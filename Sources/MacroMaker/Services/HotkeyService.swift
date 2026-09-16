import AppKit
import Carbon.HIToolbox

/// System-wide keyboard shortcuts via Carbon's `RegisterEventHotKey` — works while any app is
/// frontmost and, unlike event taps, needs no permission.
@MainActor @Observable
final class HotkeyService {
    private(set) var combos: [HotkeyAction: KeyCombo]
    /// Shortcuts macOS refused to register, usually because another app already owns them.
    private(set) var unavailable: Set<HotkeyAction> = []
    /// Dynamic actions beyond the builtins (per-macro play shortcuts), capped for slot hygiene.
    private(set) var dynamicActions: [HotkeyAction] = []

    @ObservationIgnored var onTrigger: ((HotkeyAction) -> Void)?
    /// Called on the physical key-up of a hotkey's keys (hold-to-click). Event-driven, not polled.
    @ObservationIgnored var onRelease: ((HotkeyAction, KeyCombo) -> Void)? {
        didSet { updateReleaseMonitor() }
    }
    @ObservationIgnored private var registered: [HotkeyAction: EventHotKeyRef] = [:]
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var releaseMonitor: Any?
    @ObservationIgnored private var suspendCount = 0

    private static let storageKey = "hotkeys"
    private static weak var active: HotkeyService?

    init() {
        let saved = Persistence.load([HotkeyAction: KeyCombo?].self, key: Self.storageKey) ?? [:]
        var combos: [HotkeyAction: KeyCombo] = [:]
        for action in BuiltinHotkeyAction.allCases {
            let key = HotkeyAction.builtin(action)
            // Missing from storage → default; stored as null → the user cleared it.
            combos[key] = saved[key] ?? action.defaultCombo
        }
        self.combos = combos
        // Restore saved dynamic (per-macro) combos without restoring their defaults.
        for (action, combo) in saved where action.builtin == nil {
            dynamicActions.append(action)
            if let combo { self.combos[action] = combo }
        }
    }

    func activate() {
        installHandler()
        registerAll()
        updateReleaseMonitor()
    }

    /// Adds (or no-ops) a dynamic hotkey action, e.g. "play macro X". Returns false past the cap.
    @discardableResult
    func addDynamicAction(_ action: HotkeyAction) -> Bool {
        guard action.builtin == nil else { return true }
        guard !dynamicActions.contains(action) else { return true }
        guard dynamicActions.count < HotkeyAction.maxMacroHotkeys else { return false }
        dynamicActions.append(action)
        return true
    }

    /// Removes a dynamic action and its combo.
    func removeDynamicAction(_ action: HotkeyAction) {
        guard action.builtin == nil else { return }
        dynamicActions.removeAll { $0 == action }
        combos[action] = nil
        save()
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

    /// The action currently holding a combo, if any — for conflict warnings.
    func owner(of combo: KeyCombo) -> HotkeyAction? {
        combos.first { $0.value == combo }?.key
    }

    func restoreDefaults() {
        var restored: [HotkeyAction: KeyCombo] = [:]
        for action in BuiltinHotkeyAction.allCases {
            restored[.builtin(action)] = action.defaultCombo
        }
        for action in dynamicActions { combos[action] = nil }
        dynamicActions = []
        combos = restored
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
        var stored: [HotkeyAction: KeyCombo?] = [:]
        for action in BuiltinHotkeyAction.allCases {
            stored[.builtin(action)] = combos[.builtin(action)]
        }
        for action in dynamicActions {
            stored[action] = combos[action]
        }
        Persistence.save(stored, key: Self.storageKey)
    }

    private func registerAll() {
        unregisterAll()
        guard suspendCount == 0 else { return }
        var failed = Set<HotkeyAction>()
        for (action, combo) in combos {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: HotkeyAction.signature, id: action.slotID)
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

    /// Debug hook for tests: what does the persisted "hotkeys" blob actually decode to?
    private func installHandler() {
        guard handler == nil else { return }
        Self.active = self
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == HotkeyAction.signature else { return OSStatus(eventNotHandledErr) }
            // Carbon delivers application events on the main thread.
            MainActor.assumeIsolated {
                guard let service = HotkeyService.active else { return }
                var lookup: [UUID: HotkeyAction] = [:]
                for action in service.dynamicActions {
                    if case let .macro(id) = action { lookup[id] = action }
                }
                guard let action = HotkeyAction.action(forSlotID: hotKeyID.id, macros: &lookup) else { return }
                service.onTrigger?(action)
            }
            return noErr
        }, 1, &eventType, nil, &handler)
    }

    /// Hold-to-click: a global monitor (no permission needed for monitor-only `keyUp` taps on
    /// macOS 14+; falls back to a local monitor if the global one fails) watches for the physical
    /// key-up of any registered combo and reports it. Event-driven — never polled.
    private func updateReleaseMonitor() {
        if let releaseMonitor {
            NSEvent.removeMonitor(releaseMonitor)
            self.releaseMonitor = nil
        }
        guard onRelease != nil else { return }
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleRelease(event)
            }
        }
        releaseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp, handler: handler)
            ?? NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
                handler(event)
                return event
            }
    }

    private func handleRelease(_ event: NSEvent) {
        let modifiers = KeyModifiers(event.modifierFlags)
        for (action, combo) in combos {
            guard combo.matches(keyCode: CGKeyCode(event.keyCode), modifiers: modifiers) else { continue }
            onRelease?(action, combo)
        }
    }
}

extension KeyCombo {
    @MainActor var displayString: String {
        modifiers.symbols + KeyboardLayout.displayName(for: CGKeyCode(keyCode))
    }
}
