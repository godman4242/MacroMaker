import Carbon.HIToolbox
import Testing
@testable import MacroMaker

/// A fixed US-like layout so tests don't depend on the machine's keyboard settings.
private struct FakeLayout: CharacterKeyMap {
    private let presses: [Character: KeyPress] = [
        "a": KeyPress(keyCode: 0, modifiers: []),
        "A": KeyPress(keyCode: 0, modifiers: .shift),
        "z": KeyPress(keyCode: 6, modifiers: []),
        "1": KeyPress(keyCode: 18, modifiers: []),
        "!": KeyPress(keyCode: 18, modifiers: .shift),
        "=": KeyPress(keyCode: 24, modifiers: []),
        "+": KeyPress(keyCode: 24, modifiers: .shift),
        " ": KeyPress(keyCode: 49, modifiers: []),
    ]

    func keyPress(for character: Character) -> KeyPress? { presses[character] }
    func character(for keyCode: CGKeyCode) -> String? { presses.first { $0.value.keyCode == keyCode && $0.value.modifiers.isEmpty }.map { String($0.key) } }
}

@Suite struct KeyStrokeParserTests {
    private func parse(_ input: String) throws -> KeyStroke {
        try KeyStrokeParser.parse(input, layout: FakeLayout())
    }

    @Test func plainLetter() throws {
        let stroke = try parse("a")
        #expect(stroke.key == .code(0))
        #expect(stroke.modifiers.isEmpty)
        #expect(stroke.label == "a")
    }

    @Test func uppercaseLetterAddsShiftFromLayout() throws {
        let stroke = try parse("A")
        #expect(stroke.key == .code(0))
        #expect(stroke.modifiers == .shift)
    }

    @Test func specialCharacterUsesLayoutModifiers() throws {
        let stroke = try parse("!")
        #expect(stroke.key == .code(18))
        #expect(stroke.modifiers == .shift)
        #expect(stroke.label == "!")
    }

    @Test(arguments: [" ", "space", "SPACE", "  space  "])
    func spaceVariants(input: String) throws {
        let stroke = try parse(input)
        #expect(stroke.key == .code(CGKeyCode(kVK_Space)))
        #expect(stroke.label == "Space")
    }

    @Test(arguments: [
        ("enter", kVK_Return), ("return", kVK_Return), ("tab", kVK_Tab), ("esc", kVK_Escape),
        ("up", kVK_UpArrow), ("Left", kVK_LeftArrow), ("f5", kVK_F5), ("F12", kVK_F12), ("f20", kVK_F20),
        ("pagedown", kVK_PageDown),
    ])
    func namedKeys(input: String, expected: Int) throws {
        #expect(try parse(input).key == .code(CGKeyCode(expected)))
    }

    @Test func modifierCombo() throws {
        let stroke = try parse("cmd+shift+z")
        #expect(stroke.key == .code(6))
        #expect(stroke.modifiers == [.command, .shift])
        #expect(stroke.label == "⇧⌘Z")
    }

    @Test func comboLettersAreCaseInsensitive() throws {
        let stroke = try parse("ctrl+A")
        #expect(stroke.key == .code(0))
        #expect(stroke.modifiers == .control, "⌃A, not ⌃⇧A")
    }

    @Test func plusKeyAloneAndInCombo() throws {
        #expect(try parse("+") == KeyStroke(key: .code(24), modifiers: .shift, label: "+"))
        let combo = try parse("cmd++")
        #expect(combo.key == .code(24))
        #expect(combo.modifiers == [.command, .shift])
    }

    @Test func modifierKeyOnItsOwnCanBeHeld() throws {
        let stroke = try parse("shift")
        #expect(stroke.key == .code(CGKeyCode(kVK_Shift)))
        #expect(stroke.canHold)
    }

    @Test func characterMissingFromLayoutFallsBackToText() throws {
        let stroke = try parse("é")
        #expect(stroke.key == .text("é"))
        #expect(!stroke.canHold)
    }

    @Test func errors() {
        #expect(throws: KeyStrokeParser.ParseError.empty) { try parse("") }
        #expect(throws: KeyStrokeParser.ParseError.empty) { try parse("   ") }
        #expect(throws: KeyStrokeParser.ParseError.unknownKey("hello")) { try parse("hello") }
        #expect(throws: KeyStrokeParser.ParseError.unknownModifier("hyper")) { try parse("hyper+a") }
        #expect(throws: KeyStrokeParser.ParseError.unknownKey("cmd+")) { try parse("cmd+") }
        #expect(throws: KeyStrokeParser.ParseError.textWithModifiers("é")) { try parse("cmd+é") }
    }

    @Test func capturedKeyRoundTripsThroughToken() throws {
        let token = try #require(KeyStrokeParser.token(keyCode: 6, modifiers: [.command, .shift], layout: FakeLayout()))
        #expect(token == "shift+cmd+z")
        #expect(try parse(token) == parse("cmd+shift+z"))
        #expect(KeyStrokeParser.token(keyCode: CGKeyCode(kVK_F5), modifiers: [], layout: FakeLayout()) == "f5")
    }
}
