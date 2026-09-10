import Darwin
import Foundation

enum WidgetLanguage {
    case zh
    static func storedOrAutomatic() -> WidgetLanguage { .zh }
    func text(_ zh: String, _ en: String) -> String { zh }
}

private enum FixtureFailure: Error { case failed(String) }

// These persistence tests never open Terminal or perform authentication.
enum LocalCLITerminalLauncher {
    enum Action { case signIn, open }
    struct Session {}
    static func launch(profile: LocalCLIProfile, executable: String, action: Action, workingDirectory: URL) async throws -> Session {
        throw FixtureFailure.failed("interactive launcher must not run in the persistence fixture")
    }
    static func waitForExit(_ session: Session) async throws -> Int32 {
        throw FixtureFailure.failed("interactive launcher must not run in the persistence fixture")
    }
}

private func unsupportedQuota(_ profile: LocalCLIProfile) -> LocalCLIQuotaResult {
    LocalCLIQuotaResult(
        state: .unsupported,
        fetchedAt: Date(),
        maskedIdentity: nil,
        identityFingerprint: nil,
        planLabel: nil,
        windows: [],
        balance: nil,
        balanceCurrency: nil,
        sourceLabel: profile.kind.displayName,
        messageCode: "synthetic_unsupported")
}

struct LocalCLIQuotaReader {
    func load(profile: LocalCLIProfile) async -> LocalCLIQuotaResult { unsupportedQuota(profile) }
}

struct AdditionalCLIQuotaReader {
    func load(profile: LocalCLIProfile) async -> LocalCLIQuotaResult { unsupportedQuota(profile) }
}

struct ZCodeCLIQuotaReader {
    func load(profile: LocalCLIProfile) async -> LocalCLIQuotaResult { unsupportedQuota(profile) }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FixtureFailure.failed(message) }
}

