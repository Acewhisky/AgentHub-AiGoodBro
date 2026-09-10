import Foundation

/// Explicit, persisted gate for admitting new dispatch tasks.
/// Warm-up and quota refresh intentionally do not consult this policy.
struct DispatchParticipationWindow: Codable, Equatable {
    enum Mode: String, Codable { case unrestricted, onlyWithin, exceptWithin }
    struct Interval: Codable, Equatable {
        var startMinute: Int
        var endMinute: Int
        var allDays: Bool = true
        var weekdays: Set<Int> = []  // ISO weekday: 1 = Monday ... 7 = Sunday
        var allDay: Bool = false
    }

    var mode: Mode = .unrestricted
    private static let supportedTimeZones = Set(TimeZone.knownTimeZoneIdentifiers).union(["UTC", "GMT"])
    var timeZoneIdentifier: String = supportedTimeZones.contains(TimeZone.current.identifier) ? TimeZone.current.identifier : "UTC"
    var intervals: [Interval] = []

    var isValid: Bool {
        guard Self.supportedTimeZones.contains(timeZoneIdentifier), TimeZone(identifier: timeZoneIdentifier) != nil, intervals.count <= 32 else { return false }
        return intervals.allSatisfy {
            (0...1439).contains($0.startMinute) && (0...1439).contains($0.endMinute)
                && ($0.allDay || $0.startMinute != $0.endMinute)
                && $0.weekdays.allSatisfy { (1...7).contains($0) }
                && ($0.allDays || !$0.weekdays.isEmpty)
        }
    }

    func allowsAdmission(at date: Date = Date()) -> Bool {
        guard isValid else { return false }
        guard mode != .unrestricted else { return true }
        guard let zone = TimeZone(identifier: timeZoneIdentifier) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let weekday = calendar.component(.weekday, from: date)
        let isoWeekday = weekday == 1 ? 7 : weekday - 1
        let previousWeekday = isoWeekday == 1 ? 7 : isoWeekday - 1
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let matched = intervals.contains { interval in
            let today = interval.allDays || interval.weekdays.contains(isoWeekday)
            if interval.allDay { return today }
            if interval.startMinute < interval.endMinute {
                return today && minute >= interval.startMinute && minute < interval.endMinute
            }
            // Weekdays name the day on which a cross-midnight interval starts.
            let yesterday = interval.allDays || interval.weekdays.contains(previousWeekday)
            return (today && minute >= interval.startMinute) || (yesterday && minute < interval.endMinute)
        }
        return mode == .onlyWithin ? matched : !matched
    }
}
