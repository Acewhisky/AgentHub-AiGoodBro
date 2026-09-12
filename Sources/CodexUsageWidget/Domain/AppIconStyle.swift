import AppKit

enum AppIconStyle: String, CaseIterable, Identifiable {
    case warmWhite
    case deepPlum
    case sageGreen
    case graphite
    case champagne

    static let storageKey = "AiGoodBro.appIconStyle.v1"
    static let `default` = AppIconStyle.warmWhite

    var id: String { rawValue }

    var resourceName: String {
        switch self {
        case .warmWhite: return "AiGoodBro"
        case .deepPlum: return "AiGoodBro-02-deep-plum"
        case .sageGreen: return "AiGoodBro-03-sage-green"
        case .graphite: return "AiGoodBro-04-graphite"
        case .champagne: return "AiGoodBro-05-champagne"
        }
    }

    func title(_ language: WidgetLanguage) -> String {
        switch self {
        case .warmWhite: return language.text("暖白", "Warm white")
        case .deepPlum: return language.text("深梅紫", "Deep plum")
        case .sageGreen: return language.text("鼠尾草绿", "Sage green")
        case .graphite: return language.text("石墨灰", "Graphite")
        case .champagne: return language.text("浅香槟", "Champagne")
        }
    }

    static func storedOrDefault(defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .default
    }

    func persist(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }

    @discardableResult
    func applyToRunningApp() -> Bool {
        // Pure command-line self-tests intentionally do not create an
        // NSApplication. Accessing NSApp.applicationIconImage in that state
        // traps, so applying an icon is only meaningful once an app exists.
        guard let application = NSApp else { return false }
        let bundle = Bundle.main
        let image =
            bundle.image(forResource: resourceName)
            ?? NSImage(contentsOf: bundle.url(forResource: resourceName, withExtension: "icns") ?? URL(fileURLWithPath: "/dev/null"))
        guard let image else { return false }
        application.applicationIconImage = image
        return true
    }
}

enum AppIconStyleSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        expect(AppIconStyle.allCases.count == 5, "five icon palettes")
        expect(AppIconStyle.default == .warmWhite, "default is warm white")
        expect(Set(AppIconStyle.allCases.map(\.resourceName)).count == 5, "resource names are unique")
        let defaults = UserDefaults(suiteName: "AiGoodBro.appIconStyle.self-test")!
        defaults.removePersistentDomain(forName: "AiGoodBro.appIconStyle.self-test")
        expect(AppIconStyle.storedOrDefault(defaults: defaults) == .warmWhite, "missing key falls back to warm white")
        AppIconStyle.graphite.persist(defaults: defaults)
        expect(AppIconStyle.storedOrDefault(defaults: defaults) == .graphite, "persisted style reloads")
        defaults.set("not-a-style", forKey: AppIconStyle.storageKey)
        expect(AppIconStyle.storedOrDefault(defaults: defaults) == .warmWhite, "corrupt value falls back")
        if NSApp == nil {
            expect(!AppIconStyle.default.applyToRunningApp(), "headless icon apply safely reports no running app")
        }
        if failures.isEmpty {
            print("app icon style self-test passed")
            return true
        }
        failures.forEach { print("app icon style self-test failed: \($0)") }
        return false
    }
}