@MainActor
private func makeRoot(_ label: String) throws -> (root: URL, home: URL, support: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "local-cli-account-\(label)-\(UUID().uuidString)", isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".local/bin"),
                                            withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    let applications = home.appendingPathComponent("Applications", isDirectory: true)
    let zcode = applications.appendingPathComponent("ZCode.app", isDirectory: true)
    let zcodeCLI = zcode.appendingPathComponent("Contents/Resources/glm/zcode.cjs")
    let zcodeElectron = zcode.appendingPathComponent("Contents/MacOS/ZCode")
    try FileManager.default.createDirectory(at: zcodeCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: zcodeElectron.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("synthetic zcode entry".utf8).write(to: zcodeCLI)
    try Data("synthetic electron".utf8).write(to: zcodeElectron)
    guard chmod(zcodeElectron.path, 0o700) == 0 else { throw FixtureFailure.failed("chmod ZCode runner") }

    let workBuddy = applications.appendingPathComponent("WorkBuddy.app", isDirectory: true)
    let workBuddyCLI = workBuddy.appendingPathComponent("Contents/Resources/app.asar.unpacked/cli/bin/codebuddy")
    let workBuddyProduct = workBuddy.appendingPathComponent("Contents/Resources/app.asar.unpacked/cli/product.json")
    let workBuddyElectron = workBuddy.appendingPathComponent("Contents/MacOS/Electron")
    try FileManager.default.createDirectory(at: workBuddyCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workBuddyElectron.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("synthetic workbuddy entry".utf8).write(to: workBuddyCLI)
    try Data("{}".utf8).write(to: workBuddyProduct)
    try Data("synthetic electron".utf8).write(to: workBuddyElectron)
    guard chmod(workBuddyCLI.path, 0o700) == 0, chmod(workBuddyElectron.path, 0o700) == 0 else {
        throw FixtureFailure.failed("chmod WorkBuddy bundle")
    }

    let externalCodeBuddy = home.appendingPathComponent(".local/bin/codebuddy")
    try Data("synthetic external product".utf8).write(to: externalCodeBuddy)
    guard chmod(externalCodeBuddy.path, 0o700) == 0 else { throw FixtureFailure.failed("chmod external codebuddy") }
    return (root, home, support)
}

@MainActor
private func makeStore(home: URL, support: URL,
                       loader: @escaping LocalCLIAccountStore.QuotaLoader = { profile in
                           LocalCLIQuotaResult(state: .unsupported, fetchedAt: Date(), maskedIdentity: nil,
                                               identityFingerprint: nil, planLabel: nil, windows: [],
                                               balance: nil, balanceCurrency: nil,
                                               sourceLabel: profile.kind.displayName, messageCode: nil)
                       }) -> LocalCLIAccountStore {
    LocalCLIAccountStore(
        home: home,
        support: support,
        applicationsDirectory: home.appendingPathComponent("empty-system-applications", isDirectory: true),
        quotaLoader: loader)
}

private func storage(_ support: URL) -> URL {
    support.appendingPathComponent("local-cli-accounts-v1.json")
}

@MainActor
private func testDiscoveryLinkRenameUnlinkAndPermissions() async throws {
    let paths = try makeRoot("lifecycle")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let store = makeStore(home: paths.home, support: paths.support)
    store.discover()
    let applications = paths.home.appendingPathComponent("Applications", isDirectory: true)
    try expect(
        store.installed[.zcode] == applications.appendingPathComponent(
            "ZCode.app/Contents/Resources/glm/zcode.cjs").path,
        "bundled ZCode discovery")
    try expect(
        store.installed[.workBuddy] == applications.appendingPathComponent(
            "WorkBuddy.app/Contents/Resources/app.asar.unpacked/cli/bin/codebuddy").path,
        "bundled WorkBuddy discovery does not substitute external codebuddy")
    let defaults = store.profiles(for: .zcode)
    try expect(defaults.count == 1 && defaults[0].isDefault, "default profile discovery")

    let account = paths.root.appendingPathComponent("linked z'code", isDirectory: true)
    let credential = account.appendingPathComponent("v2/config.json")
    try FileManager.default.createDirectory(at: credential.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let credentialBytes = Data("{\"synthetic\":true}".utf8)
    try credentialBytes.write(to: credential)
    store.link(kind: .zcode, directory: account, name: "Plan A")
    guard let linked = store.profiles(for: .zcode).first(where: { !$0.isDefault }) else {
        throw FixtureFailure.failed("linked profile")
    }
    try expect(store.canSignIn(defaults[0]) && store.canOpen(defaults[0]),
               "default ZCode exposes official login and TUI")
    try expect(!store.canSignIn(linked) && !store.canOpen(linked),
               "linked ZCode remains quota-only")

    let symlink = paths.root.appendingPathComponent("linked-zcode-symlink", isDirectory: true)
    guard Darwin.symlink(account.path, symlink.path) == 0 else {
        throw FixtureFailure.failed("create synthetic directory symlink")
    }
    let countBeforeSymlink = store.profiles(for: .zcode).count
    store.link(kind: .zcode, directory: symlink, name: "Symlink")
    try expect(store.profiles(for: .zcode).count == countBeforeSymlink,
               "linked directory symlink is rejected")
    try expect(UUID(uuidString: linked.id) != nil, "generated UUID profile ID")
    store.rename(linked, name: "Plan Renamed")
    guard let renamed = store.profiles(for: .zcode).first(where: { !$0.isDefault }) else {
        throw FixtureFailure.failed("renamed profile")
    }
    try expect(renamed.displayName == "Plan Renamed" && renamed.id == linked.id, "rename persistence")

    var info = stat()
    try expect(lstat(storage(paths.support).path, &info) == 0 && info.st_mode & 0o077 == 0,
               "account-link file is private")
    let persisted = try JSONDecoder().decode([LocalCLIProfile].self,
                                              from: Data(contentsOf: storage(paths.support)))
    try expect(persisted == [renamed], "only explicit links are persisted")

    store.unlink(renamed)
    try expect(store.profiles(for: .zcode).allSatisfy(\.isDefault), "unlink keeps default only")
    let retainedCredential = try Data(contentsOf: credential)
    try expect(retainedCredential == credentialBytes, "unlink does not delete credentials")
    let afterUnlink = try JSONDecoder().decode([LocalCLIProfile].self,
                                                from: Data(contentsOf: storage(paths.support)))
    try expect(afterUnlink.isEmpty, "unlink persistence")
}

@MainActor
private func testStaleWriterConflictPreservesWinner() async throws {
    let paths = try makeRoot("conflict")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let first = makeStore(home: paths.home, support: paths.support)
    let stale = makeStore(home: paths.home, support: paths.support)
    first.discover(); stale.discover()
    let one = paths.root.appendingPathComponent("one", isDirectory: true)
    let two = paths.root.appendingPathComponent("two", isDirectory: true)
    try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: two, withIntermediateDirectories: true)
    first.link(kind: .zcode, directory: one, name: "Winner")
    let winningBytes = try Data(contentsOf: storage(paths.support))
    stale.link(kind: .zcode, directory: two, name: "Stale")
    try expect(stale.message != nil, "stale writer reports conflict")
    let afterConflict = try Data(contentsOf: storage(paths.support))
    try expect(afterConflict == winningBytes, "stale writer preserves winner bytes")
}

@MainActor
private func testInvalidStoredProfilesRemainUntouched() async throws {
    for (label, profile) in [
        ("invalid-id", LocalCLIProfile(id: "not-a-uuid", kind: .zcode, displayName: "Invalid",
                                       configDirectory: "/synthetic/independent", isDefault: false)),
        ("default-collision", LocalCLIProfile(id: UUID().uuidString, kind: .zcode, displayName: "Collision",
                                              configDirectory: "/placeholder", isDefault: false)),
    ] {
        let paths = try makeRoot(label)
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var seeded = profile
        if label == "default-collision" {
            seeded.configDirectory = LocalCLIKind.zcode.defaultConfigDirectory(home: paths.home).path
        }
        let bytes = try JSONEncoder().encode([seeded])
        try bytes.write(to: storage(paths.support), options: .atomic)
        guard chmod(storage(paths.support).path, 0o600) == 0 else {
            throw FixtureFailure.failed("chmod seed")
        }
        let store = makeStore(home: paths.home, support: paths.support)
        store.discover()
        try expect(store.message != nil, "invalid stored profile rejected")
        let discoveredBytes = try Data(contentsOf: storage(paths.support))
        try expect(discoveredBytes == bytes, "invalid source preserved")
        let newDirectory = paths.root.appendingPathComponent("new", isDirectory: true)
        try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)
        store.link(kind: .zcode, directory: newDirectory, name: "Must Not Save")
        let finalBytes = try Data(contentsOf: storage(paths.support))
        try expect(finalBytes == bytes, "invalid storage blocks later mutation")
    }
}

