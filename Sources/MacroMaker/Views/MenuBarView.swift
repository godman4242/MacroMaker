import SwiftUI

/// The panel that opens from the menu bar icon.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Macro Maker").font(.headline)
                Spacer()
                if model.isAnythingActive {
                    Label("Running", systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            if !model.permissions.isAccessibilityTrusted {
                Button {
                    model.permissions.requestAccessibility()
                    model.permissions.open(.accessibility)
                } label: {
                    Label("Grant Accessibility access…", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.link)
            }

            Divider()

            FeatureRow(title: "Auto Clicker", icon: "cursorarrow.click.2", phase: model.autoClicker.session.phase,
                       shortcut: model.hotkeys.label(for: .toggleAutoClicker)) {
                model.autoClicker.toggle(.button)
            }
            FeatureRow(title: "Key Presser", icon: "keyboard", phase: model.keyPresser.session.phase,
                       shortcut: model.hotkeys.label(for: .toggleKeyPresser)) {
                model.keyPresser.toggle(.button)
            }
            FeatureRow(title: "Web Target", icon: "globe", phase: model.webClicker.session.phase,
                       shortcut: model.hotkeys.label(for: .toggleWebTarget)) {
                model.webClicker.toggle(.button)
            }
            FeatureRow(title: "Record Macro", icon: "record.circle", phase: model.recorder.isRecording ? .running : .idle,
                       shortcut: model.hotkeys.label(for: .toggleRecording)) {
                model.toggleRecording()
            }
            FeatureRow(title: "Play Macro", icon: "play.circle", phase: model.player.session.phase,
                       shortcut: model.hotkeys.label(for: .togglePlayback), isDisabled: model.macro == nil) {
                model.togglePlayback(.button)
            }

            Divider()

            Button {
                model.stopAll()
            } label: {
                HStack {
                    Text("Stop Everything")
                    Spacer()
                    if let shortcut = model.hotkeys.label(for: .stopAll) {
                        Text(shortcut).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(!model.isAnythingActive)

            if let deadline = model.scheduleDeadline {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .foregroundStyle(.orange)
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        Text("\(model.schedule.feature.title) starts at \(ScheduleRules.clockString(seconds: model.schedule.seconds)) — \(ScheduleRules.describe(deadline: deadline, from: context.date))")
                            .font(.caption)
                    }
                    Spacer()
                    Button("Cancel") {
                        var updated = model.schedule
                        updated.enabled = false
                        model.setSchedule(updated)
                    }
                    .controlSize(.small)
                }
            }

            Divider()

            HStack {
                Button("Open Macro Maker") { WindowCoordinator.shared.show(.main) }
                Spacer()
                Button {
                    WindowCoordinator.shared.show(.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

private struct FeatureRow: View {
    let title: String
    let icon: String
    let phase: RunPhase
    let shortcut: String?
    var isDisabled = false
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(phase.isActive ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button(phase.isActive ? "Stop" : "Start", action: toggle)
                .controlSize(.small)
                .disabled(isDisabled && !phase.isActive)
        }
    }

    private var status: String {
        switch phase {
        case .idle: shortcut.map { "Shortcut \($0)" } ?? "No shortcut"
        case let .countdown(secondsLeft): "Starting in \(secondsLeft)…"
        case .running: "Running"
        case .paused: "Paused"
        }
    }
}
