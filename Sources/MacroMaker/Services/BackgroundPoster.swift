import AppKit
import CoreGraphics
import Foundation
import os

/// Posts mouse and keyboard events straight into a chosen app's process (`CGEventPostToPid`),
/// so the target window can sit behind other apps or on another Space — and the cursor never moves.
///
/// The click events follow the documented recipe for background delivery: screen-space CGEvents
/// built via `NSEvent.mouseEvent` (so the 12 auto-filled fields stay populated), seeded with the
/// target window's number, whose private window-target fields (91/92) and subtype 3 name the
/// window under the point. The window-local point is applied through the private
/// `CGEventSetWindowLocation` symbol — resolved and round-trip validated once at launch, and
/// re-applied after `setSource`. A missing symbol or failed aim fails the click loudly instead
/// of posting a mis-aimed event; no fake modifiers ride a background click.
enum BackgroundPoster {

    /// One of an app's usable windows, as plain data (the testable seam over the window server).
    struct Window: Equatable, Sendable {
        let id: CGWindowID
        let bounds: CGRect
    }

    /// A running app the user can target.
    struct ListedApp: Identifiable, Equatable, Sendable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    // MARK: Window lookup

    /// Field numbers from the research summary that a background-post event must not overwrite.
    static let protectedFields: [UInt32] = [0, 1, 2, 41, 43, 44, 50, 51, 55, 59, 102, 108]

    /// kCGMouseEventWindowUnderMousePointer — names the window the click is aimed at.
    private static let windowField = CGEventField(rawValue: 91)!
    /// kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent.
    private static let handlerWindowField = CGEventField(rawValue: 92)!

