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
///
/// **Single-subscriber** (asserted in debug): it exists for pause-on-real-input, which only the
/// AutoClicker uses; a second subscriber would silently eat the first one's callback.
@MainActor
final class RealInputMonitor {
    static let shared = RealInputMonitor()

    private var monitors: [Any] = []
    /// Reentrant *stop* bookkeeping is deliberate: start asserts single-subscriber in debug, but
    /// a stop imbalance still leaves the tap up while any subscriber is registered.
    private var subscribers = 0
    private var onRealInput: () -> Void = {}
    /// Set when no monitor could be installed (global denied *and* local returned nil) so the
    /// feature can say "pause-on-real-input can't work" instead of silently never firing.
    private(set) var lastFailure: String?

    private init() {}

    /// Which raw event types count as "the user took over". Macro-tagged events are filtered,
    /// so synthesised clicks never pause a run.
    static let watchedTypes: [NSEvent.EventTypeMask] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]

    /// Starts watching. `onRealInput` fires on every real key/mouse press until `stop`.
    /// Returns false (and records `lastFailure`) when no monitor could be installed.
    @discardableResult
    func start(onRealInput: @escaping () -> Void) -> Bool {
        assert(subscribers == 0,
               "RealInputMonitor is single-subscriber; a second start replaces the first callback.")
        self.onRealInput = onRealInput
        subscribers += 1
        guard monitors.isEmpty else { return true }
        let mask = Self.watchedTypes.reduce(NSEvent.EventTypeMask()) { $0.union($1) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard RealInputRules.isReal(event) else { return }
            self?.fire()
        }) {
            monitors.append(global)
            lastFailure = nil
            return true
        }
        // Global monitors need nothing for these passive types on macOS 14+, but an EventKit-style
        // edge (or an older OS) can deny them; a local monitor still covers input aimed at us.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            if RealInputRules.isReal(event) { self?.fire() }
            return event
        }) {
            monitors.append(local)
            lastFailure = nil
            return true
        }
        lastFailure = "Pause-on-real-input isn't available: macOS refused both input monitors."
        return false
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
