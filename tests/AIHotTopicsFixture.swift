import Foundation

@main enum Main {
    static func main() throws {
        let json = """
            {"schemaVersion":1,"count":1,"items":[{"rank":1,"id":"fixture","title":"Synthetic topic",
            "source":{"name":"Fixture"},"links":{"aihot":"https://aihot.news/items/fixture","original":"https://example.com/article"},
            "sourceCount":3,"latestAt":"2026-09-14T12:20:22.000Z"}]}
            """
        let data = Data(json.utf8)
        let page = try AIHotTopicsPage.decode(data)
        precondition(page.count == 1 && page.items[0].sourceCount == 3)
        for invalid in [
            json.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2"),
            json.replacingOccurrences(of: "\"count\":1", with: "\"count\":2"),
            json.replacingOccurrences(of: "\"rank\":1", with: "\"rank\":11"),
            json.replacingOccurrences(of: "https://aihot.news/items/fixture", with: "https://example.com/items/fixture"),
            json.replacingOccurrences(of: "https://example.com/article", with: "file:///tmp/example"),
        ] {
            precondition((try? AIHotTopicsPage.decode(Data(invalid.utf8))) == nil)
        }
        precondition((try? AIHotTopicsPage.decode(Data(repeating: 32, count: 524_289))) == nil)
        let empty = try AIHotTopicsPage.decode(Data(#"{"schemaVersion":1,"count":0,"items":[]}"#.utf8))
        precondition(empty.items.isEmpty)
        precondition(AIHotTopicsClient.endpoint.query == nil, "hot-topics does not accept limit or invented filters")
        precondition(AIHotTopicsClient.refreshDelay("public, max-age=60, s-maxage=600") == 600)
        precondition(AIHotTopicsClient.refreshDelay("s-maxage=1") == 300)
        precondition(AIHotTopicsClient.refreshDelay("s-maxage=nan") == 300)
        precondition(AIHotTopicsClient.retryDelay("900") == 900)
        precondition(AIHotTopicsClient.retryDelay("bad") == 300)
        let now = ISO8601DateFormatter().date(from: "2026-09-14T12:00:00Z")!
        precondition(AIHotTopicsClient.retryDelay("Mon, 14 Sep 2026 12:10:00 GMT", now: now) == 600)
        print("aihot-topics-fixture: ok")
    }
}
