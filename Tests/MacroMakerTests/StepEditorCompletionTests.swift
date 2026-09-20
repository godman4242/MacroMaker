import Foundation
import Testing

@testable import MacroMaker

/// Wave 7, feature 3 — macro editing completed (features.json F-16).
/// The step editor already renames, re-times, deletes, inserts waits and typed text; what's
/// missing is reordering, editing a click's coordinates, and inserting a wait with a chosen
/// duration (the menu offered only fixed 0.5 s / 1 s). Edits made to a macro loaded from the
/// library must persist back to that library record, not just the autosave.
@Suite("Step editor completion", .serialized, .seamSerialized)
struct StepEditorCompletionTests {

    // MARK: Reorder

    /// The pure rule: a step swaps with its neighbour — bounds are refused (no change),
    /// and the swapped pair keeps its own times (reordering is a sequence change, not a
    /// timeline re-write).
    @Test func moveStepSwapsThePairAndRefusesTheBounds() {
        let a = MacroEvent(time: 0, action: .keyDown(0, isRepeat: false), flags: 0)
        let b = MacroEvent(time: 1, action: .keyDown(1, isRepeat: false), flags: 0)
        let c = MacroEvent(time: 2, action: .keyDown(2, isRepeat: false), flags: 0)
        let events = [a, b, c]

        var moved = MacroLibraryRules.moved(events, at: 1, offset: -1)
        #expect(moved.map(\.time) == [1, 0, 2], "b swaps before a, each keeping its own time")
        moved = MacroLibraryRules.moved(events, at: 1, offset: 1)
        #expect(moved.map(\.time) == [0, 2, 1], "b swaps after c, each keeping its own time")

        #expect(MacroLibraryRules.moved(events, at: 0, offset: -1).map(\.time) == [0, 1, 2],
                "moving step 0 up is refused")
        #expect(MacroLibraryRules.moved(events, at: 2, offset: 1).map(\.time) == [0, 1, 2],
                "moving the last step down is refused")
        #expect(MacroLibraryRules.moved(events, at: 3, offset: -1).map(\.time) == [0, 1, 2],
                "an out-of-range index is refused")
    }

    /// Swapping a keyDown/keyUp pair out of order (up before its down) is refused — playback
    /// would drop the orphaned up; a swap that separates a mouse down from its up is refused
    /// for the same reason. Same-shape guard as the bounds, one rule.
    @Test func aSwapThatWouldStrandAHalfIsRefused() {
        let down = MacroEvent(time: 0, action: .keyDown(5, isRepeat: false), flags: 0)
        let up = MacroEvent(time: 0.02, action: .keyUp(5), flags: 0)
        let click = MacroEvent(time: 0.04, action: .mouseDown(.left, CGPoint(x: 1, y: 1), clickCount: 1), flags: 0)
        let clickUp = MacroEvent(time: 0.06, action: .mouseUp(.left, CGPoint(x: 1, y: 1), clickCount: 1), flags: 0)
        let other = MacroEvent(time: 1, action: .keyDown(9, isRepeat: false), flags: 0)
        // Swapping the up with the unrelated step after it is fine…
        #expect(MacroLibraryRules.moved([down, up, other], at: 1, offset: 1).map(\.time) == [0, 1, 0.02],
                "the up swaps past an unrelated step")
        // …but a swap that separates a down from its own up, either direction, is refused.
        #expect(MacroLibraryRules.moved([down, up, other], at: 0, offset: 1).map(\.time) == [0, 0.02, 1],
                "the keyDown can't move past its own keyUp")
        #expect(MacroLibraryRules.moved([down, up, other], at: 1, offset: -1).map(\.time) == [0, 0.02, 1],
                "and neither can the keyUp move before its keyDown")
        #expect(MacroLibraryRules.moved([down, click, clickUp, other], at: 1, offset: 1).map(\.time) == [0, 0.04, 0.06, 1],
                "the mouseDown can't move past its own mouseUp")
        #expect(MacroLibraryRules.moved([down, click, clickUp, other], at: 2, offset: -1).map(\.time) == [0, 0.04, 0.06, 1],
                "and neither can the mouseUp move before its own mouseDown")
    }

    // MARK: Coordinate edit

    /// The pure rule: a coordinate edit rewrites the point of a mouse step, leaving its time
    /// and clickCount alone; non-mouse steps are returned untouched.
    @Test func aCoordinateEditRewritesOnlyThePoint() {
        let click = MacroEvent(time: 1, action: .mouseDown(.right, CGPoint(x: 10, y: 20), clickCount: 2), flags: 0)
        let edited = MacroLibraryRules.withPoint(click, x: 100, y: 200)
        #expect(edited.action == .mouseDown(.right, CGPoint(x: 100, y: 200), clickCount: 2))
        #expect(edited.time == 1)

        let up = MacroEvent(time: 0, action: .mouseUp(.left, CGPoint(x: 1, y: 1), clickCount: 1), flags: 0)
        #expect(MacroLibraryRules.withPoint(up, x: 9, y: 9).action == .mouseUp(.left, CGPoint(x: 9, y: 9), clickCount: 1))

        let key = MacroEvent(time: 0, action: .keyDown(0, isRepeat: false), flags: 0)
        #expect(MacroLibraryRules.withPoint(key, x: 9, y: 9) == key,
                "a non-mouse step is returned untouched")

        let move = MacroEvent(time: 0, action: .move(CGPoint(x: 1, y: 1)), flags: 0)
        #expect(MacroLibraryRules.withPoint(move, x: 9, y: 9).action == .move(CGPoint(x: 9, y: 9)))

        let scroll = MacroEvent(time: 0, action: .scroll(CGPoint(x: 1, y: 1), dx: 0, dy: -10), flags: 0)
        #expect(MacroLibraryRules.withPoint(scroll, x: 9, y: 9) == scroll,
                "a scroll keeps its recorded point — its deltas were measured there")
    }

    // MARK: Library persistence

    @MainActor private func makeLibrary(macro: Macro, name: String) throws -> (MacroLibrary, MacroRecord, URL) {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "mm-edit-\(UUID().uuidString)", directoryHint: .isDirectory)
        MacroLibrary.folderOverride = folder
        let library = MacroLibrary(load: false)
        let record = try #require(library.add(macro, named: name))
        return (library, record, folder)
    }

    /// An edited macro loaded from the library persists back to ITS record — the file on disk
    /// and the index row both carry the edit, and nothing else in the library changes.
    @Test @MainActor func anEditedLibraryMacroPersistsBackToItsRecord() throws {
        let macro = Macro(name: "Edit me", createdAt: Date(timeIntervalSince1970: 1_000), events: [
            MacroEvent(time: 0, action: .keyDown(0, isRepeat: false), flags: 0),
            MacroEvent(time: 0.1, action: .keyUp(0), flags: 0),
        ])
        let (library, record, folder) = try makeLibrary(macro: macro, name: "Edit me")
        defer {
            MacroLibrary.folderOverride = nil
            UserDefaults.standard.removeObject(forKey: MacroLibrary.indexKey)
            try? FileManager.default.removeItem(at: folder)
        }

        var edited = macro
        edited.events.remove(at: 1)   // delete the keyUp — the edit under test
        let updated = try #require(library.update(record, with: edited))

        #expect(updated.id == record.id, "the edit updates the same record, not a new row")
        #expect(library.records.count == 1, "no duplicate row appears")
        #expect(library.records[0].eventCount == 1, "the index row carries the new count")
        let onDisk = try #require(library.load(record))
        #expect(onDisk.events.count == 1, "the file on disk carries the edit")
    }

    /// A failed update (record vanished from the index) returns nil and warns — never silent.
    @Test @MainActor func anUpdateForAnUnknownRecordWarns() throws {
        let macro = Macro(name: "Ghost", createdAt: Date(timeIntervalSince1970: 1_000), events: [
            MacroEvent(time: 0, action: .keyDown(0, isRepeat: false), flags: 0)])
        let (library, record, folder) = try makeLibrary(macro: macro, name: "Ghost")
        defer {
            MacroLibrary.folderOverride = nil
            UserDefaults.standard.removeObject(forKey: MacroLibrary.indexKey)
            try? FileManager.default.removeItem(at: folder)
        }
        // Simulate the record having left the index: delete the row through the library's own
        // delete (which also removes the file — the realistic way a record goes missing).
        library.delete(record)
        #expect(library.records.isEmpty)

        #expect(library.update(record, with: macro) == nil, "the unknown record can't be updated")
        #expect(library.lastError != nil, "the failed update must say so")
    }
}