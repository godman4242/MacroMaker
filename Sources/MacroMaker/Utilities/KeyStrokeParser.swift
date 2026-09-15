import Carbon.HIToolbox
import Foundation

/// Turns what the user types in the Key Presser ("a", "!", "space", "cmd+shift+z", "f5") into a
/// `KeyStroke` that can be posted.
enum KeyStrokeParser {
    enum ParseError: Error, Equatable, LocalizedError {
        case empty
        case unknownModifier(String)
        case unknownKey(String)
        case textWithModifiers(String)

        var errorDescription: String? {
            switch self {
            case .empty:
                "Enter a key — one character, or a name like space, enter, tab, esc, up, f5."
            case let .unknownModifier(token):
                "“\(token)” isn't a modifier. Use cmd, shift, opt or ctrl — e.g. cmd+shift+z."
            case let .unknownKey(token):
                "“\(token)” isn't a key. Type one character, or a name like space, enter, tab, esc, up, f5."
            case let .textWithModifiers(text):
                "“\(text)” isn't on your keyboard layout, so it can't be combined with modifiers."
            }
        }
    }

    private static let modifiersByName: [String: KeyModifiers] = [
        "cmd": .command, "command": .command, "⌘": .command,
        "shift": .shift, "⇧": .shift,
        "opt": .option, "option": .option, "alt": .option, "⌥": .option,
        "ctrl": .control, "control": .control, "⌃": .control,
    ]

    static func parse(_ input: String, layout: some CharacterKeyMap) throws(ParseError) -> KeyStroke {
        // A single character is always taken literally — including " " and "+".
        if input.count == 1, let character = input.first {
            return try stroke(for: character, modifiers: [], layout: layout)
        }
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw .empty }
        if trimmed.count == 1, let character = trimmed.first {
            return try stroke(for: character, modifiers: [], layout: layout)
        }

        var tokens = trimmed.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var keyToken = tokens.removeLast()
        if keyToken.isEmpty, tokens.last == "" {
            // "cmd++" splits into ["cmd", "", ""]: the key is "+" itself.
            tokens.removeLast()
            keyToken = "+"
        }
        guard !keyToken.isEmpty else { throw .unknownKey(trimmed) }

        var modifiers: KeyModifiers = []
        for token in tokens {
            guard let modifier = modifiersByName[token.lowercased()] else { throw .unknownModifier(token) }
            modifiers.insert(modifier)
        }

        if let code = KeyCodes.codesByName[keyToken.lowercased()] {
            return KeyStroke(key: .code(code), modifiers: modifiers,
                             label: modifiers.symbols + (KeyCodes.label(for: code) ?? keyToken))
        }
        guard keyToken.count == 1, let character = keyToken.first else { throw .unknownKey(keyToken) }
        // With modifiers, letters are case-insensitive: "cmd+C" means ⌘C, not ⌘⇧C.
        let base = modifiers.isEmpty ? character : Character(keyToken.lowercased())
        return try stroke(for: base, modifiers: modifiers, layout: layout)
    }

    private static func stroke(for character: Character, modifiers: KeyModifiers,
                               layout: some CharacterKeyMap) throws(ParseError) -> KeyStroke {
        if character == " " {
            return KeyStroke(key: .code(CGKeyCode(kVK_Space)), modifiers: modifiers, label: modifiers.symbols + "Space")
        }
        let label = modifiers.isEmpty ? String(character) : modifiers.symbols + String(character).uppercased()
        if let press = layout.keyPress(for: character) {
            return KeyStroke(key: .code(press.keyCode), modifiers: modifiers.union(press.modifiers), label: label)
        }
        guard modifiers.isEmpty else { throw .textWithModifiers(String(character)) }
        return KeyStroke(key: .text(String(character)), modifiers: [], label: label)
    }

    /// The text to put in the key field for a captured key press, e.g. "cmd+shift+z" or "f5".
    static func token(keyCode: CGKeyCode, modifiers: KeyModifiers, layout: some CharacterKeyMap) -> String? {
        guard let key = KeyCodes.canonicalName(for: keyCode) ?? layout.character(for: keyCode) else { return nil }
        let names: [(KeyModifiers, String)] = [(.control, "ctrl"), (.option, "opt"), (.shift, "shift"), (.command, "cmd")]
        let prefix = names.filter { modifiers.contains($0.0) }.map(\.1)
        return (prefix + [key]).joined(separator: "+")
    }
}
