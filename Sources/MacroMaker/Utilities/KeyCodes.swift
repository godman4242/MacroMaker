import Carbon.HIToolbox
import CoreGraphics

/// Static knowledge about macOS virtual key codes that doesn't depend on the keyboard layout.
enum KeyCodes {
    struct NamedKey: Sendable {
        /// Lowercase names accepted by the Key Presser; the first one is canonical.
        let names: [String]
        let code: CGKeyCode
        let label: String

        init(_ names: [String], _ code: Int, _ label: String) {
            self.names = names
            self.code = CGKeyCode(code)
            self.label = label
        }
    }

    static let namedKeys: [NamedKey] = [
        NamedKey(["space", "spacebar"], kVK_Space, "Space"),
        NamedKey(["enter", "return"], kVK_Return, "Return"),
        NamedKey(["tab"], kVK_Tab, "Tab"),
        NamedKey(["esc", "escape"], kVK_Escape, "Esc"),
        NamedKey(["delete", "backspace"], kVK_Delete, "Delete"),
        NamedKey(["forwarddelete", "del"], kVK_ForwardDelete, "Forward Delete"),
        NamedKey(["up", "uparrow", "arrowup"], kVK_UpArrow, "↑"),
        NamedKey(["down", "downarrow", "arrowdown"], kVK_DownArrow, "↓"),
        NamedKey(["left", "leftarrow", "arrowleft"], kVK_LeftArrow, "←"),
        NamedKey(["right", "rightarrow", "arrowright"], kVK_RightArrow, "→"),
        NamedKey(["home"], kVK_Home, "Home"),
        NamedKey(["end"], kVK_End, "End"),
        NamedKey(["pageup", "pgup"], kVK_PageUp, "Page Up"),
        NamedKey(["pagedown", "pgdn"], kVK_PageDown, "Page Down"),
        NamedKey(["shift"], kVK_Shift, "Shift"),
        NamedKey(["ctrl", "control"], kVK_Control, "Control"),
        NamedKey(["opt", "option", "alt"], kVK_Option, "Option"),
        NamedKey(["cmd", "command"], kVK_Command, "Command"),
        NamedKey(["fn", "function"], kVK_Function, "fn"),
        NamedKey(["rightshift"], kVK_RightShift, "Right Shift"),
        NamedKey(["rightctrl", "rightcontrol"], kVK_RightControl, "Right Control"),
        NamedKey(["rightopt", "rightoption"], kVK_RightOption, "Right Option"),
        NamedKey(["rightcmd", "rightcommand"], kVK_RightCommand, "Right Command"),
        NamedKey(["f1"], kVK_F1, "F1"), NamedKey(["f2"], kVK_F2, "F2"),
        NamedKey(["f3"], kVK_F3, "F3"), NamedKey(["f4"], kVK_F4, "F4"),
        NamedKey(["f5"], kVK_F5, "F5"), NamedKey(["f6"], kVK_F6, "F6"),
        NamedKey(["f7"], kVK_F7, "F7"), NamedKey(["f8"], kVK_F8, "F8"),
        NamedKey(["f9"], kVK_F9, "F9"), NamedKey(["f10"], kVK_F10, "F10"),
        NamedKey(["f11"], kVK_F11, "F11"), NamedKey(["f12"], kVK_F12, "F12"),
        NamedKey(["f13"], kVK_F13, "F13"), NamedKey(["f14"], kVK_F14, "F14"),
        NamedKey(["f15"], kVK_F15, "F15"), NamedKey(["f16"], kVK_F16, "F16"),
        NamedKey(["f17"], kVK_F17, "F17"), NamedKey(["f18"], kVK_F18, "F18"),
        NamedKey(["f19"], kVK_F19, "F19"), NamedKey(["f20"], kVK_F20, "F20"),
    ]

    static let codesByName: [String: CGKeyCode] = Dictionary(
        namedKeys.flatMap { key in key.names.map { ($0, key.code) } },
        uniquingKeysWith: { first, _ in first }
    )

    private static let keysByCode: [CGKeyCode: NamedKey] = Dictionary(
        namedKeys.map { ($0.code, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    static func label(for code: CGKeyCode) -> String? { keysByCode[code]?.label }

    static func canonicalName(for code: CGKeyCode) -> String? { keysByCode[code]?.names.first }

    static func isFunctionKey(_ code: CGKeyCode) -> Bool {
        keysByCode[code]?.names.first.map { $0.hasPrefix("f") && $0.count > 1 && $0.dropFirst().allSatisfy(\.isNumber) } ?? false
    }

    /// Flags a real keyboard sets on its own for certain keys. Some apps check them, so posted
    /// events include them too (arrows report as numeric-pad + fn keys, F-keys and navigation as fn).
    static func intrinsicFlags(for code: CGKeyCode) -> CGEventFlags {
        switch Int(code) {
        case kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow:
            [.maskSecondaryFn, .maskNumericPad]
        case kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete, kVK_Help:
            .maskSecondaryFn
        default:
            isFunctionKey(code) ? .maskSecondaryFn : []
        }
    }

    struct ModifierKey: Sendable {
        /// The device-independent flag (e.g. "some Shift is down").
        let flag: CGEventFlags
        /// The device-dependent bit for this exact key (left vs right), 0 if there is none.
        let deviceMask: UInt64
    }

    /// Modifier keys that arrive as `flagsChanged` events. Caps Lock is deliberately absent:
    /// it toggles state rather than being held, so it isn't recorded or replayed.
    static func modifierKey(for code: CGKeyCode) -> ModifierKey? {
        switch Int(code) {
        case kVK_Control: ModifierKey(flag: .maskControl, deviceMask: 0x0000_0001)
        case kVK_Shift: ModifierKey(flag: .maskShift, deviceMask: 0x0000_0002)
        case kVK_RightShift: ModifierKey(flag: .maskShift, deviceMask: 0x0000_0004)
        case kVK_Command: ModifierKey(flag: .maskCommand, deviceMask: 0x0000_0008)
        case kVK_RightCommand: ModifierKey(flag: .maskCommand, deviceMask: 0x0000_0010)
        case kVK_Option: ModifierKey(flag: .maskAlternate, deviceMask: 0x0000_0020)
        case kVK_RightOption: ModifierKey(flag: .maskAlternate, deviceMask: 0x0000_0040)
        case kVK_RightControl: ModifierKey(flag: .maskControl, deviceMask: 0x0000_2000)
        case kVK_Function: ModifierKey(flag: .maskSecondaryFn, deviceMask: 0)
        default: nil
        }
    }

    /// Whether a `flagsChanged` event for `code` means the key went down (vs. up).
    static func isModifierDown(code: CGKeyCode, flags: UInt64) -> Bool {
        guard let key = modifierKey(for: code) else { return false }
        let allDeviceBits: UInt64 = 0x0000_207F
        if key.deviceMask != 0, flags & allDeviceBits != 0 {
            return flags & key.deviceMask != 0
        }
        return flags & key.flag.rawValue != 0
    }
}
