import Foundation

/// Whether a run should stop because the user switched away from the app it started in.
enum FrontmostStopRule {
    /// Stops only when both snapshots exist and differ; a missing sample never stops the run.
    static func changed(from initial: String?, to current: String?) -> Bool {
        guard let initial, let current else { return false }
        return initial != current
    }
}

/// Delayed start: a button start counts down base + extra seconds; hotkeys skip the countdown.
enum DelayedStart {
    static func total(base: Int, extra: Double) -> Int {
        max(0, base) + max(0, Int(extra.rounded()))
    }
}
