import CryptoKit
import Darwin
import Foundation

/// Content-addressed role files survive app upgrades and the parent terminal.
/// Names and user task text never enter this configuration.
enum NativeExecutionPreset {
    static let roleName = "next_preset_worker"
    static let initialPrompt = "Next collaboration preset: act as the primary planner and final reviewer. Delegate implementation when useful using only the next_preset_worker role, without fork_context=true or explicit model or reasoning-effort overrides. Keep one child active at a time and review its result. This is a workflow convention, not a guaranteed whole-tree security boundary. Preserve the user's existing instructions. Wait for my task; do not execute commands yet."

    static func supports(version: String, features: String) -> Bool {
        let words = version.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard words.count == 2, words[0] == "codex-cli" else { return false }
        let numbers = words[1].split(separator: ".")
        guard numbers.count == 3, let major = Int(numbers[0]), let minor = Int(numbers[1]), Int(numbers[2]) != nil,
            major > 0 || (major == 0 && minor >= 154)
        else { return false }
        return features.split(separator: "\n").contains { $0.split(whereSeparator: \.isWhitespace).first == "multi_agent" }
    }

    static func validateCLI(executable: URL, codexHome: URL) throws {
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        do {
            let version = try BoundedLocalProcess.run(executable: executable, arguments: ["--version"], environment: environment,
                maximumOutputBytes: 4096, timeout: 2)
            let features = try BoundedLocalProcess.run(executable: executable, arguments: ["features", "list"], environment: environment,
                maximumOutputBytes: 32 * 1024, timeout: 3)
            guard supports(version: String(decoding: version, as: UTF8.self), features: String(decoding: features, as: UTF8.self)) else {
                throw TerminalLauncherError.presetCapabilityUnavailable
            }
        } catch { throw TerminalLauncherError.presetCapabilityUnavailable }
    }

    static func roleData(_ preference: CodexExecutionPreference) throws -> Data? {
        let strategy = try preference.validated().effectiveStrategy
        guard let model = strategy.subagentModel, let effort = strategy.subagentReasoningEffort else { return nil }
        return Data("model = \"\(model.rawValue)\"\nmodel_reasoning_effort = \"\(effort.rawValue)\"\n".utf8)
    }

    static func freezeRole(_ preference: CodexExecutionPreference, base: URL? = nil) throws -> URL? {
        guard let data = try roleData(preference) else { return nil }
        let directory = base ?? DispatchParticipationPaths.supportDirectory().appendingPathComponent("execution-presets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
            info.st_uid == geteuid(), info.st_mode & 0o077 == 0
        else { throw TerminalLauncherError.launchFileFailed }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent(digest + ".toml")
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd >= 0 {
            var complete = false
            defer { Darwin.close(fd); if !complete { try? FileManager.default.removeItem(at: url) } }
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard written == data.count, fsync(fd) == 0 else { throw TerminalLauncherError.launchFileFailed }
            complete = true
        } else if errno != EEXIST {
            throw TerminalLauncherError.launchFileFailed
        }
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
            try DispatchParticipationSync.readBoundedRegularFile(url, maximumBytes: 1024, allowMissing: false) == data
        else { throw TerminalLauncherError.launchFileFailed }
        return url
    }
}
