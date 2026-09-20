import AppKit
import os
import UniformTypeIdentifiers

/// The saved-profiles list: stored as a JSON array in UserDefaults, exported/imported as
/// `.macromakerprofile` files sharing the MacroFiles panels' idioms.
@MainActor @Observable
final class ProfileService {
    static let storageKey = "profiles"
    static let contentType = UTType(exportedAs: "com.kheshav.macromakerprofile", conformingTo: .json)

    private(set) var entries: [ProfileEntry]

    init(load: Bool = true) {
        entries = load ? (UserDefaults.standard.data(forKey: Self.storageKey).map(Self.entries(fromStored:)) ?? []) : []
    }

    /// The stored profiles list, decoded one entry at a time: whatever made one entry
    /// unreadable — a type mismatch, an unknown enum value, a hand-edited defaults plist —
    /// it must cost that entry, not the whole list. Decoding the array in one go meant one
    /// bad entry threw, `try?` turned the whole result into nil and `?? []` presented an
    /// empty list; the next save/delete/rename then persisted `[]` over the blob, so the
    /// loss was permanent and silent.
    nonisolated static func entries(fromStored data: Data) -> [ProfileEntry] {
        struct Tolerant: Decodable {
            let entry: ProfileEntry?
            init(from decoder: Decoder) throws { entry = try? ProfileEntry(from: decoder) }
        }
        let log = Logger(subsystem: "MacroMaker", category: "ProfileService")
        let decoded = (try? JSONDecoder().decode([Tolerant].self, from: data)) ?? []
        for (index, wrapper) in decoded.enumerated() where wrapper.entry == nil {
            log.fault("Saved-profile entry at position \(index) was unreadable and skipped.")
        }
        return decoded.compactMap(\.entry)
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
            // An EXACT name match is the same profile being re-saved. Matching
            // case-insensitively here made saving "My Profile" silently REPLACE the different
            // profile "my profile" (unrecoverable) — a case variant now saves as its own,
            // distinctly-named profile instead.
            ?? entries.firstIndex { $0.name == entry.name }
        if let existing {
            // `ProfileEntry.init(profile:)` defaults isFavorite to false (Profile has no such
            // field), so replacing wholesale would un-star a favourite on every re-save.
            entry.isFavorite = entries[existing].isFavorite
            entry.id = entries[existing].id
            entries[existing] = entry
        } else {
            var clashWarning: String?
            if let clash = entries.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(entry.name) == .orderedSame }) {
                let clashingName = entries[clash].name
                entry.name = ProfileRules.uniqueDisplayName(for: entry.name, taken: entries.map(\.name))
                clashWarning = "A profile named “\(clashingName)” already exists — saved this one as “\(entry.name)”."
            }
            entries.insert(entry, at: 0)
            // Set AFTER persist(): a landed save clears lastError (N5), so the clash notice
            // would be wiped by its own success if it went in before the write.
            if persist() { lastError = clashWarning }
            return
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

    /// Returns whether the write landed. A failed save was a silent `try?` —
    /// indistinguishable from success exactly when the user's profiles are at stake.
    /// A LANDED save also clears `lastError` (review N5): a stale "Couldn't save" used to
    /// outlive the recovery that fixed it. Callers with their own post-success message
    /// (importFile's clash warning) set it AFTER this returns, so the clear never swallows it.
    @discardableResult
    private func persist() -> Bool {
        guard Persistence.save(entries, key: Self.storageKey) else {
            lastError = "Couldn't save your profiles — this change wasn't stored."
            return false
        }
        lastError = nil
        return true
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
            // always mint a new id on import — and keep display names distinct too, so two
            // "Login" entries can't make a later same-name save ambiguous.
            var clashWarning: String?
            let unique = ProfileRules.uniqueDisplayName(for: profile.name, taken: entries.map(\.name))
            if unique != profile.name {
                clashWarning = "A profile named “\(profile.name)” already exists — imported this one as “\(unique)”."
                profile.name = unique
            }
            profile.id = UUID()
            let entry = ProfileEntry(profile: profile)
            entries.insert(entry, at: 0)
            // A failed write keeps its error; a landed one reports the rename, if there was one.
            if persist() { lastError = clashWarning }
            return entry
        } catch {
            lastError = "Couldn't import “\(url.lastPathComponent)”: it isn't a valid Macro Maker profile."
            return nil
        }
    }
}
