import Foundation

struct AccountAutomationEvent: Codable, Equatable, Identifiable {
    enum Level: String, Codable {
        case info
        case success
        case warning
        case failure
    }

    let id: UUID
    let occurredAt: Date
    let level: Level
    let title: String
    let detail: String
}

final class AccountAutomationAuditStore {
    enum Failure: Error { case invalidArchive, archiveTooLarge }

    static let maximumArchiveBytes = 1 * 1_024 * 1_024
    private let fileManager: FileManager
    private let eventsURL: URL
    private let maximumEvents = 100

    init(fileManager: FileManager = .default, applicationSupportDirectory: URL? = nil) {
        self.fileManager = fileManager
        let support =
            applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        eventsURL =
            support
            .appendingPathComponent("CodexAccountManagerNext", isDirectory: true)
            .appendingPathComponent("automation-events-v1.json")
    }

    func load() -> [AccountAutomationEvent] {
        (try? readEvents()) ?? []
    }

    func append(_ event: AccountAutomationEvent) throws -> [AccountAutomationEvent] {
        // Do not turn an unreadable, malformed, linked, or oversized archive into
        // an empty history and overwrite the evidence with the new event.
        var events = try readEvents()
        events.insert(event, at: 0)
        events = Array(events.prefix(maximumEvents))
        let data = try JSONEncoder().encode(events)
        guard data.count <= Self.maximumArchiveBytes else { throw Failure.archiveTooLarge }
        try PrivateLocalFileStore.write(data, to: eventsURL, fileManager: fileManager)
        return events
    }

    private func readEvents() throws -> [AccountAutomationEvent] {
        let data: Data?
        do {
            data = try DispatchParticipationSync.readBoundedRegularFile(
                eventsURL,
                maximumBytes: Self.maximumArchiveBytes,
                allowMissing: true
            )
        } catch {
            throw Failure.invalidArchive
        }
        guard let data else { return [] }
        guard let events = try? JSONDecoder().decode([AccountAutomationEvent].self, from: data) else {
            throw Failure.invalidArchive
        }
        return Array(events.prefix(maximumEvents))
    }
}

enum AccountAutomationAuditStoreSelfTest {
    static func run() -> Bool {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("account-automation-audit-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        do {
            let store = AccountAutomationAuditStore(
                fileManager: fileManager,
                applicationSupportDirectory: root
            )
            let event = AccountAutomationEvent(
                id: UUID(),
                occurredAt: Date(timeIntervalSince1970: 123),
                level: .success,
                title: "自动切换完成",
                detail: "c***@e***.com → n***@e***.com"
            )
            guard try store.append(event) == [event], store.load() == [event] else {
                print("Account automation audit store self-test failed")
                return false
            }
            let orderingStore = AccountAutomationAuditStore(
                fileManager: fileManager,
                applicationSupportDirectory: root.appendingPathComponent("ordering", isDirectory: true)
            )
            for index in 0...100 {
                _ = try orderingStore.append(AccountAutomationEvent(
                    id: UUID(), occurredAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    level: .info, title: "event-\(index)", detail: "bounded"
                ))
            }
            let ordered = orderingStore.load()
            guard ordered.count == 100, ordered.first?.title == "event-100",
                ordered.last?.title == "event-1"
            else {
                print("Account automation audit store self-test failed: retention order")
                return false
            }
            let archive = root
                .appendingPathComponent("CodexAccountManagerNext", isDirectory: true)
                .appendingPathComponent("automation-events-v1.json")
            let original = try Data(contentsOf: archive)
            let oversized = AccountAutomationEvent(
                id: UUID(), occurredAt: Date(), level: .warning,
                title: "oversized", detail: String(repeating: "x", count: Self.maximumFixtureBytes)
            )
            do {
                _ = try store.append(oversized)
                print("Account automation audit store self-test failed: oversized append accepted")
                return false
            } catch {}
            guard try Data(contentsOf: archive) == original else {
                print("Account automation audit store self-test failed: oversized append replaced history")
                return false
            }

            let malformed = Data("not-json".utf8)
            try PrivateLocalFileStore.write(malformed, to: archive, fileManager: fileManager)
            do {
                _ = try store.append(event)
                print("Account automation audit store self-test failed: malformed archive overwritten")
                return false
            } catch {}
            guard try Data(contentsOf: archive) == malformed else {
                print("Account automation audit store self-test failed: malformed archive changed")
                return false
            }

            let handle = try FileHandle(forWritingTo: archive)
            try handle.truncate(atOffset: UInt64(AccountAutomationAuditStore.maximumArchiveBytes + 1))
            try handle.close()
            let oversizedArchiveSize = try fileManager.attributesOfItem(atPath: archive.path)[.size] as? NSNumber
            guard store.load().isEmpty else {
                print("Account automation audit store self-test failed: oversized archive loaded")
                return false
            }
            do {
                _ = try store.append(event)
                print("Account automation audit store self-test failed: oversized archive overwritten")
                return false
            } catch {}
            let retainedSize = try fileManager.attributesOfItem(atPath: archive.path)[.size] as? NSNumber
            guard retainedSize == oversizedArchiveSize else {
                print("Account automation audit store self-test failed: oversized archive changed")
                return false
            }
            print("Account automation audit store self-test passed")
            return true
        } catch {
            print("Account automation audit store self-test failed: \(error)")
            return false
        }
    }

    private static let maximumFixtureBytes = AccountAutomationAuditStore.maximumArchiveBytes + 1
}
