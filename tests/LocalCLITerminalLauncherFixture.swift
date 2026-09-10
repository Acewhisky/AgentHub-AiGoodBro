import Darwin
import Foundation

private enum FixtureFailure: Error { case failed(String) }

enum TerminalLauncherError: Error {
    case terminalMissing
    case launchFileFailed
    case launchFailed
}

struct TerminalLaunchDeliveryError: Error {
    let session: TerminalLaunchSession
}

struct TerminalLaunchSession {
    enum State {
        case pending
        case exited(Int32)
    }
    let scriptURL = URL(fileURLWithPath: "/tmp/synthetic-terminal-script")

    static func create(command: String) throws -> Self { Self() }
    func readState() throws -> State { .pending }
    func removeAfterExit() {}
}

enum TerminalAppLauncher {
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw FixtureFailure.failed(message) }
}

private func makeExecutable(at url: URL, contents: String = "#!/bin/sh\nexit 0\n") throws {
    try Data(contents.utf8).write(to: url)
    guard chmod(url.path, 0o700) == 0 else { throw FixtureFailure.failed("chmod executable") }
}

private func testGrokQuotingAndEnvironmentIsolation() throws {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
        "local-cli-launcher-grok-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let profileDirectory = root.appendingPathComponent("profile dir ' one", isDirectory: true)
    let workingDirectory = root.appendingPathComponent("work dir ' $(touch INJECTED)", isDirectory: true)
    try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("grok ' fixture")
    try makeExecutable(at: executable)

    let profile = LocalCLIProfile(
        id: "fixture-grok", kind: .grok, displayName: "Synthetic",
        configDirectory: profileDirectory.path, isDefault: false)
    let command = try LocalCLITerminalLauncher.command(
        profile: profile, executable: executable.path, action: .signIn, workingDirectory: workingDirectory)
    try expect(command.contains("login"), "Grok login argument")
    try expect(command.contains("--oauth"), "Grok OAuth argument")
    try expect(
        command.contains("GROK_HOME=\(TerminalAppLauncher.shellQuote(profileDirectory.path))"),
        "Grok profile environment")
    try expect(
        command.contains(
            "GROK_AUTH_PATH=\(TerminalAppLauncher.shellQuote(profileDirectory.appendingPathComponent("auth.json").path))"),
        "Grok auth path")
    try expect(
        command.hasPrefix("cd -- \(TerminalAppLauncher.shellQuote(workingDirectory.path)) || exit 72;"),
        "working directory is shell quoted")
    try expect(command.contains("-u XAI_API_KEY") && command.contains("-u GROK_API_KEY"), "Grok API keys are cleared")
}

private func testOpenCodeXDGProviderIsolation() throws {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
        "local-cli-launcher-opencode-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dataDirectory = root.appendingPathComponent(".local/share/opencode", isDirectory: true)
    let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("opencode", isDirectory: false)
    try makeExecutable(at: executable)

    let profile = LocalCLIProfile(
        id: "fixture-opencode", kind: .openCode, displayName: "OpenCode",
        configDirectory: dataDirectory.path, isDefault: false)
    let command = try LocalCLITerminalLauncher.command(
        profile: profile, executable: executable.path, action: .signIn, workingDirectory: workingDirectory)
    try expect(command.contains("'auth' 'login'"), "OpenCode auth login argument")
    try expect(command.contains("XDG_DATA_HOME='\(root.appendingPathComponent(".local/share").path)"), "OpenCode XDG data root")
    try expect(command.contains("XDG_CONFIG_HOME='\(root.appendingPathComponent(".config").path)"), "OpenCode XDG config root")
    try expect(command.contains("XDG_STATE_HOME='\(root.appendingPathComponent(".local/state").path)"), "OpenCode XDG state root")
    try expect(command.contains("-u OPENCODE_CONFIG") && command.contains("-u OPENCODE_CONFIG_DIR"), "OpenCode explicit config overrides are cleared")
    try expect(
        command.contains("-u ANTHROPIC_API_KEY") && command.contains("-u OPENAI_API_KEY"),
        "OpenCode does not inherit paid provider API keys")
    try expect(!command.contains("opencode-go"), "OpenCode Go is not substituted for provider login")

    let invalid = root.appendingPathComponent("linked", isDirectory: true)
    try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
    let invalidProfile = LocalCLIProfile(
        id: "fixture-invalid", kind: .openCode, displayName: "Invalid",
        configDirectory: invalid.path, isDefault: false)
    do {
        _ = try LocalCLITerminalLauncher.command(
            profile: invalidProfile, executable: executable.path, action: .open, workingDirectory: workingDirectory)
        throw FixtureFailure.failed("arbitrary OpenCode directory accepted")
    } catch LocalCLITerminalLauncher.Failure.invalidDirectory {
        // Expected: a linked profile must use the XDG data/opencode shape.
    }
}

