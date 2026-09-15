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
        let sources = [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()]
        let layoutData = sources.lazy.compactMap { source -> CFData? in
            guard let source = source?.takeRetainedValue(),
                  let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
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
            for (modifiers, state) in states {
                // Ascending key codes: the main typing keys come before the numeric keypad.
                for code in CGKeyCode(0)..<127 {
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), state, keyboardType,
                                                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                                                chars.count, &length, &chars)
                    guard status == noErr, length > 0 else { continue }
                    let string = String(utf16CodeUnits: chars, count: length)
                    guard string.count == 1, let character = string.first, isPrintable(character) else { continue }
                    if modifiers.isEmpty, characters[code] == nil { characters[code] = string }
                    if presses[character] == nil { presses[character] = KeyPress(keyCode: code, modifiers: modifiers) }
                }
            }
        }
        return KeyboardLayout(pressesByCharacter: presses, charactersByCode: characters)
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
