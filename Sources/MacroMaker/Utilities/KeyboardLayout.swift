import AppKit
import Carbon.HIToolbox

struct KeyPress: Equatable, Sendable {
    let keyCode: CGKeyCode
    let modifiers: KeyModifiers
}

/// Answers "which key (and modifiers) types this character?". Abstracted so the parser can be
/// unit-tested with a fixed layout.
protocol CharacterKeyMap: Sendable {
    func keyPress(for character: Character) -> KeyPress?
    func character(for keyCode: CGKeyCode) -> String?
}

/// A snapshot of the user's current keyboard layout (US, AZERTY, Dvorak…), built with
/// `UCKeyTranslate`. This is what makes "!" or "@" press the right physical key on any layout.
struct KeyboardLayout: CharacterKeyMap {
    private let pressesByCharacter: [Character: KeyPress]
    private let charactersByCode: [CGKeyCode: String]

    func keyPress(for character: Character) -> KeyPress? { pressesByCharacter[character] }

    func character(for keyCode: CGKeyCode) -> String? { charactersByCode[keyCode] }

    /// Cached, and rebuilt automatically when the user switches input source.
    @MainActor static var current: KeyboardLayout {
        if let cached { return cached }
        let layout = build()
        cached = layout
        if observer == nil {
            observer = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { cached = nil }
            }
        }
        return layout
    }

    @MainActor private static var cached: KeyboardLayout?
    @MainActor private static var observer: NSObjectProtocol?

    /// Text Input Source APIs must be called on the main thread.
    @MainActor private static func build() -> KeyboardLayout {
        // Both TISCopy… calls happen when the array literal is built and each returns a +1
        // Unmanaged reference. Balancing them inside a LAZY chain leaked the second one every
        // time the first source already had layout data — which is the normal case — because
        // the chain short-circuits and that closure never runs. Take both retains up front.
        let sources = [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()]
            .compactMap { $0?.takeRetainedValue() }
        let layoutData = sources.lazy.compactMap { source -> CFData? in
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { return nil }
            return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        }.first

        guard let layoutData, let bytes = CFDataGetBytePtr(layoutData) else {
            return KeyboardLayout(pressesByCharacter: [:], charactersByCode: [:])
        }

        // Modifier states in order of preference: plain key first, then ⇧, ⌥, ⇧⌥.
        let states: [(KeyModifiers, UInt32)] = [
            ([], 0),
            (.shift, UInt32(shiftKey >> 8) & 0xFF),
            (.option, UInt32(optionKey >> 8) & 0xFF),
            ([.shift, .option], UInt32((shiftKey | optionKey) >> 8) & 0xFF),
        ]
        let keyboardType = UInt32(LMGetKbdType())
        var presses: [Character: KeyPress] = [:]
        var characters: [CGKeyCode: String] = [:]

        bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            (presses, characters) = scan(states: states) { code, state in
                var deadKeyState: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), state, keyboardType,
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                                            chars.count, &length, &chars)
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: chars, count: length)
            }
        }
        return KeyboardLayout(pressesByCharacter: presses, charactersByCode: characters)
    }

    /// Builds both lookup tables from a translator.
    ///
    /// Key code is the OUTER loop and modifier state the inner one, so "lowest key code wins" is
    /// the primary rule and plain/⇧/⌥ preference only breaks ties within one key. With the loops
    /// the other way round the whole plain pass finished first, and any character that is
    /// unmodified on the numeric keypad but shifted on the main row was claimed by the keypad.
    /// Measured over the live ABC layout: '+' resolved to key 69 (KeypadPlus) instead of ⇧24,
    /// and '*' to key 67 (KeypadMultiply) instead of ⇧28 — exactly 2 of 200 characters, with
    /// the character set unchanged. `KeyStrokeParserTests` always asserted the fixed values; it
    /// passed only because its fake layout has no keypad keys to lose to.
    ///
    /// Extracted from `build()` so that ordering can be tested with a fake layout that DOES have
    /// keypad keys — which is the only way this defect is visible to a test.
    static func scan(codes: Range<CGKeyCode> = CGKeyCode(0)..<127,
                     states: [(KeyModifiers, UInt32)],
                     translate: (CGKeyCode, UInt32) -> String?)
        -> (presses: [Character: KeyPress], characters: [CGKeyCode: String]) {
        var presses: [Character: KeyPress] = [:]
        var characters: [CGKeyCode: String] = [:]
        for code in codes {
            for (modifiers, state) in states {
                guard let string = translate(code, state), string.count == 1,
                      let character = string.first, isPrintable(character) else { continue }
                if modifiers.isEmpty, characters[code] == nil { characters[code] = string }
                if presses[character] == nil { presses[character] = KeyPress(keyCode: code, modifiers: modifiers) }
            }
        }
        return (presses, characters)
    }

    /// Excludes control characters and the private-use range macOS uses for arrows/F-keys.
    private static func isPrintable(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }

    /// Display name for any key code: "Space", "F5", or the character the key types ("A").
    @MainActor static func displayName(for keyCode: CGKeyCode) -> String {
        KeyCodes.label(for: keyCode) ?? current.character(for: keyCode)?.uppercased() ?? "Key \(keyCode)"
    }
}
