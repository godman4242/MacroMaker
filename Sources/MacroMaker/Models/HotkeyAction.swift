import Carbon.HIToolbox

/// A global keyboard shortcut: a key plus at least one modifier (or a function key on its own).
struct KeyCombo: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: KeyModifiers

    /// Whether a `.flagsChanged` event ENDS a hold of this combo.
    ///
    /// `.flagsChanged` fires on both the press and the release of a modifier, and the event
    /// itself does not say which. The answer is in the post-change flags: a modifier that is
    /// still present was just pressed. Asking only "is this modifier part of the combo" made
    /// pressing ⌃ during a ⌃⌥C hold-run read as a release and stop the run.
    ///
    /// Matching on the flag rather than the key code is deliberate: releasing EITHER part of a
    /// ⌃⌥C-style combo ends the hold, because the combo's main key rarely goes up too.
    func isEndedByFlagsChange(keyCode changed: CGKeyCode, modifiersAfter: KeyModifiers) -> Bool {
        guard let modifierKey = KeyCodes.modifierKey(for: changed),
              let flag = KeyModifiers(cgFlag: modifierKey.flag)
        else { return false }
        return modifiers.contains(flag) && !modifiersAfter.contains(flag)
    }
}

/// The built-in hotkey actions. `slotID` (`Self.allCases.firstIndex`) is each action's Carbon
/// registration slot, keeping builtins and dynamic macro hotkeys in one stable numbering scheme.
enum BuiltinHotkeyAction: String, Codable, CaseIterable, Sendable {
    case toggleAutoClicker
    case toggleKeyPresser
    case toggleWebTarget
    case toggleRecording
    case togglePlayback
    case stopAll

    var title: String {
        switch self {
        case .toggleAutoClicker: "Start / stop Auto Clicker"
        case .toggleKeyPresser: "Start / stop Key Presser"
        case .toggleWebTarget: "Start / stop Web Target"
        case .toggleRecording: "Start / stop recording"
        case .togglePlayback: "Start / stop playback"
        case .stopAll: "Stop everything"
        }
    }

    /// Defaults use ⌃⌥ plus a mnemonic letter — a combination almost no app claims.
    var defaultCombo: KeyCombo {
        let key: Int = switch self {
        case .toggleAutoClicker: kVK_ANSI_C
        case .toggleKeyPresser: kVK_ANSI_K
        case .toggleWebTarget: kVK_ANSI_W
        case .toggleRecording: kVK_ANSI_R
        case .togglePlayback: kVK_ANSI_P
        case .stopAll: kVK_ANSI_S
        }
        return KeyCombo(keyCode: UInt32(key), modifiers: [.control, .option])
    }
}

/// A global hotkey registration: a builtin action, or playing one library macro.
/// The case *name* (`toggleAutoClicker` / `macro:<uuid>`) is the Codable identity.
enum HotkeyAction: Hashable, Sendable {
    case builtin(BuiltinHotkeyAction)
    case macro(UUID)

    /// Carbon EventHotKeyID signature for Macro Maker registrations.
    static let signature: OSType = 0x4D4D_4B52 // "MMKR"
    /// Slot ids 0...N-1 are the builtins, in declaration order; macro slots start at `kHotkeyIDMacroBase`.
    static let macroIDBase: UInt32 = 1_000
    /// The recorder tab caps per-macro hotkeys so ids stay compact.
    static let maxMacroHotkeys = 10

    var builtin: BuiltinHotkeyAction? {
        if case let .builtin(action) = self { return action }
        return nil
    }

    /// The library macro this action plays, if any.
    var macroID: UUID? {
        if case let .macro(id) = self { return id }
        return nil
    }

    /// Stable string identity (`toggleAutoClicker` or `macro:<uuid>`) for capture keys.
    var storageName: String { rawValue }

