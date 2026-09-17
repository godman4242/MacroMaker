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
        // Set the wall-clock time on the day rather than adding raw seconds to midnight. A day
        // is 23 or 25 hours long across a daylight-saving transition, so midnight + 7h is 06:00
        // or 08:00 — a 07:00 start fired an hour out twice a year (measured: hour 8 on
        // 2026-03-29 in Europe/London). The `> now` comparison is kept strict so "exactly the
        // configured second" still counts as passed.
        let todayAt = at(clamped, on: day, calendar: calendar)
        if todayAt > now { return todayAt }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
        return at(clamped, on: tomorrow, calendar: calendar)
    }

    private static func at(_ secondsIntoDay: Double, on day: Date, calendar: Calendar) -> Date {
        let whole = Int(secondsIntoDay)
        return calendar.date(bySettingHour: whole / 3600, minute: whole / 60 % 60, second: whole % 60,
                             of: day, matchingPolicy: .nextTime, direction: .forward)
            ?? day.addingTimeInterval(secondsIntoDay)
    }

    /// Whether a schedule that was armed when the app last quit should stay armed on this launch.
    ///
    /// True while its time is still ahead TODAY: the user set 19:00, the app was relaunched at
    /// 18:00, and the run should still happen. False once today's time has gone, where re-arming
    /// would surprise-fire tomorrow. Launch used to disarm unconditionally, which meant the
    /// feature only ever worked inside the single session it was switched on in — and for a
    /// menu-bar login-item app, quit/relaunch is the normal path.
    static func staysArmedOnLaunch(_ schedule: AppModel.Schedule, now: Date,
                                   calendar: Calendar = .current) -> Bool {
        guard schedule.enabled, let next = nextOccurrence(of: schedule, from: now, calendar: calendar)
        else { return false }
        return calendar.isDate(next, inSameDayAs: now)
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
