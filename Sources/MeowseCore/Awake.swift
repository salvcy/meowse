import Foundation

/// Keep Awake and Wiggle Cursor helpers.
public enum Awake {

    /// The menu's one-click lengths.
    public static let pills: [TimeInterval] = [15 * 60, 30 * 60, 3600, 2 * 3600, 4 * 3600]

    // "Until…": an end time on the quarter hour, from 15 minutes to a day ahead.

    /// The end time offered first: an hour from now, on the next quarter hour.
    public static func untilStart(now: Date, calendar: Calendar = .current) -> Date {
        quarter(now.addingTimeInterval(3600), up: true, calendar)
    }

    /// The quarter hour after or before `time`, kept in range.
    public static func untilStep(_ time: Date, up: Bool, now: Date, calendar: Calendar = .current) -> Date {
        let next = up ? quarter(time, up: false, calendar).addingTimeInterval(15 * 60)
                      : quarter(time, up: true, calendar).addingTimeInterval(-15 * 60)
        let earliest = quarter(now.addingTimeInterval(15 * 60), up: true, calendar)
        let latest = quarter(now.addingTimeInterval(24 * 3600), up: false, calendar)
        return min(max(next, earliest), latest)
    }

    /// `date` rounded to a quarter hour, up or down; one already on it stays.
    private static func quarter(_ date: Date, up: Bool, _ calendar: Calendar) -> Date {
        var c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let onQuarter = c.minute! % 15 == 0 && c.second == 0
        c.minute = c.minute! / 15 * 15
        c.second = 0
        let down = calendar.date(from: c)!
        return up && !onQuarter ? down.addingTimeInterval(15 * 60) : down
    }

    /// Idle intervals after which the cursor is wiggled.
    public static let wiggleIntervals: [TimeInterval] = [30, 60, 120, 240]

    /// What the wiggle timer does when it fires: wiggle only if the user has
    /// been idle for the interval, and re-arm for the time left until they
    /// would be. An active user costs at most one wakeup per interval.
    public static func wigglePlan(idle: TimeInterval, interval: TimeInterval) -> (wiggleNow: Bool, nextCheck: TimeInterval) {
        // 5% slack so timer leeway can't skip a cycle.
        if idle >= interval * 0.95 {
            return (true, interval)
        }
        return (false, max(1, interval - idle))
    }

    /// "Until Turned Off", "15 Minutes", "1 Hour", "2 Hours".
    public static func durationLabel(_ seconds: TimeInterval) -> String {
        if seconds <= 0 { return "Until Turned Off" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return minutes == 1 ? "1 Minute" : "\(minutes) Minutes" }
        let hours = minutes / 60, rest = minutes % 60
        let h = hours == 1 ? "1 Hour" : "\(hours) Hours"
        return rest == 0 ? h : "\(h) \(rest) Minutes"
    }

    /// "30 Seconds", "1 Minute", "4 Minutes".
    public static func intervalLabel(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds)) Seconds" }
        return durationLabel(seconds)
    }

    /// The menu's lengths: "15m", "1h 30m", "Indefinitely" for until turned off.
    public static func shortLabel(_ seconds: TimeInterval) -> String {
        if seconds <= 0 { return "Indefinitely" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Time left, as short as the picker's labels: "52m left", "1h 5m left".
    public static func remainingLabel(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        return shortLabel(TimeInterval(minutes * 60)) + " left"
    }
}
