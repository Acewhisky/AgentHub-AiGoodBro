import AppKit
import Darwin
import Foundation

/// Only a phase, process ID or exit code is persisted. Terminal contents are never captured.
struct TerminalLaunchSession {
    enum State: Equatable {
        case pending
        case started(pid_t)
        case exited(Int32)
    }

    let directory: URL
    var scriptURL: URL { directory.appendingPathComponent("Launch.command") }
    var receiptURL: URL { directory.appendingPathComponent("receipt") }

    static func create(command: String, fileManager: FileManager = .default, base: URL? = nil, identifier: String = UUID().uuidString.lowercased()) throws -> Self {
        let root = base ?? DispatchParticipationPaths.supportDirectory().appendingPathComponent("terminal-launches", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
            info.st_uid == geteuid(), info.st_mode & 0o077 == 0
        else { throw TerminalLauncherError.launchFileFailed }
        guard UUID(uuidString: identifier)?.uuidString.lowercased() == identifier else { throw TerminalLauncherError.launchFileFailed }
        let session = Self(directory: root.appendingPathComponent(identifier, isDirectory: true))
        try fileManager.createDirectory(at: session.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let script = script(command: command, receipt: session.receiptURL)
            try Data(script.utf8).write(to: session.scriptURL, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: session.scriptURL.path)
            return session
        } catch {
            try? fileManager.removeItem(at: session.directory)
            throw TerminalLauncherError.launchFileFailed
        }
    }

    static func script(command: String, receipt: URL) -> String {
        """
        #!/bin/zsh -f
        umask 077
        next_receipt=\(TerminalAppLauncher.shellQuote(receipt.path))
        trap 'next_exit_status=$?; print -r -- "exited ${next_exit_status}" > "$next_receipt.tmp"; /bin/mv -f -- "$next_receipt.tmp" "$next_receipt"; /bin/rm -f -- "$0"' EXIT
        print -r -- "started $$" > "$next_receipt.tmp"
        /bin/mv -f -- "$next_receipt.tmp" "$next_receipt" || exit 74
        \(command)
        next_exit_status=$?
        if (( next_exit_status != 0 )); then
            print -r -- "CLI exited with code ${next_exit_status}. See the error above."
        fi
        exit "$next_exit_status"
        """ + "\n"
    }

    func readState() throws -> State {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
            info.st_uid == geteuid(), info.st_mode & 0o077 == 0
        else { throw TerminalLauncherError.launchFileFailed }
        if lstat(receiptURL.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
                info.st_mode & 0o077 == 0
            else { throw TerminalLauncherError.launchFileFailed }
        } else if errno != ENOENT {
            throw TerminalLauncherError.launchFileFailed
        }
        guard let data = try DispatchParticipationSync.readBoundedRegularFile(receiptURL, maximumBytes: 128, allowMissing: true) else { return .pending }
        guard let line = String(data: data, encoding: .utf8) else { throw TerminalLauncherError.launchFailed }
        return try Self.parse(line)
    }

    static func parse(_ line: String) throws -> State {
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, let number = Int32(parts[1]) else { throw TerminalLauncherError.launchFailed }
        switch parts[0] {
        case "started" where number > 1: return .started(number)
        case "exited" where (0...255).contains(number): return .exited(number)
        default: throw TerminalLauncherError.launchFailed
        }
    }

    func hasMatchingLiveProcess(_ pid: pid_t) -> Bool {
        var process = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &process, size) == size,
            process.pbi_uid == geteuid(), process.pbi_status != UInt32(SZOMB),
            let values = try? receiptURL.resourceValues(forKeys: [.contentModificationDateKey]),
            let writtenAt = values.contentModificationDate
        else { return false }
        let startedAt = Double(process.pbi_start_tvsec) + Double(process.pbi_start_tvusec) / 1_000_000
        // The wrapper writes its first receipt immediately. A reused PID must
        // never turn an old launch receipt back into a running session.
        return abs(writtenAt.timeIntervalSince1970 - startedAt) <= 5
    }

