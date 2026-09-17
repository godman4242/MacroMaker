import AppKit
import UniformTypeIdentifiers

/// The saved-profiles list: stored as a JSON array in UserDefaults, exported/imported as
/// `.macromakerprofile` files sharing the MacroFiles panels' idioms.
@MainActor @Observable
final class ProfileService {
    static let storageKey = "profiles"
    static let contentType = UTType(exportedAs: "com.kheshav.macromakerprofile", conformingTo: .json)

    private(set) var entries: [ProfileEntry]

    init(load: Bool = true) {
        entries = load ? (Persistence.load([ProfileEntry].self, key: Self.storageKey) ?? []) : []
    }

    var lastError: String?

    // MARK: CRUD

    func save(_ profile: Profile) {
        var entry = ProfileEntry(profile: profile)
        // Match on name as well as id. The only caller builds its argument through
        // `Profile.init(name:)`, which mints a FRESH UUID every time — so the id never matched,
        // the update branch was unreachable from the UI, and re-saving a name just accumulated
        // duplicates.
        let existing = entries.firstIndex { $0.id == entry.id }
            ?? entries.firstIndex { $0.name.localizedCaseInsensitiveCompare(entry.name) == .orderedSame }
        if let existing {
            // `ProfileEntry.init(profile:)` defaults isFavorite to false (Profile has no such
            // field), so replacing wholesale would un-star a favourite on every re-save.
            entry.isFavorite = entries[existing].isFavorite
            entry.id = entries[existing].id
            entries[existing] = entry
        } else {
            entries.insert(entry, at: 0)
        }
        persist()
    }

    func delete(_ profile: ProfileEntry) {
        entries.removeAll { $0.id == profile.id }
        persist()
    }

    func rename(_ profile: ProfileEntry, to proposed: String) {
        guard let index = entries.firstIndex(where: { $0.id == profile.id }) else { return }
        entries[index].name = ProfileRules.cleanedName(proposed)
        persist()
    }

    func duplicate(_ profile: ProfileEntry) {
        let copy = ProfileEntry(profile: profile.asProfile())
        // Fresh identity: applying the copy must not collide with the original.
        var fresh = copy
        fresh.id = UUID()
        fresh.name = ProfileRules.uniqueName(forDuplicateOf: profile.name, taken: entries.map(\.name))
        fresh.isFavorite = false
        if let index = entries.firstIndex(where: { $0.id == profile.id }) {
            entries.insert(fresh, at: index + 1)
        } else {
            entries.append(fresh)
        }
        persist()
    }

    func setFavorite(_ profile: ProfileEntry, _ favorite: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == profile.id }) else { return }
        entries[index].isFavorite = favorite
        persist()
    }

    /// Favorites first, then alphabetical — the sidebar order.
    var sortedEntries: [ProfileEntry] {
        entries.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func persist() {
        Persistence.save(entries, key: Self.storageKey)
    }

    // MARK: Files

    /// Writes a profile out as a shareable file.
    func exportWithPanel(_ entry: ProfileEntry) {
        var profile = entry.asProfile()
        profile.formatVersion = Profile.currentFormatVersion
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.contentType]
        panel.nameFieldStringValue = "\(entry.name).\(Profile.fileExtension)"
        panel.canCreateDirectories = true
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try profile.jsonData().write(to: url, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Couldn't export: \(error.localizedDescription)"
        }
    }

    /// Imports a `.macromakerprofile` from an open panel. Returns the entry added, or nil.
    @discardableResult
    func importWithPanel() -> ProfileEntry? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.contentType]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return importFile(at: url)
    }

    @discardableResult
    func importFile(at url: URL) -> ProfileEntry? {
        do {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= 16_000_000 else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: [], debugDescription: "This file is too large to be a Macro Maker profile."))
            }
            var profile = try Profile.from(jsonData: Data(contentsOf: url))
            // A file someone else wrote must not collide with a profile already in the list:
            // always mint a new id on import, keep the name.
            profile.id = UUID()
            let entry = ProfileEntry(profile: profile)
            entries.insert(entry, at: 0)
            persist()
            lastError = nil
            return entry
        } catch {
            lastError = "Couldn't import “\(url.lastPathComponent)”: it isn't a valid Macro Maker profile."
            return nil
        }
    }
}
