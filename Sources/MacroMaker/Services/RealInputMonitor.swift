import AppKit
import CoreGraphics
import Foundation

/// Watches for the *user's own* keyboard and mouse presses so a running feature can pause
/// ("you took over"). Listen-only: the tap never swallows or modifies events.
///
/// Implemented as an NSEvent global monitor rather than a CGEvent tap so no extra permission
/// is needed — the macOS privacy prompt for input monitoring covers recording already, and a
/// passive `.keyDown` mask on the global monitor is enough to spot real key presses without
/// that entitlement. Mouse buttons are always visible there.
@MainActor
final class RealInputMonitor {
    static let shared = RealInputMonitor()

    private var monitors: [Any] = []
    /// Reentrant: several features could watch at once; the tap lives while any remain.
    private var subscribers = 0
    private var onRealInput: () -> Void = {}

    private init() {}

    /// Which raw event types count as "the user took over". Macro-tagged events are filtered,
    /// so synthesised clicks never pause a run.
    static let watchedTypes: [NSEvent.EventTypeMask] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]

    /// Starts watching. `onRealInput` fires on every real key/mouse press until `stop`.
    func start(onRealInput: @escaping () -> Void) {
        self.onRealInput = onRealInput
        subscribers += 1
        guard monitors.isEmpty else { return }
        let mask = Self.watchedTypes.reduce(NSEvent.EventTypeMask()) { $0.union($1) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard RealInputRules.isReal(event) else { return }
            self?.fire()
        } {
            monitors.append(global)
        }
    }

    func stop() {
        subscribers = max(0, subscribers - 1)
        guard subscribers == 0 else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func fire() {
        let handler = onRealInput
        handler()
    }
}

/// Pure idle-timing decision for pause-on-real-input's auto-resume.
enum RealInputRules {
    /// True when an incoming event is the user's own input, not Macro Maker's output
    /// (synthetic events carry the self-tag in .eventSourceUserData; a real event doesn't).
    nonisolated static func isReal(_ event: NSEvent) -> Bool {
        guard let cgEvent = event.cgEvent else { return true }
        return cgEvent.getIntegerValueField(.eventSourceUserData) != EventSynthesizer.eventTag
    }

    /// True when the user's last own input happened at least `afterSeconds` before `now`.
    static func idleEnough(lastInputAt: Date, afterSeconds: Double, now: Date) -> Bool {
        now.timeIntervalSince(lastInputAt) >= max(1, afterSeconds)
    }
}
