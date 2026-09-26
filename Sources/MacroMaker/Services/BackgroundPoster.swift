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
    /// Chromium's synthetic-event filter reads the target pid here (cua-driver recipe f40).
    /// Field 51 (the NSEvent-bridge window number, also in the recipe) is NOT stamped here:
    /// `NSEvent.mouseEvent(with: windowNumber:)` already populated it — field 51 is on the
    /// `protectedFields` list of values this code must never overwrite, and re-stamping the
    /// same window number would be that, with nothing gained.
    private static let targetPidField = CGEventField(rawValue: 40)!
    /// Gesture-phase marker — see `Phase`. Chromium tells the primer from the real click by it.
    private static let gesturePhaseField = CGEventField(rawValue: 0)!
    /// Click-group id: one value shared by every event of a gesture, so the target coalesces them.
    private static let clickGroupField = CGEventField(rawValue: 58)!

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

    // MARK: Game route

    /// The topmost on-screen window owner at a screen point — pure over one listing (the
    /// window server returns front to back), so it tests without the window server. The
    /// game route posts REAL clicks, which land on whatever is topmost at the point: this
    /// is the truth that decides whether the point is visibly the target's right now.
    ///
    /// ANY layer counts, not just 0: a real click lands on the menu bar, the Dock and
    /// notification banners (all non-layer-0 surfaces) exactly as readily as on an app
    /// window, so a spot under one of those is NOT the target's to click — whatever the
    /// layer-0 stacking says. The FIRST entry containing the point wins; a zero-size
    /// window never matches.
    static func topmostWindowOwner(at point: CGPoint, in list: [[String: Any]]) -> pid_t? {
        (topmostWindowInfo(at: point, in: list)?[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) }
    }

    /// The topmost on-screen entry at a point (any layer, same rule as `topmostWindowOwner`) —
    /// the recorder also needs its layer and bounds, not just its owner.
    static func topmostWindowInfo(at point: CGPoint, in list: [[String: Any]]) -> [String: Any]? {
        list.first { info in
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any] as CFDictionary?,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 0, bounds.height > 0,
                  info[kCGWindowOwnerPID as String] is Int
            else { return false }
            return bounds.contains(point)
        }
    }

    /// Live topmost owner at a point — the single-shot lookups (test click, status line).
    static func topmostOwner(at point: CGPoint) -> pid_t? {
        guard let list = windowListCopy(.optionOnScreenOnly) else { return nil }
        return topmostWindowOwner(at: point, in: list)
    }

    /// Where a main-actor block runs: INLINE when the caller is already on the main thread,
    /// a main-queue hop otherwise (the caller never blocks on main). The Test Click's raise
    /// depends on the inline half: it runs on main and then sleeps ~250 ms to let the raise
    /// land — with an async-only runner the queued activate sits BEHIND the sleeping main
    /// thread, so the click posts while the game is still backgrounded, inside its measured
    /// discard window, and the reply still said "sent" (the shipped blocker: three reviewers).
    nonisolated(unsafe) static var mainThreadRunner: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { body in
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            performOnMain(body)
        }
    }

    /// The game route's real raise. Games discard posted input while their app isn't frontmost
    /// (measured in Roblox: pixel diff 0), and a synthetic click does NOT activate a background
    /// window (measured on this machine: the cursor moved to the click point, frontmost
    /// unchanged 1.5 s later) — so a game-route run must bring the target forward itself.
    /// A seam, so tests never raise a real window.
    nonisolated(unsafe) static var appActivator: @Sendable (String) -> Void = { bundleID in
        BackgroundPoster.mainThreadRunner {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
        }
    }

    /// The gate's listing TTL, scaled to the run's own cadence: one refresh per tick at click
    /// rates, capped at the resolver's 300 ms and floored at 10 ms. A stale listing on a
    /// REAL-click route is up to a TTL of misdirected clicks after something pops over the
    /// spot — at the run's cadence that's at most one click before the next refresh.
    static func gateTTL(interval: TimeInterval) -> TimeInterval {
        min(0.3, max(0.01, interval))
    }

    /// The game route's per-click visibility gate: one on-screen listing cached for the
    /// run-interval TTL (see `gateTTL`) — a 1 ms-interval run must not re-query the window
    /// server per click. A miss means the real click would land on a window the user can't
    /// see the target owning (occluded, another Space, off-screen), so the click is refused
    /// instead of aimed blind.
    final class VisibilityGate: @unchecked Sendable {
        private let lock = NSLock()
        private let ttl: TimeInterval
        private var cacheDate: Date?
        private var cachedList: [[String: Any]]?

        init(interval: TimeInterval) {
            self.ttl = BackgroundPoster.gateTTL(interval: interval)
        }

        /// True when the TOPMOST on-screen window at the point belongs to `pid` (any layer —
        /// see `topmostWindowOwner`). A nil listing is remembered for the TTL like any other
        /// result — a hidden window can't re-query the window server once per click either.
        func isVisible(pid: pid_t, at point: CGPoint) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if cacheDate == nil || Date().timeIntervalSince(cacheDate!) >= ttl {
                cachedList = BackgroundPoster.windowListCopy(.optionOnScreenOnly)
                cacheDate = Date()
            }
            guard let list = cachedList else { return false }
            return BackgroundPoster.topmostWindowOwner(at: point, in: list) == pid
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
    /// The default reads TargetSnapshot's lock-protected cache — safe from ANY thread.
    /// (`MainActor.assumeIsolated` would trap on the playback worker thread; the recorder's
    /// main-run-loop tap was fine, but the seam must honour its own doc for both callers.)
    /// Snapshot misses resolve asynchronously on main; runs prewarm at arm-time, so a
    /// replay's first anchored step sees a warm cache (same contract AutoClicker uses).
    nonisolated(unsafe) static var pidResolver: @Sendable (String) -> pid_t? = { bundleID in
        TargetSnapshot.shared.targetState(forBundleID: bundleID).pid
    }

    /// Pid → bundle id, the reverse seam: the recorder names the app that OWNS the clicked
    /// window (not whichever app was frontmost a moment before the click activated it).
    nonisolated(unsafe) static var bundleIDResolver: @Sendable (pid_t) -> String? = { pid in
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
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
    /// `equivalentCGEventType`, minus drags — background clicks post down/up plus the leading
    /// `mouseMoved` the Chromium recipe requires). Anything else returns nil so a bad type fails
    /// loudly instead of synthesizing something the caller didn't ask for.
    private static func nsEventType(_ type: CGEventType) -> NSEvent.EventType? {
        switch type {
        case .leftMouseDown: .leftMouseDown
        case .leftMouseUp: .leftMouseUp
        case .rightMouseDown: .rightMouseDown
        case .rightMouseUp: .rightMouseUp
        case .otherMouseDown: .otherMouseDown
        case .otherMouseUp: .otherMouseUp
        case .mouseMoved: .mouseMoved
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

    /// Gesture-phase marker (field 0). Chromium's renderer reads it to tell the primer pair
    /// apart from the real click; AppKit targets ignore it.
    enum Phase {
        static let move: Int64 = 2
        static let primerDown: Int64 = 1
        static let primerUp: Int64 = 2
        static let real: Int64 = 3
    }

    /// Where the primer click lands: off every window, so it opens Chromium's user-activation
    /// gate without hitting anything on the page. Used as BOTH the screen and the window-local
    /// point — the recipe this came from stamps a literal (-1, -1) window location.
    static let primerPoint = CGPoint(x: -1, y: -1)

    /// Gaps between the events of one gesture. Below the 100 ms primer settle Chromium reads the
    /// primer and the real click as one run-on gesture and drops the second.
    static let moveSettle: TimeInterval = 0.015
    static let primerGap: TimeInterval = 0.001
    static let primerSettle: TimeInterval = 0.100

    /// A complete click delivered to the process. False = undelivered: the REAL click's event
    /// couldn't be built or aimed, so the caller must not count it — F5's silent swallow ends here.
    ///
    /// The sequence is the measured one, not a down/up pair:
    ///   stamped `mouseMoved` at the target → primer down/up off-screen → the real down/up.
    /// MEASURED 2026-09-20 on macOS 26.5.2: with only down/up, a Chromium-class target
    /// (Brave/Chrome/Electron) whose app is in the background drops the click silently — four
    /// variants confirmed, including a forced-correct window. With this sequence the same click
    /// lands pixel-exact while another app stays frontmost. AppKit targets accept it either way,
    /// so one path serves both. A primer is needed on EVERY click: skipping it after a first
    /// primed click was measured to go back to being dropped.
    @discardableResult
    static func click(_ button: MouseButton, screenPoint: CGPoint, holdFor duration: TimeInterval,
                      clickCount: Int, window: Window, pid: pid_t) -> Bool {
        // One id across every event of this gesture (field 58) so the target coalesces them as
        // one click instead of unrelated taps.
        let group = newClickGroup()
        guard press(button, down: true, screenPoint: screenPoint, clickCount: clickCount,
                    window: window, pid: pid, group: group) else { return false }
        if duration > 0 { Thread.sleep(forTimeInterval: duration) }
        return press(button, down: false, screenPoint: screenPoint, clickCount: clickCount,
                     window: window, pid: pid, group: group)
    }

    /// A fresh click-group id (field 58), shared by every event of one gesture.
    static func newClickGroup() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds & 0x7FFF_FFFF)
    }

    /// One half of `click`, for callers that time the press and the release themselves (a
    /// replayed macro holds a button as long as the recording did). The press carries the
    /// whole measured lead-in — stamped move, then the off-screen primer pair — before the
    /// real down; the release is the real up alone. Both halves of a gesture share `group`.
    /// False = the REAL event couldn't be built or aimed (nothing to count as delivered).
    /// `flags` ride the REAL down/up only (a replayed ⌘-click stays a ⌘-click); the move and
    /// the primer pair stay modifier-free, as the measured recipe posts them.
    @discardableResult
    static func press(_ button: MouseButton, down: Bool, screenPoint: CGPoint, clickCount: Int,
                      window: Window, pid: pid_t, group: Int64, flags: CGEventFlags = []) -> Bool {
        func send(_ type: CGEventType, at point: CGPoint, localPoint: CGPoint?,
                  state: Int, phase: Int64, flags: CGEventFlags = []) -> Bool {
            post(mouseEvent(type, button: button, clickCount: state,
                            screenPoint: point, window: window),
                 window: window, screenPoint: point, pid: pid,
                 phase: phase, clickGroup: group, localOverride: localPoint, flags: flags)
        }
        guard down else {
            return send(button.upEventType, at: screenPoint, localPoint: nil,
                        state: clickCount, phase: Phase.real, flags: flags)
        }
        // The primers' return values are deliberately ignored: only the real click decides
        // whether this counted, and a refused primer must not be reported as a delivered click.
        _ = send(.mouseMoved, at: screenPoint, localPoint: nil, state: 0, phase: Phase.move)
        Thread.sleep(forTimeInterval: moveSettle)
        _ = send(button.downEventType, at: primerPoint, localPoint: primerPoint,
                 state: 1, phase: Phase.primerDown)
        Thread.sleep(forTimeInterval: primerGap)
        _ = send(button.upEventType, at: primerPoint, localPoint: primerPoint,
                 state: 1, phase: Phase.primerUp)
        Thread.sleep(forTimeInterval: primerSettle)
        return send(button.downEventType, at: screenPoint, localPoint: nil,
                    state: clickCount, phase: Phase.real, flags: flags)
    }

    /// Delivery seam: swapped in tests so `click` can be asserted without hitting real processes.
    ///
    /// The default tries the private SkyLight `SLEventPostToPid` FIRST and falls back to the
    /// public `CGEventPostToPid`. Both deliver to one process without raising it, but they
    /// travel different routes: `CGEventPostToPid` skips the window-server activity tickle, and
    /// Chromium/Electron-class renderers (plus macOS 26 WebKit content processes) filter
    /// session-targeted events that lack the WindowServer trust envelope — the click reached
    /// the app's outer process and silently vanished (verified against cua-driver's SkyLight
    /// bridge and the safari-mcp #29 report, both 2026). `SLEventPostToPid` is that envelope;
    /// when its symbol is absent (older macOS, or Apple removes it) the public call is the
    /// best available delivery and still works for AppKit targets.
    nonisolated(unsafe) static var eventPoster: (CGEvent, pid_t) -> Void = { event, pid in
        if skylightPostToPid(pid, event) { return }
        event.postToPid(pid)
    }

    /// Runtime seam over the private `SLEventPostToPid` (SkyLight.framework) — resolved once
    /// per launch, like `CGEventSetWindowLocation` above. `nil` = the symbol is unavailable.
    nonisolated(unsafe) static var skylightPostResolver: @Sendable () -> (@convention(c) (pid_t, CGEvent) -> Void)? = {
        // RTLD_DEFAULT is ((void *) -2) in dlfcn.h; the macro doesn't import into Swift.
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SLEventPostToPid")
            .map { unsafeBitCast($0, to: (@convention(c) (pid_t, CGEvent) -> Void).self) }
    }

    /// Posts via SkyLight; false = symbol unavailable (the caller falls back to postToPid).
    nonisolated static func skylightPostToPid(_ pid: pid_t, _ event: CGEvent) -> Bool {
        guard let post = skylightPostResolver() else { return false }
        post(pid, event)
        return true
    }

    // MARK: Activation without raising

    /// Runtime seam over the three SkyLight/Carbon symbols the activation step needs. A test
    /// swaps this for a recorder; `nil` = a symbol is missing, so the step reports failure
    /// instead of pretending the target was activated.
    struct ActivationSymbols {
        let getFrontProcess: @convention(c) (UnsafeMutableRawPointer) -> Int32
        let postEventRecord: @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>) -> Int32
        let processForPID: @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    }

    nonisolated(unsafe) static var activationSymbols: @Sendable () -> ActivationSymbols? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let front = dlsym(rtldDefault, "_SLPSGetFrontProcess"),
              let post = dlsym(rtldDefault, "SLPSPostEventRecordTo"),
              let forPID = dlsym(rtldDefault, "GetProcessForPID")
        else { return nil }
        return ActivationSymbols(
            getFrontProcess: unsafeBitCast(front, to: (@convention(c) (UnsafeMutableRawPointer) -> Int32).self),
            postEventRecord: unsafeBitCast(post, to: (@convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>) -> Int32).self),
            processForPID: unsafeBitCast(forPID, to: (@convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32).self))
    }

    /// Makes the target app *input-active* without raising its window or taking the user's
    /// frontmost app away — the missing half of background delivery for Chromium-class targets.
    ///
    /// MEASURED 2026-09-20 (macOS 26.5.2): the full stamped + primed click sequence alone still
    /// gets dropped by a background Brave; run this once first and the same click lands, with the
    /// user's app still frontmost and Brave's window still behind. The effect PERSISTS, so a run
    /// calls this once at arm time, not per click.
    ///
    /// Two 248-byte window-server event records (`0x0D` kind): one telling the current front
    /// process it is losing focus, one telling the target window it is gaining it. Deliberately
    /// does NOT call `_SLPSSetFrontProcessWithOptions` — that is the call that raises the window
    /// and steals the user's frontmost app.
    @discardableResult
    static func activateWithoutRaise(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let symbols = activationSymbols() else {
            targetingLog.warning("activate-without-raise unavailable: a SkyLight symbol is missing")
            return false
        }
        // A Carbon ProcessSerialNumber is two UInt32s; kept as raw bytes so this never depends
        // on the deprecated Swift shim for a type it only passes through by pointer.
        let psnSize = MemoryLayout<UInt32>.size * 2
        let front = UnsafeMutableRawPointer.allocate(byteCount: psnSize, alignment: 8)
        let target = UnsafeMutableRawPointer.allocate(byteCount: psnSize, alignment: 8)
        defer { front.deallocate(); target.deallocate() }
        front.initializeMemory(as: UInt8.self, repeating: 0, count: psnSize)
        target.initializeMemory(as: UInt8.self, repeating: 0, count: psnSize)

        guard symbols.getFrontProcess(front) == 0, symbols.processForPID(pid, target) == 0 else {
            targetingLog.warning("activate-without-raise: could not resolve the process serial numbers")
            return false
        }

        var record = [UInt8](repeating: 0, count: 0xF8)
        record[0x04] = 0xF8          // record length marker
        record[0x08] = 0x0D          // focus-change record kind
        withUnsafeBytes(of: windowID.littleEndian) { raw in
            for offset in 0..<4 { record[0x3C + offset] = raw[offset] }
        }
        record[0x8A] = 0x02          // the old front process loses focus
        let defocused = record.withUnsafeMutableBufferPointer { symbols.postEventRecord(front, $0.baseAddress!) }
        record[0x8A] = 0x01          // the target window gains it
        let focused = record.withUnsafeMutableBufferPointer { symbols.postEventRecord(target, $0.baseAddress!) }

        guard defocused == 0, focused == 0 else {
            targetingLog.warning("activate-without-raise refused: defocus=\(defocused) focus=\(focused)")
            return false
        }
        // AppKit needs a moment to update its active/key-window routing before the click stream
        // arrives; without the settle the first click of a run is dropped.
        Thread.sleep(forTimeInterval: activationSettle)
        return true
    }

    static let activationSettle: TimeInterval = 0.050

    /// One run's memory of which (pid, window) it has already activated. The activation persists,
    /// so re-posting the focus records on every click would thrash window-server focus at click
    /// rates for no gain; a changed window (the user switched the target's window mid-run) or a
    /// replaced process re-arms it.
    final class Activator: @unchecked Sendable {
        private let lock = NSLock()
        private var activated: (pid: pid_t, windowID: CGWindowID)?

        init() {}

        /// True when the target was already active or has just been activated.
        @discardableResult
        func activateIfNeeded(pid: pid_t, windowID: CGWindowID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if let activated, activated == (pid, windowID) { return true }
            guard BackgroundPoster.activateWithoutRaise(pid: pid, windowID: windowID) else {
                // Leave it un-armed so the next click retries rather than latching a failure.
                return false
            }
            activated = (pid, windowID)
            return true
        }
    }

    private static func post(_ event: CGEvent?, window: Window, screenPoint: CGPoint, pid: pid_t,
                             phase: Int64 = Phase.real, clickGroup: Int64 = 0,
                             localOverride: CGPoint? = nil, flags: CGEventFlags = []) -> Bool {
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
        // and no fake ⌘; background clicks stopped pretending modifiers are held). A replayed
        // step passes its RECORDED flags; everything else passes none.
        event.flags = flags.union(.maskNonCoalesced)
        event.setIntegerValueField(.mouseEventSubtype, value: 3)
        event.setIntegerValueField(windowField, value: Int64(window.id))
        event.setIntegerValueField(handlerWindowField, value: Int64(window.id))
        // The Chromium synthetic-event filter (cua-driver recipe): the target pid rides
        // field 40, beside the 91/92 pair above.
        event.setIntegerValueField(targetPidField, value: Int64(pid))
        // Gesture phase and click-group id: Chromium reads these to tell the off-screen primer
        // from the real click and to coalesce the pair into one gesture. Field 51 (the AppKit
        // window number every working implementation agrees on) is already populated by
        // `NSEvent.mouseEvent(with:windowNumber:)` — it is on `protectedFields` for that reason.
        event.setIntegerValueField(gesturePhaseField, value: phase)
        event.setIntegerValueField(clickGroupField, value: clickGroup)
        guard windowLocationResolver.setWindowLocation(
            of: event, to: localOverride ?? windowPoint(fromScreenPoint: screenPoint, window: window)) else {
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

    static func postKey(_ event: CGEvent, flags: CGEventFlags, pid: pid_t) {
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
