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
        /// Edit a mouse step's click point ("x, y" as text).
        case editPoint(Int)
        /// Insert a wait of a chosen duration after this step.
        case insertWait(after: Int)

        var index: Int {
            switch self {
            case let .renameText(index), let .editTime(index), let .insertText(index),
                 let .editPoint(index), let .insertWait(index): index
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
                // No phase condition — the chain's launch refusal happens BEFORE a run
                // starts, and its run-time failure lands the same hop that ends the run.
                // Cleared on every launch and every stop, like AutoClicker's runWarning.
                if let warning = player.runWarning {
                    StatusMessage(kind: .warning, text: warning)
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
            Toggle("Follow the window", isOn: $player.settings.followWindow)
                .help("Clicks recorded inside a window land at the same spot inside it wherever it has moved. Off = replay at the exact recorded screen positions.")
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
        if isMouseStep(index) {
            Button("Edit Coordinates…") {
                editor = .editPoint(index)
                editorDraft = pointText(for: index)
            }
        }
        Divider()
        Button("Move Up") { moveStep(at: index, offset: -1) }
            .disabled(index == 0)
        Button("Move Down") { moveStep(at: index, offset: 1) }
            .disabled(index >= (model.macro?.events.count ?? 0) - 1)
        Divider()
        Button("Insert Wait…") {
            editor = .insertWait(after: index)
            editorDraft = "0.5"
        }
        Button("Insert Typed Text…") {
            insertText(after: index)
        }
        insertRunMacroMenu(after: index)
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
        case .editPoint: "Edit Click Point (x, y)"
        case .insertWait: "Insert Wait (seconds)"
        case nil: ""
        }
    }

    private var editorHint: String {
        switch editor {
        case .renameText: "The text typed for this key step. Leave empty to play the raw key code."
        case .editTime: "Seconds since the start of the macro, e.g. 1.25"
        case .insertText: "Typed one character at a time after the selected step, at typing speed."
        case .editPoint: "Screen point from the top-left of the main display, e.g. 512, 384"
        case .insertWait: "A pause after the selected step; later steps shift back by this much."
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
        case .editPoint: return parsePoint(editorDraft) != nil
        case .insertWait:
            let seconds = Double(editorDraft.trimmingCharacters(in: .whitespaces))
            return seconds?.isFinite == true && (seconds ?? 0) > 0
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
        case .editPoint:
            // `parsePoint` validated the draft (editorIsValid gates Apply); a failed parse here
            // leaves the step alone rather than doing nothing at all.
            if let point = parsePoint(editorDraft) {
                updated.events[index] = MacroLibraryRules.withPoint(updated.events[index],
                                                                    x: point.x, y: point.y)
            }
        case .insertWait:
            if let seconds = Double(editorDraft.trimmingCharacters(in: .whitespaces)),
               seconds.isFinite, seconds > 0 {
                let insertAt = index + 1
                updated.events = MacroLibraryRules.shiftedForWait(events: macro.events,
                                                                  atIndex: insertAt, seconds: seconds)
            }
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

    /// Whether the step has an editable point (mouse transitions and cursor moves — the ones
    /// `MacroLibraryRules.withPoint` rewrites).
    private func isMouseStep(_ index: Int) -> Bool {
        guard let macro = model.macro, index < macro.events.count else { return false }
        switch macro.events[index].action {
        case .mouseDown, .mouseUp, .move: return true
        default: return false
        }
    }

    private func pointText(for index: Int) -> String {
        guard let macro = model.macro, index < macro.events.count else { return "" }
        switch macro.events[index].action {
        case let .mouseDown(_, point, _), let .mouseUp(_, point, _), let .move(point):
            // Clamped before conversion: a huge-but-finite coordinate traps Int(_:).
            let bound = MacroEvent.maximumCoordinate
            let x = point.x.isFinite ? Int(min(max(point.x, -bound), bound)) : 0
            let y = point.y.isFinite ? Int(min(max(point.y, -bound), bound)) : 0
            return "\(x), \(y)"
        default: return ""
        }
    }

    /// Parses "x, y" (comma or space separated) into a point; nil when it isn't one.
    ///
    /// Non-finite is refused and huge-but-finite values are CLAMPED to the event coordinate
    /// bound: "1e300" is finite, so accepting it here stored a value that trapped `Int(point.x)`
    /// in the step summary on the next render (exit 133, whole app). Clamped to the same bound
    /// the file decoder enforces, so an edited step can never be one the file format refuses.
    private func parsePoint(_ text: String) -> CGPoint? {
        let parts = text.split(whereSeparator: { ",;".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count == 2,
              let x = Double(parts[0]), let y = Double(parts[1]),
              x.isFinite, y.isFinite else { return nil }
        let bound = MacroEvent.maximumCoordinate
        return CGPoint(x: min(max(x, -bound), bound), y: min(max(y, -bound), bound))
    }

    /// Move Up/Down: the pure rule refuses the bounds and pair-stranding swaps silently,
    /// so a refused swap simply changes nothing.
    private func moveStep(at index: Int, offset: Int) {
        guard let macro = model.macro, index >= 0, index < macro.events.count else { return }
        var updated = macro
        updated.events = MacroLibraryRules.moved(updated.events, at: index, offset: offset)
        model.macro = updated
        model.autosaveMacro()
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

    /// Insert Run Macro: a submenu of the library, so a chain step is one right-click away.
    /// The macro being edited is offered too — playing yourself is a CYCLE the launch check
    /// catches and names, so it stays visible (and its own menu item says so) rather than
    /// disappearing depending on what's loaded. The one thing a submenu buys over the sheet
    /// machinery is not needing a picker: the library is already the picker.
    @ViewBuilder private func insertRunMacroMenu(after index: Int) -> some View {
        let others = model.library.sortedRecords
        Menu {
            ForEach(others) { record in
                Button(record.name) {
                    insertRunMacro(after: index, macroID: record.id)
                }
            }
        } label: {
            Label("Insert Run Macro…", systemImage: "link")
        } primaryAction: {
            // A primary action inserts the first (favorite-first) record; the submenu is the
            // full list. Disabled outright when the library is empty.
            if let first = others.first {
                insertRunMacro(after: index, macroID: first.id)
            }
        }
        .disabled(others.isEmpty)
    }

    private func insertRunMacro(after index: Int, macroID: UUID) {
        guard let macro = model.macro, index >= 0, index < macro.events.count else { return }
        var updated = macro
        updated.events = MacroLibraryRules.insertRunMacro(events: macro.events,
                                                          atIndex: index, macroID: macroID)
        model.macro = updated
        model.autosaveMacro()
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
