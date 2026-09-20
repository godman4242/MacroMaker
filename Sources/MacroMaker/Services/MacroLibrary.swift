import AppKit

/// The macro library: `.macromaker` files in `~/Library/Application Support/Macro Maker/Macros/`
/// with a JSON index in UserDefaults. The "Last Recording" autosave still lives beside them
/// (not part of the library); saving a recording here is the stage-F way to keep one.
@MainActor @Observable
final class MacroLibrary {
    static let indexKey = "macroLibrary"

    private(set) var records: [MacroRecord]

    init(load: Bool = true) {
        records = load ? (UserDefaults.standard.data(forKey: Self.indexKey).map(Self.records(fromIndex:)) ?? []) : []
    }

    /// The stored index, decoded one entry at a time.
    ///
    /// `MacroRecord.init(from:)` deliberately throws on a file name `isSafeFileName` rejects —
    /// that is the path-traversal defence and it stays. But decoding the array in one go meant
    /// one such entry threw, `try?` turned the whole result into nil and `?? []` presented an
    /// empty library; the next add/rename/delete then persisted that empty list over the top,
    /// so the loss was permanent. Whatever produced the bad name — an older build, a future
    /// rule change, a hand-edited defaults plist — it must cost one row, not all of them.
    nonisolated static func records(fromIndex data: Data) -> [MacroRecord] {
        struct Tolerant: Decodable {
            let record: MacroRecord?
            init(from decoder: Decoder) throws { record = try? MacroRecord(from: decoder) }
        }
        return ((try? JSONDecoder().decode([Tolerant].self, from: data)) ?? []).compactMap(\.record)
    }

    var lastError: String?

    /// Test seam: when set, the library lives here instead of app support.
    static var folderOverride: URL?

    static var folder: URL? {
        if let folderOverride { return folderOverride }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Macro Maker/Macros", directoryHint: .isDirectory)
    }

    /// Returns whether the write landed. A failed index write was a silent `try?` —
    /// indistinguishable from success.
    @discardableResult
    private func persist() -> Bool {
        var records = records
        // Mark entries whose file vanished so the UI can show and clean them.
        if let folder = Self.folder {
            for index in records.indices {
                records[index].isOrphan = orphanIn(folder, fileName: records[index].fileName)
            }
        }
        self.records = records
        guard Persistence.save(records, key: Self.indexKey) else {
            lastError = "Couldn't save the library index — this change wasn't stored."
            return false
        }
        return true
    }

    /// A record is an orphan when its file is missing — or its name can't be trusted (it would
    /// never be reachable through the safe-name rule anyway).
    private func orphanIn(_ folder: URL, fileName: String) -> Bool {
        guard MacroLibraryRules.isSafeFileName(fileName) else { return true }
        return !FileManager.default.fileExists(atPath: folder.appending(path: fileName).path)
    }

    // MARK: Import / add

