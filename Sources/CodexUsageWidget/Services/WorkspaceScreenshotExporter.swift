import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Renders the workspace's non-scrolling content, never the desktop or another window.
enum WorkspaceScreenshotExporter {
    static let maximumRGBABytes: CGFloat = 128_000_000

    enum ExportError: LocalizedError {
        case invalidSize, tooLarge, renderingFailed

        var errorDescription: String? {
            message(.storedOrAutomatic())
        }

        func message(_ language: WidgetLanguage) -> String {
            switch self {
            case .invalidSize: return language.text("主界面尚未完成排版，请稍后再试。", "The workspace is still laying out. Please try again shortly.")
            case .tooLarge: return language.text("内容超出安全图片尺寸，请收起部分栏目后再试；未截断内容。", "The image exceeds the safe size limit. Collapse a section and try again; no content was cropped.")
            case .renderingFailed: return language.text("未能生成图片，请重试。", "Could not capture the workspace. Please try again.")
            }
        }
    }

    struct RasterPlan {
        let size: CGSize
        let scale: CGFloat
        let pixelsWide: Int
        let pixelsHigh: Int

        init(size: CGSize) throws {
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
                throw ExportError.invalidSize
            }
            let rounded = CGSize(width: ceil(size.width), height: ceil(size.height))
            // Bound dimensions before converting to Int or allocating an RGBA bitmap.
            let maximumDimension: CGFloat = 32_768
            let maximumPixels = maximumRGBABytes / 4
            guard rounded.width <= maximumDimension, rounded.height <= maximumDimension,
                rounded.width * rounded.height <= maximumPixels
            else { throw ExportError.tooLarge }
            let retinaFits =
                rounded.width * 2 <= maximumDimension
                && rounded.height * 2 <= maximumDimension
                && rounded.width * rounded.height * 4 <= maximumPixels
            self.size = rounded
            let scale: CGFloat = retinaFits ? 2 : 1
            self.scale = scale
            pixelsWide = Int(rounded.width * scale)
            pixelsHigh = Int(rounded.height * scale)
        }
    }

    struct Capture {
        let png: Data
        let plan: RasterPlan
    }

    static func render<Content: View>(_ content: Content, width: CGFloat, scheme: ColorScheme) throws -> Capture {
        guard Thread.isMainThread, width.isFinite, width > 0, width <= 32_768 else { throw ExportError.invalidSize }
        let root =
            content
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, scheme)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 1),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        // This offscreen host never orders a window front or starts runtime polling.
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        host.layoutSubtreeIfNeeded()
        let plan = try RasterPlan(size: CGSize(width: width, height: host.fittingSize.height))
        window.setContentSize(plan.size)
        host.frame = NSRect(origin: .zero, size: plan.size)
        host.layoutSubtreeIfNeeded()
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: plan.pixelsWide, pixelsHigh: plan.pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )
        else { throw ExportError.renderingFailed }
        bitmap.size = plan.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]), !png.isEmpty else {
            throw ExportError.renderingFailed
        }
        return Capture(png: png, plan: plan)
    }

    static func save(_ capture: Capture, for window: NSWindow, language: WidgetLanguage = .storedOrAutomatic(), completion: @escaping (Result<URL?, Error>) -> Void) {
        let panel = NSSavePanel()
        panel.title = language.text("保存 Next 主界面长截图", "Save Next workspace screenshot")
        panel.message = language.text(
            "包含滚动区全部内容，保持当前展开状态；仅保存到本机，不会上传。", "Includes the full scrollable workspace with the current expanded sections. Saves locally; nothing is uploaded.")
        panel.prompt = language.text("保存", "Save")
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMdd-HHmmss"
        panel.nameFieldStringValue = language.text("Next-长截图-", "Next-workspace-") + "\(formatter.string(from: Date())).png"
        panel.beginSheetModal(for: window) { response in
            do {
                completion(.success(try finishSave(capture, to: response == .OK ? panel.url : nil)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// A cancelled panel has no destination and must perform no filesystem mutation.
    static func finishSave(_ capture: Capture, to destination: URL?) throws -> URL? {
        guard let destination else { return nil }
        try capture.png.write(to: destination, options: .atomic)
        return destination
    }
}
