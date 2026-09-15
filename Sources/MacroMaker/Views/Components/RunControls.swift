import SwiftUI

/// The big Start/Stop button pinned to the bottom of each tab, with live status.
struct RunControls: View {
    let session: RunSession
    let startTitle: String
    let hotkey: HotkeyAction
    /// Live counter while running, e.g. "1,234 clicks".
    var detail: String?
    /// Whether the Start button counts down first (see `StartTrigger`).
    var usesCountdown = true
    var isStartDisabled = false
    let toggle: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            Button(action: toggle) {
                Label(buttonTitle, systemImage: session.phase == .idle ? "play.fill" : "stop.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(session.phase == .idle ? .accentColor : .red)
            .disabled(session.phase == .idle && isStartDisabled)

            HStack(spacing: 6) {
                statusLine
                Spacer()
                if let shortcut = model.hotkeys.label(for: hotkey) {
                    Text("Shortcut \(shortcut)").monospacedDigit()
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var buttonTitle: String {
        switch session.phase {
        case .idle: startTitle
        case let .countdown(secondsLeft): "Starting in \(secondsLeft)… (click to cancel)"
        case .running: "Stop"
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch session.phase {
        case .idle:
            if usesCountdown, let shortcut = model.hotkeys.label(for: hotkey) {
                Text("Starts after \(RunSession.countdownSeconds) s — \(shortcut) starts instantly")
            } else if let detail {
                Text(detail)
            } else {
                Text("Idle")
            }
        case .countdown:
            Text("Switch to the app you want to control")
        case .running:
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 7, height: 7)
                if let startedAt = session.startedAt {
                    Text(startedAt, style: .timer).monospacedDigit()
                }
                if let detail {
                    Text("· \(detail)").monospacedDigit()
                }
            }
        }
    }
}
