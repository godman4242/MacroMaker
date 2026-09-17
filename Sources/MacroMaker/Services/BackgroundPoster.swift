import AppKit
import CoreGraphics
import Foundation

/// Posts mouse and keyboard events straight into a chosen app's process (`CGEventPostToPid`),
/// so the target window can sit behind other apps or on another Space — and the cursor never moves.
///
/// The click events follow the documented recipe for background delivery: screen-space CGEvents
/// built via `NSEvent.mouseEvent` (so the 12 auto-filled fields stay populated), whose private
/// window-target fields (91/92) name the window under the point, subtype 3, and — when the app
/// isn't active — the NX_COMMAND bit set so AppKit doesn't drop the click.
/// The window-local point is applied through the private `CGEventSetWindowLocation` symbol,
/// looked up at runtime and optional-chained: if it can't be resolved the UI says so loudly.
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

    /// The app's front-most usable window over one window-server listing (front to back).
    /// `optionOnScreenOnly` first; a fully covered (occluded) window then falls back to
    /// `.optionAll`, still layer-0 filtered — an occluded app is no excuse to drop its clicks.
    static func primaryWindow(ofPID pid: pid_t, in list: [[String: Any]]) -> Window? {
        list.lazy.compactMap { window(fromInfo: $0, ownerPID: pid) }.first
    }

    /// Re-runs the window-server queries: on-screen first, `.optionAll` fallback for occlusion.
    static func resolveWindowLive(ofPID pid: pid_t) -> Window? {
        for options in [CGWindowListOption.optionOnScreenOnly, .optionAll] {
            guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { continue }
            if let window = primaryWindow(ofPID: pid, in: list) { return window }
        }
        return nil
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

        /// The worker's per-click window lookup. Cheap while fresh; on expiry (or after a
        /// failure) both listings are re-pulled and the `.optionAll` fallback runs again.
        func window(ofPID pid: pid_t) -> Window? {
            lock.lock()
            defer { lock.unlock() }
            if let cacheDate, Date().timeIntervalSince(cacheDate) < Self.ttl, let window = lastWindow {
                return window
            }
            let window = BackgroundPoster.resolveWindowLive(ofPID: pid)
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

    /// Regular apps the user could plausibly click in, without Macro Maker itself.
    @MainActor static func targetableApps() -> [ListedApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in
                app.bundleIdentifier.map { ListedApp(bundleID: $0, name: app.localizedName ?? $0) }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Which app is active right now (the ⌘-flag rule depends on it).
    @MainActor static func isActive(bundleID: String) -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    // MARK: Window-location seam

    /// Runtime seam for the private `CGEventSetWindowLocation` symbol — swapped for a fake in tests.
    protocol WindowLocationResolver {
        var isAvailable: Bool { get }
        /// Applies a window-local point to the event. Returns false when the symbol is missing.
        @discardableResult func setWindowLocation(of event: CGEvent, to point: CGPoint) -> Bool
    }

    struct SystemWindowLocationResolver: WindowLocationResolver {
        private typealias CFunction = @convention(c) (CGEvent, CGPoint) -> Void
        private let function: CFunction? = {
            // RTLD_DEFAULT is ((void *) -2) in dlfcn.h; the macro doesn't import into Swift.
            let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
            guard let symbol = dlsym(rtldDefault, "CGEventSetWindowLocation") else { return nil }
            return unsafeBitCast(symbol, to: CFunction.self)
        }()

        var isAvailable: Bool { function != nil }

        @discardableResult func setWindowLocation(of event: CGEvent, to point: CGPoint) -> Bool {
            guard let function else { return false }
            function(event, point)
            return true
        }
    }

    nonisolated(unsafe) static var windowLocationResolver: any WindowLocationResolver = SystemWindowLocationResolver()

    /// False triggers the loud UI failure: background clicks can't be aimed without the symbol.
    static var targetingSupported: Bool { windowLocationResolver.isAvailable }

    // MARK: Coordinates & flags

    /// Screen point → window-local point (translate by the negative window origin).
    static func windowPoint(fromScreenPoint point: CGPoint, window: Window) -> CGPoint {
        CGPoint(x: point.x - window.bounds.origin.x, y: point.y - window.bounds.origin.y)
    }

    /// 0x00100000 is the NX_COMMAND device-independent bit. Background-posted clicks are dropped
    /// by AppKit unless the event pretends ⌘ is held when the target app isn't the active one.
    static let backgroundClickFlag = CGEventFlags(rawValue: 0x0010_0000)

    static func clickFlags(appIsActive: Bool) -> CGEventFlags {
        appIsActive ? [] : backgroundClickFlag
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
    /// 12 protected field numbers (0,1,2,41,43,44,50,51,55,59,102,108), and only the recipe's own
    /// fields (3 button, 7 subtype, 91/92 window ids) plus the window-local point are written after.
    /// The ⌘-flag background trick is *not* baked in here — it is applied at post time, where the
    /// active-state snapshot lives.
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

    static func mouseEvent(_ type: CGEventType, button: MouseButton, clickCount: Int,
                           screenPoint: CGPoint, window: Window) -> CGEvent? {
        let appKitPoint = CGPoint(x: screenPoint.x,
                                  y: appKitY(fromScreenY: screenPoint.y, screenFrames: NSScreen.screens.map(\.frame)))
        guard let nsType = nsEventType(type),
              let event = NSEvent.mouseEvent(with: nsType, location: appKitPoint, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: 0, context: nil, eventNumber: 0,
                                             clickCount: clickCount, pressure: button == .left ? 1 : 0)?.cgEvent
        else { return nil }
        event.type = type  // NSEvent.dragged flattens to mouseMoved on some paths; restore the recipe's type.
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.cgButton.rawValue))
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event.setIntegerValueField(.mouseEventSubtype, value: 3)
        event.setIntegerValueField(windowField, value: Int64(window.id))
        event.setIntegerValueField(handlerWindowField, value: Int64(window.id))
        windowLocationResolver.setWindowLocation(of: event, to: windowPoint(fromScreenPoint: screenPoint, window: window))
        return event
    }

    /// A complete click delivered to the process: down, hold, up.
    static func click(_ button: MouseButton, screenPoint: CGPoint, holdFor duration: TimeInterval,
                      clickCount: Int, window: Window, pid: pid_t, appIsActive: Bool) {
        post(mouseEvent(button.downEventType, button: button, clickCount: clickCount,
                        screenPoint: screenPoint, window: window),
             appIsActive: appIsActive, pid: pid)
        if duration > 0 { Thread.sleep(forTimeInterval: duration) }
        post(mouseEvent(button.upEventType, button: button, clickCount: clickCount,
                        screenPoint: screenPoint, window: window),
             appIsActive: appIsActive, pid: pid)
    }

    /// Delivery seam: swapped in tests so `click` can be asserted without hitting real processes.
    nonisolated(unsafe) static var eventPoster: (CGEvent, pid_t) -> Void = { $0.postToPid($1) }

    private static func post(_ event: CGEvent?, appIsActive: Bool, pid: pid_t) {
        guard let event else { return }
        // Same contract as the HID path: explicit flags (never the user's held keys) and the
        // self-tag so the recorder ignores Macro Maker's own output.
        event.flags = clickFlags(appIsActive: appIsActive).union(.maskNonCoalesced)
        // Re-home the event onto a fresh private source before posting. NSEvent's .cgEvent is
        // shared-sourced (stateID 0), and posting through that source at click rates wedges its
        // cumulative modifier/button state — ⌘ then reads as physically held to the window
        // server (fake-⌘-clicking every window you touch, defeating ⌘Tab's app switch) and no
        // key-up ever clears it; only quitting the poster does. A fresh source has no history,
        // so nothing outlives a run.
        let fresh = CGEventSource(stateID: .hidSystemState)
        fresh?.localEventsSuppressionInterval = 0
        event.setSource(fresh)
        // The self-tag goes on AFTER setSource, never before: setSource resets
        // .eventSourceUserData to the new source's own user data. Measured: the tag read back as
        // 0 when written first, so every background-posted event went out untagged and
        // pause-on-real-input would treat the clicker's own clicks as the user taking over.
        event.setIntegerValueField(.eventSourceUserData, value: EventSynthesizer.eventTag)
        eventPoster(event, pid)
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
        event.flags = flags.union(.maskNonCoalesced)
        // Same fresh-source rule as the mouse path: these events are built with a nil source.
        let fresh = CGEventSource(stateID: .hidSystemState)
        fresh?.localEventsSuppressionInterval = 0
        event.setSource(fresh)
        // Tag after setSource — see post(_:appIsActive:pid:).
        event.setIntegerValueField(.eventSourceUserData, value: EventSynthesizer.eventTag)
        eventPoster(event, pid)
    }
}
