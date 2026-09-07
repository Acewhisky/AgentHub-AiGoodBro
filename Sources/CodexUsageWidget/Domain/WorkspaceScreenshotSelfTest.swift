import AppKit
import SwiftUI

/// Offline tests: isolated defaults, synthetic accounts, no dialogs or runtime connections.
enum WorkspaceScreenshotSelfTest {
    static func run() -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("next-screenshot-test-\(UUID().uuidString)")
        let suite = "CodexAccountManagerNext.screenshot-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let retina = try WorkspaceScreenshotExporter.RasterPlan(size: CGSize(width: 980, height: 1_400))
            expect(retina.scale == 2 && retina.pixelsWide == 1_960 && retina.pixelsHigh == 2_800, "normal export must be 2x")
            let long = try WorkspaceScreenshotExporter.RasterPlan(size: CGSize(width: 980, height: 12_000))
            expect(long.scale == 1 && long.pixelsHigh == 12_000, "large export must lower scale without cropping")
            let pixelLimit = try WorkspaceScreenshotExporter.RasterPlan(size: CGSize(width: 32_000, height: 1_000))
            expect(
                pixelLimit.scale == 1 && pixelLimit.pixelsWide * pixelLimit.pixelsHigh == 32_000_000,
                "the exact pixel limit must remain exportable at 1x"
            )
            let dimensionLimit = try WorkspaceScreenshotExporter.RasterPlan(size: CGSize(width: 1, height: 32_768))
            expect(
                dimensionLimit.scale == 1 && dimensionLimit.pixelsHigh == 32_768,
                "the exact dimension limit must not be truncated"
            )
            for size in [
                CGSize(width: 0, height: 100), CGSize(width: 100, height: -1),
                CGSize(width: CGFloat.nan, height: 100), CGSize(width: 100, height: CGFloat.infinity),
                CGSize(width: 100, height: 32_769), CGSize(width: 10_000, height: 10_000),
                CGSize(width: 32_000, height: 1_000.01),
            ] {
                do {
                    _ = try WorkspaceScreenshotExporter.RasterPlan(size: size)
                    failures.append("invalid or oversized layout was accepted")
                } catch {}
            }

            // Explicit top/bottom markers catch viewport-only or upside-down exports.
            let stripes = VStack(spacing: 0) {
                Color.red.frame(height: 80)
                Color.blue.frame(height: 1_800)
                Color.green.frame(height: 80)
            }
            let stripeCapture = try WorkspaceScreenshotExporter.render(stripes, width: 320, scheme: .light)
            expect(stripeCapture.plan.size.height == 1_960, "content height must exceed and not depend on any viewport")
            if let bitmap = NSBitmapImageRep(data: stripeCapture.png),
                let top = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 20)?.usingColorSpace(.deviceRGB),
                let bottom = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - 20)?.usingColorSpace(.deviceRGB)
            {
                expect(top.redComponent > top.greenComponent, "top marker must be present and correctly oriented")
                expect(bottom.greenComponent > bottom.redComponent, "offscreen bottom marker must be present")
                expect(top.alphaComponent > 0.99 && bottom.alphaComponent > 0.99, "image must have an opaque background")
            } else {
                failures.append("export must decode as a complete PNG")
            }
            let output = root.appendingPathComponent("roundtrip.png")
            expect(try WorkspaceScreenshotExporter.finishSave(stripeCapture, to: nil) == nil, "cancel must return without saving")
            expect(!FileManager.default.fileExists(atPath: output.path), "cancel must not create a file")
            expect(try WorkspaceScreenshotExporter.finishSave(stripeCapture, to: output) == output, "save must return the selected destination")
            expect(try Data(contentsOf: output) == stripeCapture.png, "PNG must survive an atomic write")
            do {
                _ = try WorkspaceScreenshotExporter.finishSave(stripeCapture, to: root)
                failures.append("writing over a directory should fail")
            } catch {}
            expect(try Data(contentsOf: output) == stripeCapture.png, "failed save must preserve the prior file")

            let catalog = PaletteCatalog.loadFromMainBundle()
            let settings = AppSettings(defaults: defaults, paletteCatalog: catalog)
            var previousHeight: CGFloat = 0
            for count in 1...9 {
                let store = WorkspacePreviewRenderer.fixtureStore(
                    accountCount: count,
                    root: root.appendingPathComponent("row-growth-\(count)")
                )
                let view = CodexAccountManagerView(store: store, settings: settings, paletteCatalog: catalog)
                let captured = try WorkspaceScreenshotExporter.render(view.screenshotContent, width: 980, scheme: .light)
                expect(captured.plan.size.height > previousHeight, "each synthetic account row through nine must increase export height")
                previousHeight = captured.plan.size.height
            }
            for scheme in [ColorScheme.light, .dark] {
                settings.themeMode = scheme == .dark ? .dark : .light
                for width: CGFloat in [820, 980, 1280] {
                    let eightAccountStore = WorkspacePreviewRenderer.fixtureStore(
                        accountCount: 8,
                        root: root.appendingPathComponent(UUID().uuidString)
                    )
                    let eightAccountView = CodexAccountManagerView(
                        store: eightAccountStore,
                        settings: settings,
                        paletteCatalog: catalog
                    )
                    let eightAccountCapture = try WorkspaceScreenshotExporter.render(
                        eightAccountView.screenshotContent,
                        width: width,
                        scheme: scheme
                    )
                    let store = WorkspacePreviewRenderer.fixtureStore(accountCount: 9, root: root.appendingPathComponent(UUID().uuidString))
                    let view = CodexAccountManagerView(store: store, settings: settings, paletteCatalog: catalog)
                    let captured = try WorkspaceScreenshotExporter.render(view.screenshotContent, width: width, scheme: scheme)
                    expect(captured.plan.size.width == width, "export must keep the current workspace width")
                    expect(
                        captured.plan.size.height > eightAccountCapture.plan.size.height,
                        "the ninth account row must increase the complete export height at every layout"
                    )
                    expect(NSBitmapImageRep(data: captured.png)?.pixelsHigh == captured.plan.pixelsHigh, "long PNG must retain its full planned height")
                    expect(store.isPreview && store.profiles.count == 9, "export must retain all nine fixture accounts")
                }
            }
        } catch {
            failures.append("render or persistence test threw an error")
        }
        if failures.isEmpty {
            print("Workspace screenshot self-test passed: bounds, 2x/1x, offscreen bottom, cancel/save/failure, row growth through nine, 6 nine-account layouts")
            return true
        }
        failures.forEach { print("Workspace screenshot self-test failed: \($0)") }
        return false
    }
}
