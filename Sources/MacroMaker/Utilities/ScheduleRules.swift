import Foundation

/// Clock-time scheduling math, kept pure so it's testable.
enum ScheduleRules {
    /// Parses "7:30", "18:05" into seconds since the start of today, clamped into the day.
    /// Returns nil for anything that doesn't look like a clock time.
    static func parseClock(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2,
              let hours = Int(parts[0]), let minutes = Int(parts[1]),
              (0...23).contains(hours), (0...59).contains(minutes)
        else { return nil }
        return Double(hours * 3600 + minutes * 60)
    }

    /// Formats seconds-from-today as "h:mm" 24-hour, clamped into the day.
    static func clockString(seconds: Double) -> String {
        let clamped = min(max(0, seconds), 24 * 3600 - 1)
        return String(format: "%d:%02d", Int(clamped) / 3600, Int(clamped) / 60 % 60)
    }

    /// Seconds (0..<86400) → today's or tomorrow's occurrence, whichever is in the future.
    /// Uses the *wall clock* on purpose: a 7:00 start must survive sleep/drift, so this is a
    /// Date, not a DispatchTime. Returns nil only when the schedule is off.
    static func nextOccurrence(of schedule: AppModel.Schedule, from now: Date,
                               calendar: Calendar = .current) -> Date? {
        guard schedule.enabled else { return nil }
        let clamped = min(max(0, schedule.seconds), 24 * 3600 - 1)
        let day = calendar.startOfDay(for: now)
        let todayAt = day.addingTimeInterval(clamped)
        return todayAt > now ? todayAt : calendar.date(byAdding: .day, value: 1, to: todayAt)
    }

    /// Human countdown for the menu-bar label.
    static func describe(deadline: Date, from now: Date) -> String {
        let interval = deadline.timeIntervalSince(now)
        guard interval > 0 else { return "now" }
        let minutes = Int(interval / 60)
        if minutes >= 60 * 24 { return "in \(minutes / (60 * 24)) d" }
        if minutes >= 60 { return "in \(minutes / 60) h \(minutes % 60) min" }
        if minutes >= 1 { return "in \(minutes) min" }
        return "in \(Int(interval) + 1) s"
    }
}