    /// Pure filter over one raw CGWindowInfo dictionary: the app's layer-0 windows only.
    static func window(fromInfo info: [String: Any], ownerPID: pid_t) -> Window? {
        guard let owner = info[kCGWindowOwnerPID as String] as? Int, owner == ownerPID,
              let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
              let number = info[kCGWindowNumber as String] as? Int, number > 0,
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any] as CFDictionary?,
              let bounds = CGRect(dictionaryRepresentation: boundsDict),
              bounds.width > 0, bounds.height > 0
        else { return nil }
        return Window(id: CGWindowID(number), bounds: bounds)
    }

    /// The app's usable layer-0 windows over one window-server listing (front to back).
    static func windows(ofPID pid: pid_t, in list: [[String: Any]]) -> [Window] {
        list.compactMap { window(fromInfo: $0, ownerPID: pid) }
    }

    /// The window-server listing, as a seam (see `nsMouseEventBuilder`): tests seed the two
    /// listings the resolvers ask for — on-screen first, `.optionAll` for occlusion — without
    /// querying the real window server.
    nonisolated(unsafe) static var windowListCopy: (CGWindowListOption) -> [[String: Any]]? = { options in
        CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
    }

    /// Re-runs the window-server queries: on-screen first, `.optionAll` fallback for occlusion.
    ///
    /// With a captured point, containment must be settled across BOTH listings before any
    /// window is accepted (review N2): the picked window can be minimized or on another
    /// Space — visible only to `.optionAll` — while the app's other window is front-most in
    /// the on-screen listing. Accepting that one aimed the click at (and the clamp kept it
    /// inside) a window the user never picked. Only when no listing contains the point does
    /// the front-most fallback win, front-most of the first listing that has any window.
    static func resolveWindowLive(ofPID pid: pid_t, containing point: CGPoint? = nil) -> Window? {
        var frontMost: Window?
        for options in [CGWindowListOption.optionOnScreenOnly, .optionAll] {
            guard let list = windowListCopy(options) else { continue }
            let windows = windows(ofPID: pid, in: list)
            if let point {
                if let hit = windows.first(where: { $0.bounds.contains(point) }) { return hit }
            } else if let front = windows.first {
                return front
            }
            if frontMost == nil { frontMost = windows.first }
        }
        return frontMost
    }

    /// Every usable window of the app, live: the pick-time containment check (H4) needs all of
    /// them, not just the front-most. Same on-screen-first, `.optionAll`-fallback rule.
    static func resolveWindowsLive(ofPID pid: pid_t) -> [Window] {
        for options in [CGWindowListOption.optionOnScreenOnly, .optionAll] {
            guard let list = windowListCopy(options) else { continue }
            let windows = windows(ofPID: pid, in: list)
            if !windows.isEmpty { return windows }
        }
        return []
    }

    /// One run's reuse of window-server queries: both listings are cached for 300 ms — misses
    /// included, so a hidden-window run can't re-query the window server once per click (a 1 ms
    /// interval would otherwise mean ~300 listings/second for however long the window stays
    /// hidden). A resolution failure re-pulls on the next tick past the TTL; a success is reused
    /// without paying `CGWindowListCopyWindowInfo` per click.
    final class WindowResolver: @unchecked Sendable {
        private static let ttl: TimeInterval = 0.3

        private let lock = NSLock()
        nonisolated(unsafe) private var cacheDate: Date?
        /// Last resolution when the cache was fresh — including a negative one (the occlusion
        /// fallback has already run for this window of time, so don't fall through twice).
        nonisolated(unsafe) private var lastWindow: Window??

        init() {}

        /// The worker's per-click window lookup, preferring the window that contains the click
        /// point (F6). Cheap while fresh — the point is only a preference at resolve time, so the
        /// cached window can outlive a jittered point's containment; on expiry (or after a
        /// failure) both listings are re-pulled and the `.optionAll` fallback runs again.
        func window(ofPID pid: pid_t, containing point: CGPoint?) -> Window? {
            lock.lock()
            defer { lock.unlock() }
            if let cacheDate, Date().timeIntervalSince(cacheDate) < Self.ttl, let window = lastWindow {
                return window
            }
            let window = BackgroundPoster.resolveWindowLive(ofPID: pid, containing: point)
            self.cacheDate = Date()
            self.lastWindow = .some(window)
            return window
        }
    }

    // MARK: Apps

    /// The target's pid and active state from the lock-protected snapshot — callable from a
    /// worker thread without ever waiting on main (TargetSnapshot refreshes itself on main).
    nonisolated static func targetState(forBundleID bundleID: String) -> (pid: pid_t?, isActive: Bool) {
        TargetSnapshot.shared.targetState(forBundleID: bundleID)
    }

    @MainActor static func processID(forBundleID bundleID: String) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
    }

    /// Bundle id → pid as a seam, for the worker-thread paths (recorder anchors, window
    /// binding at replay): they can't hop to main, and tests have no real running apps.
    nonisolated(unsafe) static var pidResolver: @Sendable (String) -> pid_t? = { bundleID in
        MainActor.assumeIsolated { processID(forBundleID: bundleID) }
    }

    /// Regular apps the user could plausibly click in, without Macro Maker itself.
    @MainActor static func targetableApps() -> [ListedApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in
                app.bundleIdentifier.map { ListedApp(bundleID: $0, name: app.localizedName ?? $0) }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Window-location seam

    /// Runtime seam for the private `CGEventSetWindowLocation` symbol — swapped for a fake in tests.
    protocol WindowLocationResolver {
        var isAvailable: Bool { get }
        /// Signature validation (F14): true when a set→get round-trip stores the point. The
        /// default vouches only for availability — the system resolver measures the round-trip.
        func signatureRoundTrips() -> Bool
        /// Applies a window-local point to the event. Returns false when the symbol is missing.
        @discardableResult func setWindowLocation(of event: CGEvent, to point: CGPoint) -> Bool
    }

    struct SystemWindowLocationResolver: WindowLocationResolver {
        private typealias Setter = @convention(c) (CGEvent, CGPoint) -> Void
        private typealias Getter = @convention(c) (CGEvent) -> CGPoint

        /// Seam over dlsym so tests can force the missing-symbol path (F14) without touching
        /// the dyld tables. Read once per resolver instance, at init.
        nonisolated(unsafe) static var symbolLookup: (String) -> UnsafeMutableRawPointer? = { name in
            // RTLD_DEFAULT is ((void *) -2) in dlfcn.h; the macro doesn't import into Swift.
            dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
        }

        private let setter: Setter?
        private let getter: Getter?

        init() {
            setter = Self.symbolLookup("CGEventSetWindowLocation").map { unsafeBitCast($0, to: Setter.self) }
            getter = Self.symbolLookup("CGEventGetWindowLocation").map { unsafeBitCast($0, to: Getter.self) }
        }

        var isAvailable: Bool { setter != nil }

        /// The private API's C signature is assumed, not documented — a set→get round-trip on
        /// a scratch event proves the call takes (event, point) and stores it, instead of every
        /// posted click silently mis-aiming.
        func signatureRoundTrips() -> Bool {
            guard let setter, let getter,
                  let scratch = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                        mouseCursorPosition: .zero, mouseButton: .left)
            else { return false }
            let probe = CGPoint(x: 123, y: 456)
            setter(scratch, probe)
            return getter(scratch) == probe
        }

        @discardableResult func setWindowLocation(of event: CGEvent, to point: CGPoint) -> Bool {
            guard let setter else { return false }
            setter(event, point)
            return true
        }
    }

    nonisolated(unsafe) static var windowLocationResolver: any WindowLocationResolver = SystemWindowLocationResolver()

    private static let targetingLog = Logger(subsystem: "MacroMaker", category: "BackgroundPoster")

    /// The launch-time verdict (F14): nil until validation fails. A set line disables
    /// directApp targeting loudly — `targetingSupported` goes false and `directAppProblem`
    /// says so — instead of posting mis-aimed events.
    nonisolated(unsafe) static var windowTargetingProblem: String?

    /// One-time startup validation: symbol presence plus signature round-trip. Called once
    /// from AppModel.launch; takes the resolver so tests can drive each failure branch.
    @discardableResult
    static func validateWindowTargeting(resolver: (any WindowLocationResolver)? = nil) -> Bool {
        let resolver = resolver ?? windowLocationResolver
        guard resolver.isAvailable else {
            windowTargetingProblem = "background window targeting not supported on this OS: CGEventSetWindowLocation is missing"
            targetingLog.warning("directApp targeting disabled: \(windowTargetingProblem ?? "", privacy: .public)")
            return false
        }
        guard resolver.signatureRoundTrips() else {
            windowTargetingProblem = "background window targeting not supported on this OS: CGEventSetWindowLocation doesn't behave as (event, point)"
            targetingLog.warning("directApp targeting disabled: \(windowTargetingProblem ?? "", privacy: .public)")
            return false
        }
        windowTargetingProblem = nil
        targetingLog.info("directApp targeting validated: window-location symbol present and round-trips")
        return true
    }

    /// False triggers the loud UI failure: background clicks can't be aimed without the symbol.
    static var targetingSupported: Bool {
        windowLocationResolver.isAvailable && windowTargetingProblem == nil
    }

    // MARK: Coordinates & flags

    /// Screen point → window-local point (translate by the negative window origin).
    static func windowPoint(fromScreenPoint point: CGPoint, window: Window) -> CGPoint {
        CGPoint(x: point.x - window.bounds.origin.x, y: point.y - window.bounds.origin.y)
    }

    // MARK: Posting

    /// The CGEvent type NSEvent reports via the CGEventType property for one of our mouse events
    /// (NSEvent.dragged→moved, so a synthesized drag must not be mistaken for a user move here).
    static func equivalentCGEventType(_ type: NSEvent.EventType) -> CGEventType {
        switch type {
        case .leftMouseDown: .leftMouseDown
        case .leftMouseUp: .leftMouseUp
        case .leftMouseDragged: .leftMouseDragged
        case .rightMouseDown: .rightMouseDown
        case .rightMouseUp: .rightMouseUp
        case .rightMouseDragged: .rightMouseDragged
        case .otherMouseDown: .otherMouseDown
        case .otherMouseUp: .otherMouseUp
        case .otherMouseDragged: .otherMouseDragged
        default: .null
        }
    }

    /// The NSEvent type to seed `mouseEvent(with:)` with for a recipe event type (the reverse of
    /// `equivalentCGEventType`, minus drags — background clicks only ever post down/up). Anything
    /// else returns nil so a bad type fails loudly instead of synthesizing a move.
    private static func nsEventType(_ type: CGEventType) -> NSEvent.EventType? {
        switch type {
        case .leftMouseDown: .leftMouseDown
        case .leftMouseUp: .leftMouseUp
        case .rightMouseDown: .rightMouseDown
        case .rightMouseUp: .rightMouseUp
        case .otherMouseDown: .otherMouseDown
        case .otherMouseUp: .otherMouseUp
        default: nil
        }
    }

    /// One mouse transition aimed at the window, ready to post to the owning process.
    ///
    /// Built through `NSEvent.mouseEvent(...).cgEvent` per the researched recipe: NSEvent fills the
    /// 12 protected field numbers (0,1,2,41,43,44,50,51,55,59,102,108). The event is seeded with
    /// the target window's NUMBER (F1: windowNumber 0 resolves to no window in the target's
    /// AppKit — the classic silently-dropped click), plus button and click count. The window-target
    /// payload itself (subtype, fields 91/92, the private window location) is applied at post
    /// time, after `setSource` — see `post(_:window:screenPoint:pid:)`.
    /// Top-left global (CG) Y → bottom-left global (AppKit) Y. NSEvent.mouseEvent takes AppKit
    /// coordinates and flips Y into CG display space itself, so a screen-space (top-left) point
    /// must be pre-flipped — otherwise it lands mirrored (1080 − y) in the posted event.
    /// A top-left screen Y as the bottom-left AppKit Y that `NSEvent.mouseEvent` expects.
    ///
    /// The flip constant is the PRIMARY screen's maxY, not the union of every screen.
    /// `NSEvent.mouseEvent(...).cgEvent` performs its own flip, and it was measured directly:
    /// on a 1920x1080 primary, appKitY + cgY == 1080.0 for every input. Flipping about the union
    /// agrees with that only while the primary is the topmost display — put a second display
    /// above it and every background click lands high by exactly the overhang. `MacroRecorder`
    /// already flips about `NSScreen.screens.first` for the inverse conversion; this is now
    /// consistent with it. Using `.first` also removes the empty-screens case: the union of no
    /// rects is `CGRect.null`, whose maxY is +infinity.
    static func appKitY(fromScreenY y: CGFloat, screenFrames: [CGRect]) -> CGFloat {
        (screenFrames.first?.maxY ?? 0) - y
    }

    /// The AppKit conversion the recipe builds on. A seam: `NSEvent.mouseEvent` is documented
    /// to be able to return nil, and tests force that path to prove the failure surfaces
    /// instead of swallowing the click.
    nonisolated(unsafe) static var nsMouseEventBuilder:
        (_ type: NSEvent.EventType, _ location: CGPoint, _ clickCount: Int,
         _ windowNumber: Int, _ pressure: Float) -> CGEvent? = { type, location, clickCount, windowNumber, pressure in
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: windowNumber, context: nil, eventNumber: 0,
                               clickCount: clickCount, pressure: pressure)?.cgEvent
        }

    static func mouseEvent(_ type: CGEventType, button: MouseButton, clickCount: Int,
                           screenPoint: CGPoint, window: Window) -> CGEvent? {
        let appKitPoint = CGPoint(x: screenPoint.x,
                                  y: appKitY(fromScreenY: screenPoint.y, screenFrames: NSScreen.screens.map(\.frame)))
        guard let nsType = nsEventType(type),
              let event = nsMouseEventBuilder(nsType, appKitPoint, clickCount, Int(window.id),
                                              button == .left ? 1 : 0)
        else { return nil }
        event.type = type  // NSEvent.dragged flattens to mouseMoved on some paths; restore the recipe's type.
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.cgButton.rawValue))
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        return event
    }

    /// A complete click delivered to the process: down, hold, up. False = undelivered: nothing
    /// went out (the AppKit conversion returned nil, or the window aim was refused), so the
    /// caller must not count the click — F5's silent swallow ends here.
    @discardableResult
    static func click(_ button: MouseButton, screenPoint: CGPoint, holdFor duration: TimeInterval,
                      clickCount: Int, window: Window, pid: pid_t) -> Bool {
        guard post(mouseEvent(button.downEventType, button: button, clickCount: clickCount,
                              screenPoint: screenPoint, window: window),
                   window: window, screenPoint: screenPoint, pid: pid) else { return false }
        if duration > 0 { Thread.sleep(forTimeInterval: duration) }
        return post(mouseEvent(button.upEventType, button: button, clickCount: clickCount,
                               screenPoint: screenPoint, window: window),
                    window: window, screenPoint: screenPoint, pid: pid)
    }

    /// Delivery seam: swapped in tests so `click` can be asserted without hitting real processes.
    nonisolated(unsafe) static var eventPoster: (CGEvent, pid_t) -> Void = { $0.postToPid($1) }

    private static func post(_ event: CGEvent?, window: Window, screenPoint: CGPoint, pid: pid_t) -> Bool {
        guard let event else {
            // F5: NSEvent.mouseEvent is documented to be able to return nil. That used to
            // vanish silently — nothing posted, and the caller still counted a delivery.
            targetingLog.warning("background click lost: the AppKit event conversion returned nil")
            return false
        }
        // Re-home the event onto a fresh private source before posting. NSEvent's .cgEvent is
        // shared-sourced (stateID 0), and posting through that source at click rates wedges its
        // cumulative modifier/button state — ⌘ then reads as physically held to the window
        // server (fake-⌘-clicking every window you touch, defeating ⌘Tab's app switch) and no
        // key-up ever clears it; only quitting the poster does. A fresh source has no history,
        // so nothing outlives a run.
        let fresh = CGEventSource(stateID: .hidSystemState)
        fresh?.localEventsSuppressionInterval = 0
        event.setSource(fresh)
        // Everything delivery-visible goes on AFTER setSource, never before: setSource resets
        // source-owned per-event data — measured directly, .eventSourceUserData read back as
        // 0 when written first, and one proven wipe is enough to put everything delivery
        // depends on (flags, subtype, fields 91/92, the private window location, the self-tag)
        // on the safe side of the call. (Measured with no modifiers held, setSource happens
        // not to rewrite flags — the same ordering posture applies regardless: the source's
        // state is live the moment a user is holding keys.)
        // Same contract as the HID path: explicit flags only (never the user's held keys —
        // and no fake ⌘; background clicks stopped pretending modifiers are held).
        event.flags = .maskNonCoalesced
        event.setIntegerValueField(.mouseEventSubtype, value: 3)
        event.setIntegerValueField(windowField, value: Int64(window.id))
        event.setIntegerValueField(handlerWindowField, value: Int64(window.id))
        guard windowLocationResolver.setWindowLocation(
            of: event, to: windowPoint(fromScreenPoint: screenPoint, window: window)) else {
            // Fail loud, not mis-aimed: a click the resolver can't aim never leaves the app.
            targetingLog.warning("background click lost: the window aim was refused — nothing posted")
            return false
        }
        // The self-tag rides the same after-setSource rule (see above).
        event.setIntegerValueField(.eventSourceUserData, value: EventSynthesizer.eventTag)
        eventPoster(event, pid)
        return true
    }

    // MARK: Keyboard

    /// One key transition delivered to the process (no windows involved — keys go to whatever has
    /// focus *inside* the app, so the app should be brought forward first for reliable typing).
    static func keyEvent(_ code: CGKeyCode, down: Bool, flags: CGEventFlags,
                         isRepeat: Bool = false, pid: pid_t) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return }
        if isRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        postKey(event, flags: flags, pid: pid)
    }

    /// Types a character that isn't a physical key by attaching it as a Unicode string.
    static func textEvent(_ text: String, down: Bool, pid: pid_t) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { return }
        let utf16 = Array(text.utf16)
        event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        postKey(event, flags: [], pid: pid)
    }

    private static func postKey(_ event: CGEvent, flags: CGEventFlags, pid: pid_t) {
        // Same fresh-source rule as the mouse path: these events are built with a nil source.
        let fresh = CGEventSource(stateID: .hidSystemState)
        fresh?.localEventsSuppressionInterval = 0
        event.setSource(fresh)
        // Everything delivery-visible after setSource, same as the mouse path — flags included.
        event.flags = flags.union(.maskNonCoalesced)
        event.setIntegerValueField(.eventSourceUserData, value: EventSynthesizer.eventTag)
        eventPoster(event, pid)
    }
}

extension BackgroundPoster.WindowLocationResolver {
    /// Default signature validation: vouches only for availability — the system resolver
    /// measures the actual set→get round-trip.
    func signatureRoundTrips() -> Bool { isAvailable }
}
