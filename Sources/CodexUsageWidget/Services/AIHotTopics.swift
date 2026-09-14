import Combine
import Foundation

/// Public, read-only AIHOT v1 metadata. No credentials or model calls are used.
struct AIHotTopic: Codable, Identifiable, Equatable {
    struct Source: Codable, Equatable { let name: String }
    struct Links: Codable, Equatable {
        let aihot: URL
        let original: URL
    }
    let rank: Int
    let id: String
    let title: String
    let source: Source
    let links: Links
    let sourceCount: Int
    let latestAt: Date
}

struct AIHotTopicsPage: Codable {
    let schemaVersion: Int
    let count: Int
    let items: [AIHotTopic]

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= AIHotTopicsClient.maximumBytes else { throw AIHotTopicsClient.Failure.invalidResponse }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { input in
            let value = try input.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else { throw AIHotTopicsClient.Failure.invalidResponse }
            return date
        }
        let page = try decoder.decode(Self.self, from: data)
        guard page.schemaVersion == 1, page.count == page.items.count, page.count <= 10,
            Set(page.items.map(\.id)).count == page.count,
            Set(page.items.map(\.rank)).count == page.count,
            page.items.allSatisfy({ item in
                (1...10).contains(item.rank) && validText(item.id, maximum: 200)
                    && validText(item.title, maximum: 2_000) && validText(item.source.name, maximum: 500)
                    && (0...1_000_000).contains(item.sourceCount)
                    && item.latestAt.timeIntervalSince1970.isFinite
                    && safeURL(item.links.aihot, siteOnly: true) && safeURL(item.links.original, siteOnly: false)
            })
        else { throw AIHotTopicsClient.Failure.invalidResponse }
        return page
    }

    private static func validText(_ value: String, maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= maximum
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func safeURL(_ url: URL, siteOnly: Bool) -> Bool {
        guard url.absoluteString.utf8.count <= 4_096,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == "https", let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil, components.port == nil
        else { return false }
        return !siteOnly || (host == "aihot.news" && components.path.hasPrefix("/items/"))
    }
}

private final class AIHotRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

struct AIHotTopicsClient {
    static let endpoint = URL(string: "https://aihot.news/api/v1/hot-topics")!
    static let siteURL = URL(string: "https://aihot.news/")!
    static let maximumBytes = 512 * 1_024
    enum Failure: Error {
        case invalidResponse, unavailable
        case retryLater(TimeInterval)
    }
    struct Response {
        let page: AIHotTopicsPage?
        let etag: String?
        let refreshAfter: TimeInterval
    }

    static func refreshDelay(_ cacheControl: String?) -> TimeInterval {
        let entries = (cacheControl ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let shared = entries.first { $0.hasPrefix("s-maxage=") }
        let local = entries.first { $0.hasPrefix("max-age=") }
        let seconds = (shared ?? local)?.split(separator: "=").last.flatMap { Double($0) } ?? 300
        return seconds.isFinite ? min(86_400, max(300, seconds)) : 300
    }

    static func retryDelay(_ value: String?, now: Date = Date()) -> TimeInterval {
        if let seconds = Double(value ?? ""), seconds.isFinite { return min(86_400, max(300, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return min(86_400, max(300, formatter.date(from: value ?? "")?.timeIntervalSince(now) ?? 300))
    }

    func fetch(etag: String?) async throws -> Response {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: AIHotRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AiGoodBro/1", forHTTPHeaderField: "User-Agent")
        if let etag, etag.utf8.count <= 512, !etag.contains("\n"), !etag.contains("\r") {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.url == Self.endpoint else { throw Failure.invalidResponse }
        if http.statusCode == 429 || http.statusCode == 503 {
            throw Failure.retryLater(Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After")))
        }
        let delay = Self.refreshDelay(http.value(forHTTPHeaderField: "Cache-Control"))
        let nextETag = http.value(forHTTPHeaderField: "ETag")
        if http.statusCode == 304 {
            guard etag != nil else { throw Failure.invalidResponse }
            return Response(page: nil, etag: nextETag ?? etag, refreshAfter: delay)
        }
        guard http.statusCode == 200, http.mimeType == "application/json",
            http.expectedContentLength <= Self.maximumBytes
        else { throw Failure.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < Self.maximumBytes else { throw Failure.invalidResponse }
            data.append(byte)
        }
        return Response(page: try AIHotTopicsPage.decode(data), etag: nextETag, refreshAfter: delay)
    }
}

@MainActor
final class AIHotTopicsStore: ObservableObject {
    static let shared = AIHotTopicsStore()
    @Published private(set) var items: [AIHotTopic] = []
    @Published private(set) var checkedAt: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var failed = false
    @Published private(set) var nextRefreshAt = Date.distantPast
    private var etag: String?

    func refresh() async {
        guard !isLoading, Date() >= nextRefreshAt, !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await AIHotTopicsClient().fetch(etag: etag)
            try Task.checkCancellation()
            if let page = response.page { items = page.items.sorted { $0.rank < $1.rank } }
            etag = response.etag
            checkedAt = Date()
            failed = false
            nextRefreshAt = Date().addingTimeInterval(response.refreshAfter)
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
            let delay: TimeInterval
            if case AIHotTopicsClient.Failure.retryLater(let seconds) = error { delay = seconds } else { delay = 300 }
            nextRefreshAt = Date().addingTimeInterval(delay)
        }
    }
}
