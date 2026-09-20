import SwiftUI

struct RecorderView: View {
    @Environment(AppModel.self) private var model

    private struct Row: Identifiable {
        let id: Int
        let event: MacroEvent
    }

    /// The selected event in the table; nil while recording (live events aren't editable).
    @State private var selectedEvent: Int?
    /// The sheet currently editing one step (nil = closed).
    @State private var editor: StepEditor?
    @State private var editorDraft = ""

    private enum StepEditor: Hashable {
        case renameText(Int)
        case editTime(Int)
        /// Ask for the text FIRST, then insert it after this step.
        case insertText(after: Int)

        var index: Int {
            switch self {
            case let .renameText(index), let .editTime(index), let .insertText(index): index
            }
        }
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

            LibrarySection()

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
        .sheet(isPresented: editorBinding) { editorSheet }
    }

    @ViewBuilder private func playbackOptions(player: MacroPlayer) -> some View {
        @Bindable var player = player
        HStack(spacing: 16) {
            Toggle("Loop until stopped", isOn: $player.settings.loopForever)
            if !player.settings.loopForever, !player.settings.stopOnHotkey {
                Stepper("Repeat \(player.settings.repeatCount)×", value: $player.settings.repeatCount, in: 1...10_000)
                    .monospacedDigit()
            }
            Toggle("Until stop shortcut", isOn: $player.settings.stopOnHotkey)
                .help("Repeats until you press the Stop-the-Current-Run shortcut (Settings ▸ Keyboard shortcuts, default F6).")
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
            .frame(minHeight: 240)
        } else {
            Table(events.enumerated().map { Row(id: $0.offset, event: $0.element) },
                  selection: $selectedEvent) {
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
            // While recording, this table shows `recorder.liveEvents` — but every editing action
            // it offers indexes and rewrites `model.macro`, a DIFFERENT array, and then autosaves
            // it. Deleting "step 3" of a live recording silently deleted step 3 of the PREVIOUS
            // macro and overwrote the autosave. The editing affordances are therefore gated on
            // the same flag the data source uses. (`selectedEvent`'s comment always claimed live
            // events aren't editable; nothing enforced it.)
            .contextMenu(forSelectionType: Int.self) { ids in
                if let index = ids.first, !model.recorder.isRecording {
                    contextMenuItems(for: index)
                }
            } primaryAction: { ids in
                if let index = ids.first, !model.recorder.isRecording {
                    editor = .renameText(index)
                    editorDraft = renameText(for: index)
                }
            }
            // The recorder is the one tab with a second scroller: this Table scrolls its own
            // rows inside the page that the detail-root ScrollView scrolls. That needs an
            // explicit height range — inside a ScrollView nothing proposes a height, so
            // `maxHeight: .infinity` would resolve to the Table's ideal size and either
            // collapse it or let a long macro grow it without bound. A fixed range keeps the
            // table a predictable block: long macros scroll inside it, the page scrolls
            // around it, and neither scroller can swallow the other.
            .frame(minHeight: 240, maxHeight: 420)
        }
    }

    @ViewBuilder private func contextMenuItems(for index: Int) -> some View {
        Button("Rename Step…") {
            editor = .renameText(index)
            editorDraft = renameText(for: index)
        }
        Button("Edit Time…") {
            editor = .editTime(index)
            editorDraft = timeText(for: index)
        }
        Divider()
        Button("Insert Wait 0.5 s After") {
            insertWait(after: index, seconds: 0.5)
        }
        Button("Insert Wait 1 s After") {
            insertWait(after: index, seconds: 1)
        }
        Button("Insert Typed Text…") {
            insertText(after: index)
        }
        Divider()
        Button("Delete Step", role: .destructive) {
            deleteStep(at: index)
        }
    }

    private var editorBinding: Binding<Bool> {
        Binding(get: { editor != nil }, set: { if !$0 { editor = nil } })
    }

    private var editorTitle: String {
        switch editor {
        case .renameText: "Rename Step"
        case .editTime: "Edit Start Time (seconds)"
        case .insertText: "Insert Typed Text"
        case nil: ""
        }
    }

    private var editorHint: String {
        switch editor {
        case .renameText: "The text typed for this key step. Leave empty to play the raw key code."
        case .editTime: "Seconds since the start of the macro, e.g. 1.25"
        case .insertText: "Typed one character at a time after the selected step, at typing speed."
        case nil: ""
        }
    }

    @ViewBuilder private var editorSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editorTitle).font(.headline)
            TextField("Value", text: $editorDraft)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 260)
            Text(editorHint).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { editor = nil }
                Button("Apply") { applyEditor() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!editorIsValid)
            }
        }
        .padding(20)
    }

    private var editorIsValid: Bool {
        guard let editor else { return false }
        switch editor {
        case .renameText: return true   // clearing the text is a valid "play raw key"
        case .editTime: return (Double(editorDraft.trimmingCharacters(in: .whitespaces))?.isFinite ?? false)
        case .insertText: return !editorDraft.isEmpty   // inserting nothing is not an edit
        }
    }

    private func applyEditor() {
        guard let editor, let macro = model.macro else { self.editor = nil; return }
        let index = editor.index
        guard index < macro.events.count else { self.editor = nil; return }
        var updated = macro
        switch editor {
        case .renameText:
            let text = editorDraft.trimmingCharacters(in: .whitespaces)
            updated.events[index].textOverride = text.isEmpty ? nil : text
        case .editTime:
            // `.isFinite` as well as `>= 0`: "inf" and "1e400" both parse and both satisfy
            // `t >= 0`, and the value reaches `UInt64(_:)` in the playback loop, which traps.
            if let t = Double(editorDraft.trimmingCharacters(in: .whitespaces)), t.isFinite, t >= 0 {
                updated.events[index].time = t
                // A time edit can reorder the timeline; keep events sorted so playback and the
                // table agree (stable: same-time pairs keep their recorded order).
                updated.events = MacroLibraryRules.sortedByTime(events: updated.events)
            }
        case .insertText:
            updated.events = MacroLibraryRules.insertTypedText(events: macro.events, atIndex: index,
                                                               text: editorDraft)
        }
        model.macro = updated
        model.autosaveMacro()
        self.editor = nil
    }

    private func renameText(for index: Int) -> String {
        guard let macro = model.macro, index < macro.events.count else { return "" }
        return macro.events[index].textOverride ?? ""
    }

    private func timeText(for index: Int) -> String {
        guard let macro = model.macro, index < macro.events.count else { return "" }
        return macro.events[index].time.formatted(.number.precision(.fractionLength(3)))
    }

    private func insertWait(after index: Int, seconds: Double) {
        guard let macro = model.macro, index >= 0, index < macro.events.count else { return }
        let insertAt = index + 1
        let shifted = MacroLibraryRules.shiftedForWait(events: macro.events, atIndex: insertAt, seconds: seconds)
        var updated = macro
        updated.events = shifted
        model.macro = updated
        model.autosaveMacro()
    }

    /// Ask for the text, then insert it — `applyEditor` does the work, shifting later events by
    /// the typed duration exactly as "Insert Wait" does.
    ///
    /// This used to insert a hard-coded "abc" immediately and then open the single-step RENAME
    /// editor on the first inserted keyDown, pre-filled with "abc". `insertTypedText` expands a
    /// word into one keyDown/keyUp pair per character, and the rename editor writes ONE step's
    /// `textOverride` — so whatever the user typed replaced only the "a", and the "b" and "c"
    /// pairs stayed in the macro silently. The control the flow pointed at could not do what the
    /// flow promised. (The draft was also pre-filled with the whole word while the step it
    /// edited held just "a".)
    private func insertText(after index: Int) {
        guard let macro = model.macro, index >= 0, index < macro.events.count else { return }
        editor = .insertText(after: index)
        editorDraft = ""
    }

    private func deleteStep(at index: Int) {
        guard let macro = model.macro, index >= 0, index < macro.events.count else { return }
        var updated = macro
        updated.events.remove(at: index)
        model.macro = updated
        model.autosaveMacro()
    }

    private var playbackDetail: String {
        let player = model.player
        let total = model.macro?.events.count ?? 0
        let pass = player.settings.loopForever ? "pass \(player.progress.iteration + 1)" : "pass \(min(player.progress.iteration + 1, player.settings.repeatCount)) of \(player.settings.repeatCount)"
        return "\(pass) · event \(player.progress.eventIndex) of \(total)"
    }
}
