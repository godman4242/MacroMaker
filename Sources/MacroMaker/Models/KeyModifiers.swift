import AppKit
import Carbon.HIToolbox

/// The four user-facing modifier keys, convertible to every representation macOS uses
/// (CGEvent flags for posting, Carbon flags for hotkeys, NSEvent flags from key capture).
struct KeyModifiers: OptionSet, Hashable, Codable, Sendable {
    let rawValue: Int

    static let control = KeyModifiers(rawValue: 1 << 0)
    static let option = KeyModifiers(rawValue: 1 << 1)
    static let shift = KeyModifiers(rawValue: 1 << 2)
    static let command = KeyModifiers(rawValue: 1 << 3)

    /// Apple's canonical display order: ⌃⌥⇧⌘.
    private static let ordered: [(KeyModifiers, symbol: String, keyCode: CGKeyCode, flag: CGEventFlags, carbon: Int)] = [
        (.control, "⌃", CGKeyCode(kVK_Control), .maskControl, controlKey),
        (.option, "⌥", CGKeyCode(kVK_Option), .maskAlternate, optionKey),
        (.shift, "⇧", CGKeyCode(kVK_Shift), .maskShift, shiftKey),
        (.command, "⌘", CGKeyCode(kVK_Command), .maskCommand, cmdKey),
    ]

    var symbols: String {
        Self.ordered.filter { contains($0.0) }.map(\.symbol).joined()
    }

    var cgFlags: CGEventFlags {
        Self.ordered.reduce(into: CGEventFlags()) { flags, entry in
            if contains(entry.0) { flags.insert(entry.flag) }
        }
    }

    var carbonFlags: UInt32 {
        Self.ordered.reduce(0) { result, entry in
            contains(entry.0) ? result | UInt32(entry.carbon) : result
        }
    }

    /// Key codes of the left-hand modifier keys, in the order they should be pressed.
    var keyCodes: [CGKeyCode] {
        Self.ordered.filter { contains($0.0) }.map(\.keyCode)
    }

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(_ flags: NSEvent.ModifierFlags) {
        var result: KeyModifiers = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        self = result
    }

    /// The modifier represented by one device-independent CGEventFlag (nil for any other flag).
    init?(cgFlag: CGEventFlags) {
        let mask = cgFlag.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand])
        var result: KeyModifiers = []
        if mask.contains(.maskControl) { result.insert(.control) }
        if mask.contains(.maskAlternate) { result.insert(.option) }
        if mask.contains(.maskShift) { result.insert(.shift) }
        if mask.contains(.maskCommand) { result.insert(.command) }
        guard result.rawValue != 0, mask.rawValue == cgFlag.rawValue else { return nil }
        self = result
    }
}
