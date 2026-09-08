import Cocoa
import Darwin

/// Acquired before UsageStore is constructed, so a second bundle cannot start
/// quota readers or write the first instance's account state.
final class NextAppInstanceLease {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    enum Failure: Error { case unavailable }

    static func acquire(in directory: URL, fileManager: FileManager = .default) throws -> NextAppInstanceLease? {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(".app-instance.lock")
        let descriptor = url.path.withCString { Darwin.open($0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600) }
        guard descriptor >= 0 else { throw Failure.unavailable }
        var acquired = false
        defer { if !acquired { Darwin.close(descriptor) } }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
            info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == geteuid(),
            info.st_nlink == 1,
            info.st_mode & 0o077 == 0
        else { throw Failure.unavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { return nil }
            throw Failure.unavailable
        }
        acquired = true
        return NextAppInstanceLease(descriptor: descriptor)
    }

    /// Older builds do not hold the lease. Yield to an already launched copy;
    /// simultaneous new launches use a deterministic order and the file lease.
    static func runningOwner() -> NSRunningApplication? {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: "com.blackielf.codex-account-manager-next")
            .filter {
                !$0.isTerminated && $0.processIdentifier != currentPID
                    && ($0.isFinishedLaunching || $0.processIdentifier < currentPID)
            }
            .sorted { $0.processIdentifier < $1.processIdentifier }
            .first
    }

    static func selfTest() -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("camnext-instance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            var first = try acquire(in: root)
            guard let descriptor = first?.descriptor,
                fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0,
                try acquire(in: root) == nil
            else { throw Failure.unavailable }
            let independent = try acquire(in: root.appendingPathComponent("independent", isDirectory: true))
            guard independent != nil else { throw Failure.unavailable }
            first = nil
            guard try acquire(in: root) != nil else { throw Failure.unavailable }

            let invalid = root.appendingPathComponent("invalid", isDirectory: true)
            try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
            let target = root.appendingPathComponent("untouched.txt")
            let original = Data("preserve".utf8)
            try original.write(to: target)
            let link = invalid.appendingPathComponent(".app-instance.lock")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            do {
                _ = try acquire(in: invalid)
                throw CocoaError(.fileWriteUnknown)
            } catch Failure.unavailable {
                guard try Data(contentsOf: target) == original else { throw Failure.unavailable }
            }
            withExtendedLifetime(independent) {}
            print("Next single-instance lease self-test passed")
            return true
        } catch {
            print("Next single-instance lease self-test failed")
            return false
        }
    }
}