    func removeAfterExit() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func recovering(leaseID: String) throws -> Self {
        guard UUID(uuidString: leaseID)?.uuidString.lowercased() == leaseID else { throw TerminalLauncherError.launchFileFailed }
        let session = Self(
            directory: DispatchParticipationPaths.supportDirectory()
                .appendingPathComponent("terminal-launches", isDirectory: true).appendingPathComponent(leaseID, isDirectory: true))
        _ = try session.readState()
        return session
    }

    static func selfTest() -> Bool {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("next-terminal-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let working = root.appendingPathComponent("folder ' $(touch INJECTED) 中文", isDirectory: true)
            try fm.createDirectory(at: working, withIntermediateDirectories: false)
            let profile = root.appendingPathComponent("isolated-profile", isDirectory: true)
            try fm.createDirectory(at: profile, withIntermediateDirectories: false)
            let executable = root.appendingPathComponent("test-cli ' binary")
            let fakeCLI = """
                #!/bin/sh
                printf '%s\\n' "$CODEX_HOME" "$PWD" "${OPENAI_API_KEY-unset}" "${CODEX_THREAD_ID-unset}" "$@"
                exit "${NEXT_TEST_EXIT_CODE:-0}"
                """ + "\n"
            try Data(fakeCLI.utf8).write(to: executable)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let command = try TerminalAppLauncher.command(codexHome: profile, directory: working, executable: executable.path, preference: .defaultValue, homeDirectory: root)
            guard !command.contains("\n") else { return false }
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", "-c", command + "; [ \"$CODEX_HOME\" = parent-fixture ]"]
            process.environment = [
                "PATH": "/usr/bin:/bin", "HOME": root.appendingPathComponent("different-home").path, "CODEX_HOME": "parent-fixture", "OPENAI_API_KEY": "test-only",
                "CODEX_THREAD_ID": "test-only",
            ]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            let outputData = try pipe.fileHandleForReading.read(upToCount: 16_384) ?? Data()
            guard outputData.count < 16_384 else { return false }
            let output = String(data: outputData, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0,
                output.contains(profile.path), output.contains(working.path),
                output.contains("unset\nunset\n--model\ngpt-6-astra\n"),
                !fm.fileExists(atPath: root.appendingPathComponent("INJECTED").path)
            else { return false }
            let session = try Self.create(command: command, base: root.appendingPathComponent("launches"))
            guard try session.readState() == .pending else { return false }
            let failing = Process()
            failing.executableURL = URL(fileURLWithPath: "/bin/zsh")
            failing.arguments = ["-f", session.scriptURL.path]
            failing.environment = ["PATH": "/usr/bin:/bin", "HOME": fm.homeDirectoryForCurrentUser.path, "NEXT_TEST_EXIT_CODE": "7"]
            failing.standardOutput = FileHandle.nullDevice
            failing.standardError = FileHandle.nullDevice
            try failing.run()
            failing.waitUntilExit()
            guard failing.terminationStatus == 7, try session.readState() == .exited(7), !fm.fileExists(atPath: session.scriptURL.path) else { return false }
            do {
                _ = try Self.parse("started 0")
                return false
            } catch {}
            do {
                _ = try Self.parse("exited -1")
                return false
            } catch {}
            do {
                _ = try Self.parse("exited 256")
                return false
            } catch {}
            var currentProcess = proc_bsdinfo()
            let processInfoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &currentProcess, processInfoSize) == processInfoSize else { return false }
            let birth = Date(timeIntervalSince1970: Double(currentProcess.pbi_start_tvsec) + Double(currentProcess.pbi_start_tvusec) / 1_000_000)
            try fm.setAttributes([.modificationDate: birth], ofItemAtPath: session.receiptURL.path)
            guard session.hasMatchingLiveProcess(getpid()) else { return false }
            try fm.setAttributes([.modificationDate: birth.addingTimeInterval(-60)], ofItemAtPath: session.receiptURL.path)
            guard !session.hasMatchingLiveProcess(getpid()) else { return false }
            session.removeAfterExit()
            print("Terminal session self-test passed: quoting, isolation, receipt and failure exit")
            return true
        } catch {
            print("Terminal session self-test failed")
            return false
        }
    }
}

struct TerminalLaunchDeliveryError: LocalizedError {
    let session: TerminalLaunchSession
    var errorDescription: String? { TerminalLauncherError.launchFailed.errorDescription }
}
