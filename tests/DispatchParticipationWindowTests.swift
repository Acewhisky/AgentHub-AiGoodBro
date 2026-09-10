import Foundation

@main
struct DispatchParticipationWindowTests {
    static func main() throws {
        func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
        var window = DispatchParticipationWindow(mode: .onlyWithin, timeZoneIdentifier: "Asia/Shanghai", intervals: [
            .init(startMinute: 23 * 60, endMinute: 60, allDays: false, weekdays: [1])
        ])
        precondition(window.allowsAdmission(at: date("2026-09-07T15:00:00Z"))) // Monday 23:00
        precondition(window.allowsAdmission(at: date("2026-09-07T16:59:59Z"))) // Tuesday 00:59
        precondition(!window.allowsAdmission(at: date("2026-09-07T17:00:00Z"))) // Exclusive end
        precondition(!window.allowsAdmission(at: date("2026-09-06T16:30:00Z"))) // Monday morning belongs to Sunday
        window.mode = .exceptWithin
        precondition(!window.allowsAdmission(at: date("2026-09-07T15:00:00Z")))
        window.timeZoneIdentifier = "Invalid/Zone"
        precondition(!window.allowsAdmission())
        window.timeZoneIdentifier = "GMT+0900"
        precondition(!window.isValid)
        window = .init(mode: .onlyWithin, timeZoneIdentifier: "UTC", intervals: [])
        precondition(!window.allowsAdmission())
        window.mode = .unrestricted
        precondition(window.allowsAdmission())
        window.intervals = [.init(startMinute: 0, endMinute: 0)]
        precondition(!window.isValid)
        window.intervals[0].allDay = true
        precondition(window.isValid)
        window.mode = .onlyWithin
        precondition(window.allowsAdmission())
        window = .init(mode: .onlyWithin, timeZoneIdentifier: "America/New_York", intervals: [.init(startMinute: 90, endMinute: 120)])
        precondition(window.allowsAdmission(at: date("2026-11-01T05:45:00Z")))
        precondition(window.allowsAdmission(at: date("2026-11-01T06:45:00Z"))) // Repeated hour
        precondition(!window.allowsAdmission(at: date("2026-11-01T07:00:00Z")))
        let decoded = try JSONDecoder().decode(DispatchParticipationWindow.self, from: JSONEncoder().encode(window))
        precondition(decoded == window)
        print("Dispatch participation window: boundary, overnight weekday, invalid policy, full-day and DST checks passed")
    }
}
