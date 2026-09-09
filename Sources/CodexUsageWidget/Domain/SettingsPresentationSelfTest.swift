import Cocoa

/// UI reorganization must keep the existing preference keys and round trips.
enum SettingsPresentationSelfTest {
    static func run() -> Bool {
        let application = NSApplication.shared
        let previousAppearance = application.appearance
        defer { application.appearance = previousAppearance }
        let suiteName = "CodexManagerNext.settings-self-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return false }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        expect(SettingsPage.allCases == [.appearance, .menuBar, .automation, .workspace, .about], "all five direct settings pages remain reachable")
        for language in WidgetLanguage.allCases {
            let titles = SettingsPage.allCases.map { $0.title(language) }
            expect(Set(titles).count == titles.count, "settings pages have unique localized labels")
            expect(SettingsPage.allCases.allSatisfy { !$0.detail(language).isEmpty && !$0.symbol.isEmpty }, "settings pages have labels and descriptions")
        }

        let catalog = PaletteCatalog.loadFromMainBundle()
        let settings = AppSettings(defaults: defaults, paletteCatalog: catalog)
        expect(settings.language == .zh && settings.themeMode == .system, "fresh installs use Chinese and follow system appearance")
        expect(settings.accountWorkspaceLayout == .rows && settings.paletteID == PaletteCatalog.defaultPaletteID, "fresh installs use the list and standard palette")
        expect(settings.statusItemPreferences == .accountRing && settings.globalShortcut == .default, "fresh installs show weekly remaining quota and enable Command-U")
        expect(settings.setupProgress.shouldPresentAutomatically, "general defaults must not copy another user's completed setup")
        expect(
            CodexExecutionPreference.defaultValue == .init(model: .astra, reasoningEffort: .low, serviceTier: .standard),
            "new account task defaults use Astra Low at standard speed")
        for mode in WidgetThemeMode.allCases {
            settings.themeMode = mode
            expect(WidgetThemeMode.storedOrAutomatic(defaults: defaults) == mode, "theme tiles preserve existing persistence")
        }
        for language in WidgetLanguage.allCases {
            settings.language = language
            expect(WidgetLanguage.storedOrAutomatic(defaults: defaults) == language, "language segments persist")
        }
        for transparency in AccountMenuTransparency.allCases {
            settings.accountMenuTransparency = transparency
            expect(AccountMenuTransparency.storedOrDefault(defaults: defaults) == transparency, "opacity segments persist")
        }
        for motion in ParticleAnimationMode.allCases {
            settings.particleAnimationMode = motion
            expect(ParticleAnimationMode.storedOrDefault(defaults: defaults) == motion, "motion segments persist")
        }
        settings.keepMainWindowOnTop = true
        settings.keepRunningWhenMainWindowClosed = false
        settings.automaticUpdateChecksEnabled = false
        GlobalShortcut.clear(defaults: defaults)
        let restored = AppSettings(defaults: defaults, paletteCatalog: catalog)
        expect(restored.keepMainWindowOnTop, "window pin setting survives reopen")
        expect(!restored.keepRunningWhenMainWindowClosed, "background setting survives reopen")
        expect(!restored.automaticUpdateChecksEnabled, "update opt-out survives reopen")
        expect(restored.themeMode == settings.themeMode && restored.language == settings.language, "appearance and language survive reopen")
        expect(restored.globalShortcut == nil, "a saved shortcut opt-out survives the new defaults")

        if failures.isEmpty {
            print("settings presentation self-test passed")
            return true
        }
        failures.forEach { print("settings presentation self-test failed: \($0)") }
        return false
    }
}
