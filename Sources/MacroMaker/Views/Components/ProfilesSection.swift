import SwiftUI

/// The Settings tab's profile list: save the current state, apply, share as files.
struct ProfilesSection: View {
    let model: AppModel
    @State private var newName = ""
    @State private var searchText = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("Name", text: $newName, prompt: Text("Name this setup…"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveCurrent)
            Button("Save") { saveCurrent() }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Import…") { _ = model.profiles.importWithPanel() }
        }

        if let error = model.profiles.lastError {
            StatusMessage(kind: .error, text: error)
        }

        if !model.profiles.entries.isEmpty {
            TextField("Search", text: $searchText, prompt: Text("Filter profiles…"))
                .textFieldStyle(.roundedBorder)
        }
        ForEach(visible) { entry in
            profileRow(entry)
        }
        if model.profiles.entries.isEmpty {
            Text("No profiles yet — name the current setup above and press Save.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var visible: [ProfileEntry] {
        let query = searchText.lowercased()
        let sorted = model.profiles.sortedEntries
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.name.lowercased().contains(query) }
    }

    private func saveCurrent() {
        model.profiles.save(model.currentProfile(named: newName))
        newName = ""
    }

    @ViewBuilder private func profileRow(_ entry: ProfileEntry) -> some View {
        HStack(spacing: 8) {
            Button {
                model.profiles.setFavorite(entry, !entry.isFavorite)
            } label: {
                Image(systemName: entry.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(entry.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .help(entry.isFavorite ? "Remove from favorites" : "Mark as favorite")
            Text(entry.name)
                .lineLimit(1)
            Spacer()
            Menu {
                Button("Apply") { model.applyProfile(entry) }
                Divider()
                Button("Duplicate") { model.profiles.duplicate(entry) }
                Button("Rename…") { rename(entry) }
                Button("Export…") { model.profiles.exportWithPanel(entry) }
                Divider()
                Button("Delete", role: .destructive) {
                    confirmDelete(entry)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    private func rename(_ entry: ProfileEntry) {
        // A simple panel beats an inline-edit state machine here.
        let alert = NSAlert()
        alert.messageText = "Rename profile"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.stringValue = entry.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.profiles.rename(entry, to: field.stringValue)
    }

    private func confirmDelete(_ entry: ProfileEntry) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(entry.name)”?"
        alert.informativeText = "This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            model.profiles.delete(entry)
        }
    }
}
