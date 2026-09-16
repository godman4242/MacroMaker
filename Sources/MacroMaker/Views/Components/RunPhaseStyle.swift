import SwiftUI

extension RunPhase {
    /// The colour that tells the current state at a glance: green = working, orange = about to,
    /// indigo = you paused it, red = something's wrong (shown by the hero banner's icon too).
    var tint: Color {
        switch self {
        case .idle: .secondary
        case .countdown: .orange
        case .running: .green
        case .paused: .indigo
        }
    }

    var statusLabel: String {
        switch self {
        case .idle: "Idle"
        case .countdown(let secondsLeft): "Starting in \(secondsLeft)…"
        case .running: "Running"
        case .paused: "Paused — you took over"
        }
    }
}
