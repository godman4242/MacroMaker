import AppKit
import UniformTypeIdentifiers

/// Saving, opening and autosaving `.macromaker` files.
@MainActor
enum MacroFiles {
    static let contentType = UTType(exportedAs: "com.kheshav.macromaker", conformingTo: .json)

    /// The last recording survives quitting the app.
    private static var autosaveURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appending(path: "Macro Maker/Last Recording.\(Macro.fileExtension)")
    }

    static func loadAutosave() -> Macro? {
        guard let url = autosaveURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? Macro(jsonData: data)
    }

    static func autosave(_ macro: Macro?) {
        guard let url = autosaveURL else { return }
        guard let macro else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? macro.jsonData().write(to: url, options: .atomic)
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
