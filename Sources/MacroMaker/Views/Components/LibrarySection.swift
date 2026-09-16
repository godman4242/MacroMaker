import SwiftUI

/// The macro library: every `.macromaker` kept in ~/Library/Application Support/Macro Maker/Macros,
/// listed with favorites-first order, search, and a per-macro play hotkey (capped at 10).
struct LibrarySection: View {
    @Environment(AppModel.self) private var model

    @State private var search = ""
    @State private var renaming: MacroRecord?
    @State private var renameText = ""
    @State private var deleting: MacroRecord?

    private var library: MacroLibrary { model.library }

    private var shownRecords: [MacroRecord] {
        let sorted = library.sortedRecords
        let needle = search.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    private var hotkeysUsed: Int { model.hotkeys.dynamicActions.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Library")
                    .font(.headline)
                Text("\(library.records.count) macro\(library.records.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    guard let macro = model.macro else { return }
                    if library.add(macro, named: macro.name) == nil {
                        NSSound.beep()
                    }
                } label: {
                    Label("Add Current", systemImage: "plus")
                }
                .help("Save the macro above into the library")
                .disabled(model.macro == nil || model.recorder.isRecording)
                Button {
                    revealFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show the library folder in Finder")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if let problem = library.lastError {
                StatusMessage(kind: .error, text: problem)
                    .padding(.horizontal, 16)
            }
            if hotkeysUsed >= HotkeyAction.maxMacroHotkeys {
                StatusMessage(kind: .warning,
                              text: "All \(HotkeyAction.maxMacroHotkeys) macro hotkeys are in use — remove one to add another.")
                    .padding(.horizontal, 16)
            }

            if library.records.isEmpty {
                Text("Nothing saved yet. Record or open a macro, then “Add Current” keeps it here — with its own hotkey if you like.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                TextField("Search library", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 16)

                List(shownRecords) { record in
                    row(for: record)
                }
                .frame(minHeight: 120, maxHeight: 220)
            }
        }
        .padding(.bottom, 12)
        .alert("Rename Macro", isPresented: renameBinding) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let renaming { library.rename(renaming, to: renameText) }
            }
            .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete “\(deleting?.name ?? "")”?", isPresented: deleteBinding) {
            Button("Delete", role: .destructive) {
                if let deleting {
                    model.setMacroHotkey(false, for: deleting)
                    library.delete(deleting)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its .macromaker file is deleted too. This can't be undone.")
        }
    }

    @ViewBuilder private func row(for record: MacroRecord) -> some View {
        HStack(spacing: 8) {
            Button {
                library.setFavorite(record, !record.isFavorite)
            } label: {
                Image(systemName: record.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(record.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .help(record.isFavorite ? "Remove from favorites" : "Favorite — pins it to the top")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(record.name).lineLimit(1)
                    if record.isOrphan {
                        Text("file missing")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Text("\(record.eventCount.formatted()) events · \(record.durationSeconds.formatted(.number.precision(.fractionLength(1)))) s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()

            if let action = model.macroHotkeyAction(for: record) {
                HotkeyField(action: action)
                    .scaleEffect(0.85, anchor: .trailing)
                    .frame(width: 120)
            } else {
                Toggle("Hotkey", isOn: hotkeyBinding(for: record))
                    .toggleStyle(.checkbox)
                    .disabled(record.isOrphan || model.hotkeys.dynamicActions.count >= HotkeyAction.maxMacroHotkeys)
                    .help("Give this macro its own global shortcut (max \(HotkeyAction.maxMacroHotkeys))")
            }

            Button("Play") { model.playMacro(id: record.id) }
                .disabled(record.isOrphan)
            Button("Edit…") { model.loadFromLibrary(record) }
                .disabled(record.isOrphan)
                .help("Load into the editor above")

            Menu {
                Button("Duplicate") { library.duplicate(record) }
                    .disabled(record.isOrphan)
                Button("Rename…") {
                    renaming = record
                    renameText = record.name
                }
                Divider()
                Button("Delete…", role: .destructive) { deleting = record }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.vertical, 2)
    }

    private func hotkeyBinding(for record: MacroRecord) -> Binding<Bool> {
        Binding(
            get: { model.macroHotkeyAction(for: record) != nil },
            set: { enabled in
                if !model.setMacroHotkey(enabled, for: record) {
                    NSSound.beep()
                }
            }
        )
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private func revealFolder() {
        guard let folder = MacroLibrary.folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
