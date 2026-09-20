import Foundation
import Testing
@testable import MacroMaker

/// The library persist-back flow through the SAME path the UI uses:
/// loadFromLibrary(record) → step edit (model.macro = edited) → autosaveMacro().
/// Calling library.update directly (as anEditedLibraryMacroPersistsBackToItsRecord does)
/// skips the AppModel wiring and can pass while the wiring is dead.
@Suite("LibraryPersistBackWiring")
struct LibraryPersistBackWiringTests {
    @MainActor @Test func anEditAfterLoadFromLibraryPersistsBackToTheRecord() async throws {
        let macro = Macro(name: "Wiring", createdAt: Date(timeIntervalSince1970: 1_000), events: [
            MacroEvent(time: 0, action: .keyDown(0, isRepeat: false), flags: 0),
            MacroEvent(time: 0.1, action: .keyUp(0), flags: 0),
        ])
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "mm-wiring-\(UUID().uuidString)", directoryHint: .isDirectory)
        MacroLibrary.folderOverride = folder
        MacroFiles.autosaveDestination = folder.appending(path: "autosave.macromaker")
        let savedIndex = UserDefaults.standard.data(forKey: MacroLibrary.indexKey)
        let model = AppModel.shared
        let savedLoadedRecord = model.loadedRecord
        let savedMacro = model.macro

        func cleanup() {
            MacroLibrary.folderOverride = nil
            MacroFiles.autosaveDestination = nil
            if let savedIndex { UserDefaults.standard.set(savedIndex, forKey: MacroLibrary.indexKey) }
            else { UserDefaults.standard.removeObject(forKey: MacroLibrary.indexKey) }
            model.loadedRecord = savedLoadedRecord
            model.macro = savedMacro
        }
        defer { cleanup() }

        // Use AppModel.shared's OWN library instance: autosaveMacro persists through
        // model.library, and a second MacroLibrary(load: false) instance here would hold a
        // separate records array that never sees the update (the exact dead-wiring shape
        // this test exists to catch, but on the wrong side).
        let library = model.library
        let record = try #require(library.add(macro, named: "Wiring"))

        // The UI path: Edit… → loadFromLibrary, then the recorder's step edit.
        model.loadFromLibrary(record)
        try #require(model.loadedRecord != nil, "loadFromLibrary must keep the record link for persist-back")
        var edited = try #require(model.macro)
        edited.events.remove(at: 1)
        model.macro = edited
        model.autosaveMacro()

        #expect(model.loadedRecord != nil, "the record link survives the save, so later edits also persist")
        #expect(library.records.count == 1)
        #expect(library.records[0].eventCount == 1, "the index row carries the edit")
        let onDisk = try #require(library.load(record))
        #expect(onDisk.events.count == 1, "the file on disk carries the edit")
    }
}