private func testWorkBuddyBundleAndProductIsolation() throws {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
        "local cli launcher workbuddy ' \(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let application = root.appendingPathComponent("WorkBuddy.app", isDirectory: true)
    let cli = application.appendingPathComponent(
        "Contents/Resources/app.asar.unpacked/cli/bin/codebuddy")
    let electron = application.appendingPathComponent("Contents/MacOS/Electron")
    let product = application.appendingPathComponent(
        "Contents/Resources/app.asar.unpacked/cli/product.json")
    let profileDirectory = root.appendingPathComponent("account one/.workbuddy", isDirectory: true)
    let workingDirectory = root.appendingPathComponent("project ' one", isDirectory: true)
    try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: electron.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    try makeExecutable(at: cli)
    try makeExecutable(at: electron)
    try Data("{}".utf8).write(to: product)

    let profile = LocalCLIProfile(
        id: "fixture-workbuddy",
        kind: .workBuddy,
        displayName: "WorkBuddy",
        configDirectory: profileDirectory.path,
        isDefault: false)
    let command = try LocalCLITerminalLauncher.command(
        profile: profile,
        executable: cli.path,
        action: .signIn,
        workingDirectory: workingDirectory)
    try expect(
        command.contains(
            "\(TerminalAppLauncher.shellQuote(electron.path)) \(TerminalAppLauncher.shellQuote(cli.path))"),
        "WorkBuddy runs its bundled CLI through its bundled Electron")
    try expect(
        command.contains("ACC_PRODUCT_CONFIG_PATH=\(TerminalAppLauncher.shellQuote(product.path))"),
        "WorkBuddy product config stays in the same bundle")
    try expect(
        command.contains("CODEBUDDY_CONFIG_DIR=\(TerminalAppLauncher.shellQuote(profileDirectory.path))")
            && command.contains("WORKBUDDY_CONFIG_DIR=\(TerminalAppLauncher.shellQuote(profileDirectory.path))"),
        "WorkBuddy config variables share the selected .workbuddy directory")
    try expect(command.contains("ELECTRON_RUN_AS_NODE='1'"), "WorkBuddy uses Electron as Node")
    try expect(command.contains("WORKBUDDY_DATA_FOLDER_NAME='.workbuddy'"), "WorkBuddy data folder name")
    try expect(command.contains("DISABLE_AUTOUPDATER='1'"), "WorkBuddy updater disabled")
    try expect(!command.contains("'login'"), "WorkBuddy sign-in does not become a model prompt")

    let external = root.appendingPathComponent("codebuddy", isDirectory: false)
    try makeExecutable(at: external)
    do {
        _ = try LocalCLITerminalLauncher.command(
            profile: profile,
            executable: external.path,
            action: .open,
            workingDirectory: workingDirectory)
        throw FixtureFailure.failed("external codebuddy accepted")
    } catch LocalCLITerminalLauncher.Failure.unsupported {
        // Expected: only WorkBuddy.app's own codebuddy is accepted.
    }
}

private func testZCodeDefaultBundleCommands() throws {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
        "local cli launcher zcode ' \(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let application = root.appendingPathComponent("ZCode.app", isDirectory: true)
    let cli = application.appendingPathComponent("Contents/Resources/glm/zcode.cjs")
    let electron = application.appendingPathComponent("Contents/MacOS/ZCode")
    let profileDirectory = root.appendingPathComponent("synthetic home/.zcode", isDirectory: true)
    let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: electron.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    try Data("synthetic cjs".utf8).write(to: cli)
    try makeExecutable(at: electron)

    let profile = LocalCLIProfile(
        id: "local-zcode",
        kind: .zcode,
        displayName: "Local",
        configDirectory: profileDirectory.path,
        isDefault: true)
    let signIn = try LocalCLITerminalLauncher.command(
        profile: profile,
        executable: cli.path,
        action: .signIn,
        workingDirectory: workingDirectory)
    let settings = profileDirectory.appendingPathComponent("cli/config.json").path
    try expect(signIn.contains("'login'"), "ZCode login command")
    try expect(signIn.contains("'--settings' \(TerminalAppLauncher.shellQuote(settings))"), "ZCode CLI settings path")
    try expect(signIn.contains("ELECTRON_RUN_AS_NODE='1'"), "ZCode uses Electron as Node")

    let open = try LocalCLITerminalLauncher.command(
        profile: profile,
        executable: cli.path,
        action: .open,
        workingDirectory: workingDirectory)
    try expect(open.contains("'tui'"), "ZCode TUI command")
    try expect(!open.contains("--prompt"), "ZCode open does not send a model prompt")
}

private func testRejectsSymlinkAndLinkedZCode() throws {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
        "local-cli-launcher-safety-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real", isDirectory: true)
    let link = root.appendingPathComponent("link", isDirectory: true)
    let working = root.appendingPathComponent("working", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let executable = root.appendingPathComponent("grok", isDirectory: false)
    try makeExecutable(at: executable)
    let profile = LocalCLIProfile(
        id: "fixture-symlink", kind: .grok, displayName: "Symlink",
        configDirectory: link.path, isDefault: false)
    do {
        _ = try LocalCLITerminalLauncher.command(
            profile: profile, executable: executable.path, action: .open, workingDirectory: working)
        throw FixtureFailure.failed("symlink profile accepted")
    } catch LocalCLITerminalLauncher.Failure.invalidDirectory {
        // Expected.
    }

    let zcodeProfile = LocalCLIProfile(
        id: "fixture-zcode", kind: .zcode, displayName: "Linked ZCode",
        configDirectory: real.path, isDefault: false)
    do {
        _ = try LocalCLITerminalLauncher.command(
            profile: zcodeProfile, executable: executable.path, action: .open, workingDirectory: working)
        throw FixtureFailure.failed("linked ZCode environment accepted")
    } catch LocalCLITerminalLauncher.Failure.unsupported {
        // Expected: only the default ZCode environment can be launched.
    }
}

@main enum Main {
    static func main() throws {
        try testGrokQuotingAndEnvironmentIsolation()
        try testOpenCodeXDGProviderIsolation()
        try testWorkBuddyBundleAndProductIsolation()
        try testZCodeDefaultBundleCommands()
        try testRejectsSymlinkAndLinkedZCode()
        print("local-cli-terminal-launcher-fixture: ok")
    }
}
