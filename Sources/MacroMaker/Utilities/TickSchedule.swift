import Foundation

/// Timing math for repeating actions, kept pure so it can be tested.
enum TickSchedule {
    /// No action ever repeats faster than once per millisecond.
    static let minimumDelay: TimeInterval = 0.001

    /// The delay before the next tick. `random` is in -1...1 and scales the ± jitter.
    static func delay(interval: TimeInterval, jitter: TimeInterval, random: Double) -> TimeInterval {
        max(minimumDelay, interval + jitter * random)
    }

    /// Drift-free deadlines: each tick is scheduled from the previous *deadline*, not from when the
    /// work finished. If the thread fell more than a whole tick behind (system stall), it resyncs
    /// to now instead of firing a burst of catch-up clicks.
    static func nextDeadline(previous: UInt64, delay: UInt64, now: UInt64) -> UInt64 {
        let candidate = previous + delay
        return candidate + delay < now ? now : candidate
    }

    /// How long a click or key press is held down: long enough for games that poll input once a
    /// frame, never more than a quarter of the interval.
    static func pressDuration(interval: TimeInterval) -> TimeInterval {
        min(0.010, interval / 4)
    }
}
