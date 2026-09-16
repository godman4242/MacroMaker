import SwiftUI

struct RecorderView: View {
    @Environment(AppModel.self) private var model

    private struct Row: Identifiable {
        let id: Int
        let event: MacroEvent
    }

    var body: some View {
        @Bindable var player = model.player
        let recorder = model.recorder
        let isPlaying = player.session.phase.isActive

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    model.toggleRecording()
                } label: {
                    Label(recorder.isRecording ? "Stop Recording" : "Record",
                          systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(isPlaying)

                Spacer()

                Button("Open…") { model.openMacroWithPanel() }
                    .disabled(recorder.isRecording || isPlaying)
                Button("Save…") { model.saveMacro() }
                    .disabled(model.macro == nil || recorder.isRecording)
                Button(role: .destructive) {
                    model.clearMacro()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear this macro")
                .disabled(model.macro == nil || recorder.isRecording || isPlaying)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 10) {
                if let message = recorder.errorMessage {
                    HStack {
                        StatusMessage(kind: .error, text: message)
                        Spacer()
                        Button("Open Input Monitoring") { model.permissions.open(.inputMonitoring) }
                    }
                }
                if let message = model.fileError {
                    StatusMessage(kind: .error, text: message)
                }
                if recorder.isRecording {
                    StatusMessage(kind: .info, text: "Recording — click and type in other apps. Input into Macro Maker itself isn't recorded.")
                } else if let macro = model.macro {
                    HStack(spacing: 12) {
                        TextField("Name", text: Binding(get: { macro.name }, set: { model.macro?.name = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                        Text("\(macro.events.count.formatted()) events · \(macro.duration.formatted(.number.precision(.fractionLength(1)))) s")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    playbackOptions(player: player)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            eventTable

            HStack(spacing: 16) {
                LabeledContent("Record") { HotkeyField(action: .toggleRecording) }
                LabeledContent("Play") { HotkeyField(action: .togglePlayback) }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            RunControls(session: player.session,
                        startTitle: "Play Macro",
                        hotkey: .togglePlayback,
                        detail: playbackDetail,
                        isStartDisabled: model.macro == nil || recorder.isRecording) {
                model.togglePlayback(.button)
            }
        }
    }

    @ViewBuilder private func playbackOptions(player: MacroPlayer) -> some View {
        @Bindable var player = player
        HStack(spacing: 16) {
            Toggle("Loop until stopped", isOn: $player.settings.loopForever)
            if !player.settings.loopForever {
                Stepper("Repeat \(player.settings.repeatCount)×", value: $player.settings.repeatCount, in: 1...10_000)
                    .monospacedDigit()
            }
            Picker("Speed", selection: $player.settings.speed) {
                ForEach([0.25, 0.5, 1, 2, 4], id: \.self) { speed in
                    Text("\(speed.formatted())×").tag(speed)
                }
            }
            .fixedSize()
            Toggle("Humanise", isOn: $player.settings.humanizer.enabled)
                .help("Jitters the gap before each replayed event")
        }
        .disabled(player.session.phase.isActive)
    }

    @ViewBuilder private var eventTable: some View {
        let events = model.recorder.isRecording ? model.recorder.liveEvents : (model.macro?.events ?? [])
        if events.isEmpty {
            ContentUnavailableView {
                Label(model.recorder.isRecording ? "Waiting for input…" : "No macro yet", systemImage: "record.circle")
            } description: {
                Text("Press Record, then click and type in any app. Press Stop Recording (or its shortcut) when done, then Play to replay it with the original timing.")
            }
            .frame(maxHeight: .infinity)
        } else {
            Table(events.enumerated().map { Row(id: $0.offset, event: $0.element) }) {
                TableColumn("#") { row in
                    Text("\(row.id + 1)").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(44)
                TableColumn("Time") { row in
                    Text("\(row.event.time.formatted(.number.precision(.fractionLength(3)))) s").monospacedDigit()
                }
                .width(80)
                TableColumn("Event") { row in
                    Text(row.event.summary)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var playbackDetail: String {
        let player = model.player
        let total = model.macro?.events.count ?? 0
        let pass = player.settings.loopForever ? "pass \(player.progress.iteration + 1)" : "pass \(min(player.progress.iteration + 1, player.settings.repeatCount)) of \(player.settings.repeatCount)"
        return "\(pass) · event \(player.progress.eventIndex) of \(total)"
    }
}
