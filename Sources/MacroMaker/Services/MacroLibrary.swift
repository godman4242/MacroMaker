import AppKit

/// The macro library: `.macromaker` files in `~/Library/Application Support/Macro Maker/Macros/`
/// with a JSON index in UserDefaults. The "Last Recording" autosave still lives beside them
/// (not part of the library); saving a recording here is the stage-F way to keep one.
@MainActor @Observable
final class MacroLibrary {
    static let indexKey = "macroLibrary"

    private(set) var records: [MacroRecord]

    init(load: Bool = true) {
        records = load ? (Persistence.load([MacroRecord].self, key: Self.indexKey) ?? []) : []
    }

    var lastError: String?

    static var folder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Macro Maker/Macros", directoryHint: .isDirectory)
    }

    private func persist() {
        var records = records
        // Mark entries whose file vanished so the UI can show and clean them.
        if let folder = Self.folder {
            for index in records.indices {
                records[index].isOrphan = orphanIn(folder, fileName: records[index].fileName)
            }
        }
        self.records = records
        Persistence.save(records, key: Self.indexKey)
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
            persist()
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
            try? FileManager.default.removeItem(at: folder.appending(path: record.fileName))
        }
        records.removeAll { $0.id == record.id }
        persist()
    }

    /// Renames a record; the file on disk follows the new name.
    func rename(_ record: MacroRecord, to proposed: String) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        let oldName = records[index].fileName
        records[index].name = ProfileRules.cleanedName(proposed)
        if let folder = Self.folder {
            let newFileName = MacroLibraryRules.uniqueFileName(
                for: proposed, taken: diskFileNames().filter { $0 != oldName } + records.map(\.fileName).filter { $0 != oldName })
            let oldURL = folder.appending(path: oldName)
            let newURL = folder.appending(path: newFileName)
            // The file name carries the display name for the Finder too.
            try? FileManager.default.moveItem(at: oldURL, to: newURL)
            records[index].fileName = newURL.lastPathComponent
        }
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
