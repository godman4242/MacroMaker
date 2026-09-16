/// Lifecycle shared by every start/stop feature.
enum RunPhase: Equatable, Sendable {
    case idle
    /// Waiting before starting, so the user can move away from Macro Maker's window.
    case countdown(secondsLeft: Int)
    case running
    /// Stopped mid-run because the user took over; the feature holds no worker but can resume.
    case paused

    var isActive: Bool { self != .idle }
}

/// Where a start request came from. Buttons get a countdown (the cursor and keyboard focus are
/// on Macro Maker itself); hotkeys start instantly because the user is already where they want.
enum StartTrigger: Sendable {
    case button
    case hotkey
}