    /// Adds the current macro to the library under `name`; also writes its file.
    /// Returns the record (same id is fine: a second save with the same id updates).
    @discardableResult
    func add(_ macro: Macro, named proposedName: String) -> MacroRecord? {
        guard let folder = Self.folder else { return nil }
        let name = ProfileRules.cleanedName(proposedName)
        let fileName = MacroLibraryRules.uniqueFileName(
            for: proposedName,
            taken: diskFileNames() + records.map(\.fileName))
        let url = folder.appending(path: fileName)

        var record = MacroRecord(id: UUID(), name: name, createdAt: Date(),
                                 fileName: fileName)
        record.eventCount = macro.events.count
        record.durationSeconds = macro.duration

        var stored = macro
        stored.name = name
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try stored.jsonData().write(to: url, options: .atomic)
            records.insert(record, at: 0)
            guard persist() else { return nil }
            lastError = nil
            return record
        } catch {
            lastError = "Couldn't save to the library: \(error.localizedDescription)"
            return nil
        }
    }

    /// Removes a record and its file.
    func delete(_ record: MacroRecord) {
        guard MacroLibraryRules.isSafeFileName(record.fileName) else {
            lastError = "“\(record.fileName)” isn't a name this library can safely delete."
            return
        }
        if let folder = Self.folder {
            // The remove was a silent `try?` (review N5): an undeletable file left index and
            // disk disagreeing with nothing said. The record still leaves the index — the
            // user asked for it gone — but the failure is surfaced.
            do {
                try FileManager.default.removeItem(at: folder.appending(path: record.fileName))
            } catch {
                lastError = "Couldn't delete “\(record.fileName)” from disk: \(error.localizedDescription)"
            }
        }
        records.removeAll { $0.id == record.id }
        persist()
    }

    /// Renames a record; the file on disk follows the new name.
    func rename(_ record: MacroRecord, to proposed: String) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        let oldName = records[index].fileName
        if let folder = Self.folder {
            let newFileName = MacroLibraryRules.uniqueFileName(
                for: proposed, taken: diskFileNames().filter { $0 != oldName } + records.map(\.fileName).filter { $0 != oldName })
            let oldURL = folder.appending(path: oldName)
            let newURL = folder.appending(path: newFileName)
            do {
                // The file name carries the display name for the Finder too.
                try FileManager.default.moveItem(at: oldURL, to: newURL)
            } catch {
                // Rewriting the index after a failed move pointed it at a file that never
                // existed while the real one sat on disk unindexed. The record keeps both its
                // names, and the user sees why — exactly on the orphan path, where renaming
                // is how users try to fix things.
                lastError = "Couldn't rename “\(records[index].name)”: \(error.localizedDescription)"
                return
            }
            records[index].fileName = newURL.lastPathComponent
        }
        records[index].name = ProfileRules.cleanedName(proposed)
        persist()
    }

    /// Duplicates a record's file under a Finder-style "copy" name.
    @discardableResult
    func duplicate(_ record: MacroRecord) -> MacroRecord? {
        guard let folder = Self.folder else { return nil }
        let sourceURL = folder.appending(path: record.fileName)
        let newFileName = MacroLibraryRules.uniqueFileName(
            for: record.name + " copy", taken: diskFileNames() + records.map(\.fileName))
        let targetURL = folder.appending(path: newFileName)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: targetURL)
        } catch {
            lastError = "Couldn't duplicate: \(error.localizedDescription)"
            return nil
        }
        var copy = record
        copy.id = UUID()
        copy.name = ProfileRules.uniqueName(forDuplicateOf: record.name, taken: records.map(\.name))
        copy.fileName = targetURL.lastPathComponent
        copy.createdAt = Date()
        copy.isFavorite = false
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records.insert(copy, at: index + 1)
        } else {
            records.append(copy)
        }
        persist()
        return copy
    }

    /// Stars or unstars.
    func setFavorite(_ record: MacroRecord, _ favorite: Bool) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index].isFavorite = favorite
        persist()
    }

    /// Loads the record's macro payload. Returns nil for orphans, corrupt files, and index
    /// entries whose file name could escape the library folder.
    func load(_ record: MacroRecord) -> Macro? {
        guard let folder = Self.folder else { return nil }
        guard MacroLibraryRules.isSafeFileName(record.fileName) else {
            lastError = "“\(record.name)” has an unsafe file name in the library index and wasn't loaded."
            return nil
        }
        let url = folder.appending(path: record.fileName)
        let loaded = try? MacroFiles.read(from: url)
        if loaded == nil, !record.isOrphan {
            lastError = "Couldn't read “\(record.name).\(Macro.fileExtension)”."
        }
        return loaded
    }

    /// Finder-friendly order: favorites first, then by name.
    var sortedRecords: [MacroRecord] {
        records.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func diskFileNames() -> [String] {
        guard let folder = Self.folder,
              let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return [] }
        return files
    }
}