    /// Carbon registration slot. Builtin slots 0...5 are declaration order; macro slots are
    /// derived from the UUID bytes via FNV-1a (deterministic across launches — `hashValue` is
    /// per-launch randomized, so the old `id.hashValue` slot moved the same macro between
    /// launches). A collision-free slot is found by scanning against `taken`; without a scan
    /// context the raw hash is returned.
    func slotID(avoiding taken: Set<UInt32> = []) -> UInt32 {
        switch self {
        case let .builtin(action):
            return UInt32(BuiltinHotkeyAction.allCases.firstIndex(of: action)!)
        case let .macro(id):
            var slot = Self.macroIDBase + Self.fnv1a32(uuid: id) % Self.macroSlotRange
            while taken.contains(slot) {
                slot = slot + 1 >= Self.macroIDBase + Self.macroSlotRange ? Self.macroIDBase : slot + 1
            }
            return slot
        }
    }

    /// Back-compat for call sites that don't track taken slots (registration, tests).
    var slotID: UInt32 { slotID(avoiding: []) }

    /// Slot ids span `macroIDBase ..< macroIDBase + macroSlotRange`.
    static let macroSlotRange: UInt32 = 60_000

    private static func fnv1a32(uuid: UUID) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for byte in withUnsafeBytes(of: uuid.uuid, { Array($0) }) {
            hash = (hash ^ UInt32(byte)) &* 0x0100_0193
        }
        return hash
    }

    static func action(forSlotID id: UInt32, macros: inout [UUID: HotkeyAction]) -> HotkeyAction? {
        if Int(id) < BuiltinHotkeyAction.allCases.count {
            return .builtin(BuiltinHotkeyAction.allCases[Int(id)])
        }
        return macros.first(where: { $0.value.slotID == id })?.value
    }
}

extension HotkeyAction: Codable {
    init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        if let parsed = HotkeyAction(rawValue: name) {
            self = parsed
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown hotkey action “\(name)”."))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// RawRepresentable (not just Codable) so `[HotkeyAction: KeyCombo?]` dictionaries encode
/// keyed by the case name (`"toggleAutoClicker"`, `"macro:<uuid>"`) — byte-compatible with
/// the v1 storage format, where HotkeyAction was a String-raw-value enum.
extension HotkeyAction: RawRepresentable {
    var rawValue: String {
        switch self {
        case let .builtin(action): action.rawValue
        case let .macro(id): "macro:\(id.uuidString)"
        }
    }

    init?(rawValue: String) {
        if let builtin = BuiltinHotkeyAction(rawValue: rawValue) {
            self = .builtin(builtin)
        } else if rawValue.hasPrefix("macro:"), let id = UUID(uuidString: String(rawValue.dropFirst(6))) {
            self = .macro(id)
        } else {
            return nil
        }
    }
}

/// Backwards-compatible dot-syntax: `.toggleAutoClicker` resolves to `.builtin(.toggleAutoClicker)`.
extension HotkeyAction {
    static let toggleAutoClicker = HotkeyAction.builtin(.toggleAutoClicker)
    static let toggleKeyPresser = HotkeyAction.builtin(.toggleKeyPresser)
    static let toggleWebTarget = HotkeyAction.builtin(.toggleWebTarget)
    static let toggleRecording = HotkeyAction.builtin(.toggleRecording)
    static let togglePlayback = HotkeyAction.builtin(.togglePlayback)
    static let stopAll = HotkeyAction.builtin(.stopAll)

    /// The six builtin actions in declaration order.
    static var builtins: [HotkeyAction] { BuiltinHotkeyAction.allCases.map(HotkeyAction.builtin) }

    var title: String {
        builtin?.title ?? "Play macro"
    }

    var defaultCombo: KeyCombo? {
        builtin?.defaultCombo
    }
}

extension KeyCombo {
    /// Matches a physical key event: the Carbon hotkey's key code, and the user must be
    /// holding at least the combo's modifiers (releasing one from a superset still counts).
    func matches(keyCode: CGKeyCode, modifiers: KeyModifiers) -> Bool {
        self.keyCode == UInt32(keyCode) && modifiers.isSuperset(of: self.modifiers)
    }
}
