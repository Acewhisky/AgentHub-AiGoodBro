import AppKit
import Darwin
import Foundation

/// Receipts contain only phase, process identity, process group and exit code.
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
        # One writer per session, including accidental re-opening of Launch.command.
        # A failed/interrupted claim remains uncertain and is never taken over.
        /bin/mkdir -- "$next_receipt.owner" 2>/dev/null || exit 74
        # Keep foreground children in the wrapper's group. Do not enable job control.
        unsetopt MONITOR
        next_pid=$$
        next_group=$(LC_ALL=C /bin/ps -o pgid= -p "$$") || exit 74
        next_group=${next_group// /}
        next_birth_text=$(LC_ALL=C TZ=UTC /bin/ps -o lstart= -p "$$") || exit 74
        next_birth=$(LC_ALL=C TZ=UTC /bin/date -j -u -f '%a %b %e %T %Y' "$next_birth_text" '+%s' 2>/dev/null) || exit 74
        [[ "$next_group" == <-> && "$next_birth" == <-> ]] || exit 74
        (( next_group > 1 && next_birth > 0 )) || exit 74
        # EXIT is evidence of intent to exit, never evidence that the group is gone.
        trap 'next_exit_status=$?; print -r -- "v2 exited $next_pid $next_group $next_birth $next_exit_status" > "$next_receipt.tmp" && /bin/mv -f -- "$next_receipt.tmp" "$next_receipt"' EXIT
        print -r -- "v2 started $next_pid $next_group $next_birth 0" > "$next_receipt.tmp"
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

    struct Receipt: Equatable {
        let state: State
        let pid: pid_t
        let group: pid_t
        let birthSeconds: UInt64
    }

    static func parseReceipt(_ line: String) throws -> Receipt {
        let parts = line.split(whereSeparator: \.isWhitespace)
        // Old receipts contain no group/identity evidence. Never infer idle from them.
        guard parts.count == 6, parts[0] == "v2",
            let pid = pid_t(parts[2]), pid > 1,
            let group = pid_t(parts[3]), group > 1,
            let birth = UInt64(parts[4]), birth > 0,
            let code = Int32(parts[5]), (0...255).contains(code)
        else { throw TerminalLauncherError.launchFailed }
        let state: State
        switch parts[1] {
        case "started" where code == 0: state = .started(pid)
        case "exited": state = .exited(code)
        default: throw TerminalLauncherError.launchFailed
        }
        return Receipt(state: state, pid: pid, group: group, birthSeconds: birth)
    }

    static func parse(_ line: String) throws -> State {
        try parseReceipt(line).state
    }

    private func receipt() throws -> Receipt {
        _ = try readState()  // Validate private directory and regular file first.
        guard let data = try DispatchParticipationSync.readBoundedRegularFile(receiptURL, maximumBytes: 128, allowMissing: false),
            let line = String(data: data, encoding: .utf8)
        else { throw TerminalLauncherError.launchFailed }
        return try Self.parseReceipt(line)
    }

    func hasMatchingLiveProcess(_ pid: pid_t) -> Bool {
        guard let receipt = try? receipt(), receipt.state == .started(pid), receipt.pid == pid else { return false }
        var process = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &process, size) == size,
            process.pbi_uid == geteuid(), process.pbi_status != UInt32(SZOMB),
            process.pbi_pgid == UInt32(receipt.group), process.pbi_start_tvsec == receipt.birthSeconds
        else { return false }
        // ps records seconds only. This is a running indication, never release proof.
        return true
    }

    enum Presence { case absent, present, unknown }

    static func presence(_ id: pid_t) -> Presence {
        if Darwin.kill(id, 0) == 0 { return .present }
        return errno == ESRCH ? .absent : .unknown
    }

    /// Injectable read-only probes allow failure/reuse cases without signalling tasks.
    /// Even a matching live writer (or a reused PID) blocks settlement. Only ESRCH
    /// for BOTH the writer and the whole recorded group can establish disappearance.
    func verifiedExitCode(probe: (pid_t) -> Presence = Self.presence) -> Int32? {
        guard let before = try? receipt(), case .exited(let code) = before.state,
            code < 128, noReceiptWriteInProgress(),
            probe(before.pid) == .absent, probe(-before.group) == .absent,
            let after = try? receipt(), before == after, noReceiptWriteInProgress()
        else { return nil }
        return code
    }

    private func noReceiptWriteInProgress() -> Bool {
        var info = stat()
        return lstat(receiptURL.path + ".tmp", &info) != 0 && errno == ENOENT
    }

    func removeAfterExit() {
        guard verifiedExitCode() != nil else { return }
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
            guard failing.terminationStatus == 7, try session.readState() == .exited(7), fm.fileExists(atPath: session.scriptURL.path) else { return false }
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
            // Foundation may use a dedicated or inherited group on different hosts.
            let ended = try session.receipt()
            if Self.presence(-ended.group) == .absent {
                guard session.verifiedExitCode() == 7 else { return false }
            } else {
                guard session.verifiedExitCode() == nil else { return false }
            }
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
