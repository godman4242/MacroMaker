import AppKit
import Carbon.HIToolbox

/// System-wide keyboard shortcuts via Carbon's `RegisterEventHotKey` — works while any app is
/// frontmost and, unlike event taps, needs no permission.
@MainActor @Observable
final class HotkeyService {
    private(set) var combos: [HotkeyAction: KeyCombo]
    /// Shortcuts macOS refused to register, usually because another app already owns them.
    private(set) var unavailable: Set<HotkeyAction> = []

    @ObservationIgnored var onTrigger: ((HotkeyAction) -> Void)?
    @ObservationIgnored private var registered: [HotkeyAction: EventHotKeyRef] = [:]
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var suspendCount = 0

    private static let storageKey = "hotkeys"
    private static let signature: OSType = 0x4D4D_4B52 // "MMKR"
    private static weak var active: HotkeyService?

    init() {
        let saved = Persistence.load([HotkeyAction: KeyCombo?].self, key: Self.storageKey) ?? [:]
        var combos: [HotkeyAction: KeyCombo] = [:]
        for action in HotkeyAction.allCases {
            // Missing from storage → default; stored as null → the user cleared it.
            combos[action] = saved[action] ?? action.defaultCombo
        }
        self.combos = combos
    }

    func activate() {
        installHandler()
        registerAll()
    }

    /// Assigns a shortcut. If another action already uses it, that action loses it.
    func setCombo(_ combo: KeyCombo?, for action: HotkeyAction) {
        if let combo {
            for (other, existing) in combos where other != action && existing == combo {
                combos[other] = nil
            }
        }
        combos[action] = combo
        save()
        registerAll()
    }

    func restoreDefaults() {
        combos = Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map { ($0, $0.defaultCombo) })
        save()
        registerAll()
    }

    /// Temporarily disables all shortcuts, e.g. while the user is typing a new one.
    func suspend() {
        suspendCount += 1
        unregisterAll()
    }

    func resume() {
        suspendCount = max(0, suspendCount - 1)
        if suspendCount == 0 { registerAll() }
    }

    func label(for action: HotkeyAction) -> String? {
        combos[action]?.displayString
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map { ($0, combos[$0]) })
        Persistence.save(stored, key: Self.storageKey)
    }

    private func registerAll() {
        unregisterAll()
        guard suspendCount == 0 else { return }
        var failed = Set<HotkeyAction>()
        for (index, action) in HotkeyAction.allCases.enumerated() {
            guard let combo = combos[action] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index))
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers.carbonFlags, id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registered[action] = ref
            } else {
                failed.insert(action)
            }
        }
        if failed != unavailable { unavailable = failed }
    }

    private func unregisterAll() {
        for ref in registered.values { UnregisterEventHotKey(ref) }
        registered.removeAll()
    }

    private func installHandler() {
        guard handler == nil else { return }
        Self.active = self
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == HotkeyService.signature else { return OSStatus(eventNotHandledErr) }
            // Carbon delivers application events on the main thread.
            MainActor.assumeIsolated {
                let actions = HotkeyAction.allCases
                guard Int(hotKeyID.id) < actions.count else { return }
                HotkeyService.active?.onTrigger?(actions[Int(hotKeyID.id)])
            }
            return noErr
        }, 1, &eventType, nil, &handler)
    }
}

extension KeyCombo {
    @MainActor var displayString: String {
        modifiers.symbols + KeyboardLayout.displayName(for: CGKeyCode(keyCode))
    }
}
