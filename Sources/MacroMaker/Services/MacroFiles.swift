import AppKit
import os
import UniformTypeIdentifiers

/// Saving, opening and autosaving `.macromaker` files.
@MainActor
enum MacroFiles {
    static let contentType = UTType(exportedAs: "com.kheshav.macromaker", conformingTo: .json)

    /// Test seam: where the autosave is written (tests point it at a temp path).
    static var autosaveDestination: URL?

    /// The last recording survives quitting the app.
    private static var autosaveURL: URL? {
        if let autosaveDestination { return autosaveDestination }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appending(path: "Macro Maker/Last Recording.\(Macro.fileExtension)")
    }

    static func loadAutosave() -> Macro? {
        guard let url = autosaveURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? Macro(jsonData: data)
    }

    /// Returns a user-visible warning when the autosave could NOT be written; nil on success.
    /// Both writes were a silent `try?`, so a full or slow disk discarded the last recording
    /// at the exact moment the app was about to quit — indistinguishable from success.
    @discardableResult
    static func autosave(_ macro: Macro?) -> String? {
        guard let url = autosaveURL else { return nil }
        guard let macro else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try macro.jsonData().write(to: url, options: .atomic)
            return nil
        } catch {
            let log = Logger(subsystem: "MacroMaker", category: "MacroFiles")
            log.fault("Couldn't write the autosave: \(error.localizedDescription, privacy: .public)")
            return "Couldn't save the last recording: \(error.localizedDescription)"
        }
    }

    static func read(from url: URL) throws -> Macro {
        // A real recording is tiny (10 min at 60 events/s is ~3 MB of JSON); a cap
        // keeps a huge or slow file (network volume, Finder double-click) from being
        // read wholesale on the main actor.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 16_000_000 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "This file is too large to be a Macro Maker recording."))
        }
        return try Macro(jsonData: Data(contentsOf: url))
    }

    /// Shows a save panel. Returns the saved file's URL, or nil if the user cancelled.
    static func saveWithPanel(_ macro: Macro) throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = "\(macro.name).\(Macro.fileExtension)"
        panel.canCreateDirectories = true
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // Rename BEFORE writing. The caller renames its in-memory copy from this URL, but the
        // bytes had already been written — so the file on disk kept the old name and the rename
        // the user just performed in the Save panel was lost the moment the file was reopened.
        var stored = macro
        stored.name = url.deletingPathExtension().lastPathComponent
        try stored.jsonData().write(to: url, options: .atomic)
        return url
    }

    /// Shows an open panel. Returns the chosen macro, or nil if the user cancelled.
    static func openWithPanel() throws -> Macro? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [contentType]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try read(from: url)
    }
}
