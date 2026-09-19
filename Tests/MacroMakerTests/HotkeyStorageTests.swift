import Foundation
import Testing
@testable import MacroMaker

/// The hotkey wipe (review models F11): the stored `[HotkeyAction: KeyCombo?]` dictionary
/// decoded strictly, so ONE unknown action name (a deleted builtin case, a malformed
/// `macro:` uuid, a hand-edited plist) made the whole decode throw — `try?` turned it
/// into nil and every custom shortcut silently reset to its default on next launch.
@Suite("Hotkey storage")
struct HotkeyStorageTests {

    @Test func oneUnreadableEntryDoesNotResetEveryCustomHotkey() {
        let json = """
        {"toggleAutoClicker":{"keyCode":8,"modifiers":3},
         "toggleKeyPresser":{"keyCode":1e40,"modifiers":3},
         "stopAll":null,
         "notAnAction":{"keyCode":8,"modifiers":3}}
        """
        let combos = HotkeyAction.storedCombos(from: Data(json.utf8))
        // The readable builtin survived with its combo…
        #expect(combos[.toggleAutoClicker].flatMap { $0 }?.keyCode == 8)
        // …a cleared hotkey stays cleared (stored null, not dropped)…
        #expect(combos[.stopAll] != nil)
        // …and the two bad entries cost only themselves.
        #expect(combos[.toggleKeyPresser] == nil)
        #expect(combos.count == 2)
    }

    @Test func anUnreadableBlobYieldsNoCombos() {
        #expect(HotkeyAction.storedCombos(from: Data("not json".utf8)) == [:] as [HotkeyAction: KeyCombo?])
        #expect(HotkeyAction.storedCombos(from: Data("[]".utf8)) == [:])
    }

    @Test func aWellFormedBlobDecodesWhole() throws {
        let stored: [HotkeyAction: KeyCombo?] = [
            .toggleAutoClicker: KeyCombo(keyCode: 8, modifiers: [.control, .option]),
            .stopAll: nil,
        ]
        let decoded = HotkeyAction.storedCombos(from: try JSONEncoder().encode(stored))
        #expect(decoded[.toggleAutoClicker].flatMap { $0 } == KeyCombo(keyCode: 8, modifiers: [.control, .option]))
        #expect(decoded[.stopAll] != nil)
        #expect(decoded.count == 2)
    }
}