@MainActor
private func testUnlinkRejectsLateRefresh() async throws {
    let paths = try makeRoot("late-refresh")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let store = makeStore(home: paths.home, support: paths.support, loader: { _ in
        try? await Task.sleep(nanoseconds: 150_000_000)
        return LocalCLIQuotaResult(state: .available, fetchedAt: Date(), maskedIdentity: nil,
                                   identityFingerprint: nil, planLabel: "Synthetic", windows: [],
                                   balance: nil, balanceCurrency: nil, sourceLabel: "Synthetic", messageCode: nil)
    })
    store.discover()
    let account = paths.root.appendingPathComponent("linked", isDirectory: true)
    try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
    store.link(kind: .zcode, directory: account, name: "Late")
    guard let linked = store.profiles(for: .zcode).first(where: { !$0.isDefault }) else {
        throw FixtureFailure.failed("late profile")
    }
    store.refresh(linked)
    store.unlink(linked)
    try await Task.sleep(nanoseconds: 250_000_000)
    try expect(store.quotas[linked.id] == nil && !store.refreshing.contains(linked.id),
               "unlinked profile rejects late refresh")
}

@MainActor
private func testRediscoveryRemovesOtherWritersAccountState() async throws {
    let paths = try makeRoot("rediscovery")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let store = makeStore(home: paths.home, support: paths.support, loader: { _ in
        LocalCLIQuotaResult(state: .available, fetchedAt: Date(), maskedIdentity: nil,
                            identityFingerprint: nil, planLabel: "Synthetic", windows: [],
                            balance: nil, balanceCurrency: nil, sourceLabel: "Synthetic", messageCode: nil)
    })
    store.discover()
    let directory = paths.root.appendingPathComponent("shared-link", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    store.link(kind: .zcode, directory: directory, name: "Shared")
    guard let linked = store.profiles(for: .zcode).first(where: { !$0.isDefault }) else {
        throw FixtureFailure.failed("shared profile")
    }
    store.refresh(linked)
    for _ in 0..<100 where store.refreshing.contains(linked.id) {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    try expect(store.quotas[linked.id]?.state == .available, "original account has loaded quota")
    let other = makeStore(home: paths.home, support: paths.support)
    other.discover()
    other.unlink(linked)
    store.discover()
    try expect(!store.profiles.contains(where: { $0.id == linked.id })
               && store.quotas[linked.id] == nil && !store.refreshing.contains(linked.id)
               && !store.stale.contains(linked.id), "rediscovery clears removed account runtime state")
}

@MainActor
private func testManagedGrokIsolationAndStaleWriter() throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/tmp/ng" + String(UUID().uuidString.prefix(7)), isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let home = root.appendingPathComponent("h", isDirectory: true)
    let support = root.appendingPathComponent("s", isDirectory: true)
    let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
    try fm.createDirectory(at: bin, withIntermediateDirectories: true)
    try fm.createDirectory(at: support, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let executable = bin.appendingPathComponent("grok")
    try Data("synthetic executable".utf8).write(to: executable)
    guard chmod(executable.path, 0o700) == 0 else { throw FixtureFailure.failed("Grok executable mode") }
    let first = makeStore(home: home, support: support)
    let stale = makeStore(home: home, support: support)
    first.discover(); stale.discover()
    guard let account = first.createGrokAccount(name: "Work") else {
        let expected = home.appendingPathComponent(".codex-account-manager-next/grok")
        throw FixtureFailure.failed("create Grok environment: installed=\(first.installed[.grok] != nil), normalized=\(expected.standardizedFileURL.path == expected.path), resolved=\(expected.resolvingSymlinksInPath().path == expected.path), message=\(first.message ?? "none")")
    }
    let directory = URL(fileURLWithPath: account.configDirectory)
    let attributes = try fm.attributesOfItem(atPath: directory.path)
    try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Grok private directory mode")
    try expect(account.configDirectory != LocalCLIKind.grok.defaultConfigDirectory(home: home).path, "Grok default login stays separate")
    let winner = try Data(contentsOf: storage(support))
    try expect(stale.createGrokAccount(name: "Stale") == nil, "stale Grok create rejected")
    let after = try Data(contentsOf: storage(support))
    try expect(after == winner, "stale Grok create preserves saved accounts")
    let auth = directory.appendingPathComponent("auth.json")
    try Data("synthetic retained credential".utf8).write(to: auth)
    first.unlink(account)
    try expect(fm.fileExists(atPath: auth.path), "unlink preserves Grok CLI-owned credentials")
}

@main enum Main {
    @MainActor static func main() async throws {
        try await testDiscoveryLinkRenameUnlinkAndPermissions()
        try await testStaleWriterConflictPreservesWinner()
        try await testInvalidStoredProfilesRemainUntouched()
        try await testUnlinkRejectsLateRefresh()
        try await testRediscoveryRemovesOtherWritersAccountState()
        try testManagedGrokIsolationAndStaleWriter()
        print("local-cli-account-fixture: ok")
    }
}
