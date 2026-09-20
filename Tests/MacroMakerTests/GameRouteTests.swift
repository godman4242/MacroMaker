import CoreGraphics
import Foundation
import Testing

@testable import MacroMaker

/// The game route ("It's a game — send real clicks that move the cursor"): game-class targets
/// (Roblox & co.) read a click's position from the system cursor and discard input while not
/// frontmost — both MEASURED — so the PID route's window-aimed background posts can never reach
/// them. The route swaps delivery to a REAL HID-tap click at the captured point, plus one real
/// raise of the game at run start (a synthetic click does NOT activate a background window —
/// measured), a per-click frontmost guard and visibility gate (a real click lands on whatever
/// is topmost, at ANY window layer), and a 15 ms down→up hold floor.
///
/// One serialized suite: these tests share the TargetSnapshot, the BackgroundPoster seams
/// (windowListCopy, eventPoster, appActivator, mainThreadRunner) and the EventSynthesizer seams
/// (eventPoster, cursorLocationReader, mouseBuilder). Every run aims at Finder through seeded
/// window listings, so nothing is ever posted to the real window server and no real window is
/// ever raised.
@Suite("Game route", .serialized, .seamSerialized)
@MainActor
struct GameRouteTests {

    // MARK: Settings — the flag must survive persistence

    /// A decode line that's missing would be invisible to every other test: an absent key
    /// decodes to the fallback either way. This is the silent-loss guard.
    @Test func theGameRouteFlagDefaultsOffAndRoundTrips() throws {
        let fromEmpty = try JSONDecoder().decode(AutoClickerSettings.self, from: Data("{}".utf8))
        #expect(fromEmpty.directAppGameRoute == false, "absent key = off, never an error")
        var on = AutoClickerSettings(); on.directAppGameRoute = true
        var off = AutoClickerSettings(); off.directAppGameRoute = false
        #expect(try JSONDecoder().decode(AutoClickerSettings.self,
                                         from: JSONEncoder().encode(on)).directAppGameRoute == true,
                "a saved ON toggle must come back ON — losing it silently reverts the user to the broken-for-games route")
        #expect(try JSONDecoder().decode(AutoClickerSettings.self,
                                         from: JSONEncoder().encode(off)).directAppGameRoute == false)
    }

    // MARK: Pure routing math

    /// The hold floor: a pair that completes inside one game poll tick is swallowed while
    /// CGEventPost reports success (RobloxAuto's measured warning; cliclick's hard-coded 15 ms).
    @Test func theGameRouteHoldFloorsAt15ms() {
        #expect(TickSchedule.gameRouteHold(interval: 0.001) == 0.015)
        #expect(TickSchedule.gameRouteHold(interval: 0.05) == 0.015)
        #expect(TickSchedule.gameRouteHold(interval: 1.0) == 0.015)
    }

    /// The gate's listing TTL follows the run's cadence: one refresh per tick at click rates,
    /// capped at the resolver's 300 ms, floored at 10 ms. A stale listing on a REAL-click route
    /// is misdirected clicks after something pops over the spot — the cap bounds that at one.
    @Test func theVisibilityGateTTLFollowsTheRunsCadence() {
        #expect(BackgroundPoster.gateTTL(interval: 0.001) == 0.01,
                "a 1 ms run refreshes the listing every tick, not every 300 ms")
        #expect(BackgroundPoster.gateTTL(interval: 0.05) == 0.05,
                "a 50 ms run's gate TTL is its own interval")
        #expect(BackgroundPoster.gateTTL(interval: 1.0) == 0.3,
                "slow runs never wait longer than the resolver's 300 ms contract")
    }

    /// Clamp and the gate must agree on the window's max edge: the shipped pair held opposite
    /// boundary semantics (clamp clamped ONTO rect.maxX; the gate's containment is
    /// max-exclusive), so jitter toward the far edge was refused as "covered" by nothing.
    @Test func clampNeverHandsTheGateAPointOnTheWindowsMaxEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let wayOut = ClickGeometry.clamp(CGPoint(x: 3000, y: 3000), to: bounds)
        #expect(bounds.contains(wayOut),
                "a clamped point must satisfy the gate's containment, got (\(wayOut.x), \(wayOut.y))")
        let onEdge = ClickGeometry.clamp(CGPoint(x: 2000, y: 600), to: bounds)
        #expect(onEdge.x < bounds.maxX,
                "the max edge steps one ULP inside — a real click ON the boundary lands on the neighbour")
        #expect(bounds.contains(onEdge), "…and that point is the gate's to accept")
    }

    /// The visibility gate's truth function, pure over one listing: the FIRST window containing
    /// the point wins (the window server lists front to back); ANY layer counts — a real click
    /// lands on the menu bar, the Dock or a notification banner (all non-layer-0 surfaces)
    /// exactly as readily as on an app window, so those DO occlude the spot. A zero-size or
    /// absent window never matches.
    @Test func topmostWindowOwnerPicksTheFrontmostWindowAtAnyLayer() {
        let p = CGPoint(x: 100, y: 100)
        func info(pid: Int, number: Int, layer: Int, x: Double, y: Double, w: Double, h: Double)
            -> [String: Any] {
            [kCGWindowOwnerPID as String: pid, kCGWindowNumber as String: number,
             kCGWindowLayer as String: layer,
             kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h]]
        }
        let target = info(pid: 401, number: 7, layer: 0, x: 0, y: 0, w: 2000, h: 1200)
        let occluder = info(pid: 999, number: 8, layer: 0, x: 50, y: 50, w: 200, h: 200)
        let menuBar = info(pid: 501, number: 9, layer: 25, x: 0, y: 0, w: 4000, h: 4000)
        let bannerElsewhere = info(pid: 502, number: 11, layer: 20, x: 500, y: 500, w: 100, h: 100)
        let zeroSize = info(pid: 3, number: 10, layer: 0, x: 0, y: 0, w: 0, h: 0)
        #expect(BackgroundPoster.topmostWindowOwner(at: p, in: [target]) == 401)
        #expect(BackgroundPoster.topmostWindowOwner(at: p, in: [occluder, target]) == 999,
                "front to back: whatever covers the point owns a real click there")
        #expect(BackgroundPoster.topmostWindowOwner(at: p, in: [menuBar, target]) == 501,
                "a non-zero-layer surface (menu bar, Dock band, banner) DOES receive a real click — it owns the point")
        #expect(BackgroundPoster.topmostWindowOwner(at: p, in: [bannerElsewhere, target]) == 401,
                "an overlay elsewhere on screen doesn't own this point")
        #expect(BackgroundPoster.topmostWindowOwner(at: p, in: [zeroSize, target]) == 401,
                "a zero-size window can't contain the point")
        #expect(BackgroundPoster.topmostWindowOwner(at: CGPoint(x: 5000, y: 5000),
                                                    in: [occluder, target]) == nil,
                "a point inside no window is nobody's")
    }

    // MARK: Shared test plumbing

    /// Records every event that reached the swapped EventSynthesizer seam, with the uptime
    /// each one was posted at — the route's TIMING (hold floor, raise settle) is part of its
    /// contract, not just its event stream.
    private final class HidBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [CGEvent] = []
        private var _times: [UInt64] = []
        var events: [CGEvent] {
            lock.lock(); defer { lock.unlock() }
            return _events
        }
        var times: [UInt64] {
            lock.lock(); defer { lock.unlock() }
            return _times
        }
        var poster: (CGEvent) -> Void {
            { [self] event in
                lock.lock(); defer { lock.unlock() }
                _events.append(event)
                _times.append(DispatchTime.now().uptimeNanoseconds)
            }
        }
    }

    /// A cursor-reader script: the first read returns one point, every later read another —
    /// models "the click moved the cursor" without a hand on the physical mouse.
    private final class CursorReads: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private let first: CGPoint
        private let then: CGPoint
        init(first: CGPoint, then: CGPoint) {
            self.first = first
            self.then = then
        }
        var reader: @Sendable () -> CGPoint {
            { [self] in
                lock.lock(); defer { lock.unlock() }
                calls += 1
                return calls == 1 ? first : then
            }
        }
    }

    /// Records whether a main-thread block ran inline on the calling thread — as the swapped
    /// runner seam (records at hop time) or as the probe body the DEFAULT runner executes
    /// (records at body time).
    private final class InlineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _inline: [Bool] = []
        var inline: [Bool] {
            lock.lock(); defer { lock.unlock() }
            return _inline
        }
        private func record() {
            lock.lock(); defer { lock.unlock() }
            _inline.append(Thread.isMainThread)
        }
        /// The `BackgroundPoster.mainThreadRunner` seam shape.
        var runner: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void {
            { [self] _ in self.record() }
        }
        /// An inert body the DEFAULT runner can execute — records and does nothing else.
        var probe: @MainActor @Sendable () -> Void { { [self] in self.record() } }
    }

    /// Counts calls through a swapped seam (the PID-route poster, the activator).
    private final class CallBox: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
        private func bump() {
            lock.lock(); defer { lock.unlock() }
            count += 1
        }
        /// The `BackgroundPoster.appActivator` shape.
        var activator: @Sendable (String) -> Void { { [self] _ in self.bump() } }
        /// The `BackgroundPoster.eventPoster` (PID route) shape.
        var pidPoster: @Sendable (CGEvent, pid_t) -> Void { { [self] _, _ in self.bump() } }
    }

    /// Holds a seeded window listing for a @Sendable seam — `[[String: Any]]` isn't Sendable,
    /// so it can't be captured directly.
    private final class WindowListBox: @unchecked Sendable {
        let list: [[String: Any]]
        init(_ list: [[String: Any]]) { self.list = list }
    }

    private func windowInfo(pid: pid_t, number: Int, layer: Int, x: Double, y: Double, w: Double, h: Double)
        -> [String: Any] {
        [kCGWindowOwnerPID as String: Int(pid), kCGWindowNumber as String: number,
         kCGWindowLayer as String: layer,
         kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h]]
    }

    /// One window of the target app covering the whole seeded screen.
    private func targetWindow(pid: pid_t) -> [[String: Any]] {
        [windowInfo(pid: pid, number: 7, layer: 0, x: 0, y: 0, w: 2000, h: 1200)]
    }

    /// The same, with another app's window on top of the captured point (listings are front
    /// to back): the resolver can still aim, the gate must refuse.
    private func occludedTargetWindow(pid: pid_t) -> [[String: Any]] {
        [windowInfo(pid: 999, number: 8, layer: 0, x: 0, y: 0, w: 2000, h: 1200),
         windowInfo(pid: pid, number: 7, layer: 0, x: 0, y: 0, w: 2000, h: 1200)]
    }

    private struct RunStage {
        let hid = HidBox()
        let pidPosts = CallBox()
        let raises = CallBox()
        let pid: pid_t
        init(pid: pid_t) { self.pid = pid }
    }

    /// The default settings every run test starts from: direct-app at Finder, game route ON,
    /// clicking (100,100) inside a 2000×1200 seeded window at 50 ms intervals.
    private func gameSettings() -> AutoClickerSettings {
        var s = AutoClickerSettings()
        s.target = .directApp
        s.directAppBundleID = "com.apple.finder"
        s.directAppX = 100
        s.directAppY = 100
        s.directAppGameRoute = true
        s.intervalMs = 50
        return s
    }

    /// Swaps in a fully armed game-route stage and restores everything on any exit path,
    /// including thrown `#require` failures. `windowList` is given the target's pid. The cursor
    /// reader is pinned to a constant, so restore-cursor tests never read the physical mouse.
    private func withStage(with settings: AutoClickerSettings,
                           windowList: @escaping (_ pid: pid_t) -> [[String: Any]],
                           _ body: (RunStage, AutoClicker) async throws -> Void) async throws {
        let model = AppModel.shared
        let clicker = model.autoClicker
        let defaults = UserDefaults.standard
        let savedSettingsBlob = defaults.data(forKey: AutoClicker.storageKey)
        let savedSettings = clicker.settings
        let savedHidPoster = EventSynthesizer.eventPoster
        let savedPidPoster = BackgroundPoster.eventPoster
        let savedLister = BackgroundPoster.windowListCopy
        let savedActivator = BackgroundPoster.appActivator
        let savedFrontmost = TargetSnapshot.shared.frontmostBundleIDForTests
        let savedCursorReader = EventSynthesizer.cursorLocationReader
        defer {
            // Stop any still-live worker BEFORE the real HID poster goes back in: a worker
            // that outlived the test body would otherwise post REAL input through the
            // restored tap.
            model.stopAll()
            EventSynthesizer.eventPoster = savedHidPoster
            BackgroundPoster.eventPoster = savedPidPoster
            BackgroundPoster.windowListCopy = savedLister
            BackgroundPoster.appActivator = savedActivator
            TargetSnapshot.shared.frontmostBundleIDForTests = savedFrontmost
            EventSynthesizer.cursorLocationReader = savedCursorReader
            model.permissions.forceAccessibilityTrusted = false
            clicker.settings = savedSettings
            // Byte-identical defaults restore: the re-assign above re-encoded the blob.
            if let savedSettingsBlob { defaults.set(savedSettingsBlob, forKey: AutoClicker.storageKey) }
            else { defaults.removeObject(forKey: AutoClicker.storageKey) }
        }

        // A real running target (Finder) so the snapshot's pid resolution and the run's
        // identity check exercise their real path; every delivery seam is swapped.
        TargetSnapshot.shared.prewarm(bundleID: "com.apple.finder")
        let pid = try #require(TargetSnapshot.shared.targetState(forBundleID: "com.apple.finder").pid,
                               "Finder must be running for the game-route run tests")
        let stage = RunStage(pid: pid)
        EventSynthesizer.eventPoster = stage.hid.poster
        // The PID route must never be taken by a game-route run — COUNTING its posts is
        // the assertion, so it can't quietly no-op into a pass.
        BackgroundPoster.eventPoster = stage.pidPosts.pidPoster
        BackgroundPoster.appActivator = stage.raises.activator
        let seeds = WindowListBox(windowList(pid))
        BackgroundPoster.windowListCopy = { [seeds] _ in seeds.list }
        // The "cursor" never moves unless a test says it did — the old restore test read the
        // REAL cursor and went red whenever the machine's mouse moved during the suite.
        EventSynthesizer.cursorLocationReader = { CGPoint(x: 404, y: 404) }
        model.permissions.forceAccessibilityTrusted = true
        clicker.settings = settings
        try await body(stage, clicker)
    }

    private func runToIdle(_ clicker: AutoClicker) async throws {
        let deadline = Date().addingTimeInterval(5)
        while clicker.session.phase != .idle, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(clicker.session.phase == .idle, "the run must end on its own within the test budget")
    }

    // MARK: The run — real HID clicks at the point, never a PID post

    /// The route's core contract: every click is one REAL down/up pair at the (clamped)
    /// captured point via the HID seam — self-tagged, no fake modifiers, NONE of the PID
    /// route's window-target fields, no primer pair, and the PID poster never called. The
    /// run also performs exactly one real raise of the target (it wasn't frontmost) and the
    /// raise LANDS — the activator brings the game forward like production, so the run's
    /// clicks pass the frontmost guard. The TIMING is asserted too: the down→up hold (games
    /// swallow pairs that complete inside one poll tick) and the raise's 250 ms settle
    /// before the first click.
    @Test func aGameRouteRunPostsRealClicksAtThePointAndNeverTakesThePidRoute() async throws {
        var s = gameSettings()
        s.stopAfterClicks = true
        s.maxClicks = 3
        try await withStage(with: s, windowList: targetWindow) { stage, clicker in
            // The raise lands like production: the activator call both counts and brings
            // the game forward (the frontmost seam flips to the target).
            let raises = stage.raises
            BackgroundPoster.appActivator = { bundleID in
                raises.activator(bundleID)
                TargetSnapshot.shared.frontmostBundleIDForTests = "com.apple.finder"
            }
            let t0 = DispatchTime.now().uptimeNanoseconds
            clicker.toggle(.hotkey)
            try await runToIdle(clicker)

            #expect(clicker.clickCount == 3, "three delivered clicks counted, got \(clicker.clickCount)")
            #expect(clicker.runWarning == nil,
                    "a fully visible target is not a warning, got: \(clicker.runWarning ?? "")")
            #expect(stage.pidPosts.calls == 0,
                    "the PID route must never post on the game route — its window-aimed events are what games ignore")
            #expect(stage.raises.calls == 1,
                    "one raise of the not-frontmost target at run start, got \(stage.raises.calls)")

            let events = stage.hid.events
            #expect(events.count == 6, "3 clicks × exactly [down, up] — no primer, no move, got \(events.count)")
            for (i, event) in events.enumerated() {
                let expectedType: CGEventType = i % 2 == 0 ? .leftMouseDown : .leftMouseUp
                #expect(event.type == expectedType, "event \(i) must alternate down/up, got \(event.type)")
                #expect(event.location == CGPoint(x: 100, y: 100),
                        "every event lands at the captured point, got (\(event.location.x), \(event.location.y))")
                #expect(event.flags == .maskNonCoalesced, "no fake modifiers ride a real click")
                #expect(event.getIntegerValueField(.eventSourceUserData) == EventSynthesizer.eventTag,
                        "self-tagged so the recorder ignores the clicker's own output")
                // The PID recipe's window-target fields must stay EMPTY here: they aim a
                // background post, and RobloxAuto documents the off-screen primer pair they
                // ride on registering as clicks of its own.
                #expect(event.getIntegerValueField(CGEventField(rawValue: 91)!) == 0)
                #expect(event.getIntegerValueField(CGEventField(rawValue: 92)!) == 0)
                #expect(event.getIntegerValueField(CGEventField(rawValue: 40)!) == 0)
            }

            // WHEN, not just WHAT — the two timing contracts the route exists on:
            let times = stage.hid.times
            #expect(!times.isEmpty)
            #expect(times[0] - t0 >= 200_000_000,
                    "the first click must come ~250 ms after the raise (the settle), got \((times.first ?? 0 - t0) / 1_000_000) ms")
            for c in 0..<3 {
                let downAt = times[2 * c], upAt = times[2 * c + 1]
                #expect(upAt - downAt >= 14_000_000,
                        "click \(c): the down→up hold must be at least ~15 ms — a pair that completes inside one game poll tick is swallowed, got \((upAt - downAt) / 1_000_000) ms")
            }
        }
    }

    /// A covered spot refuses the click — fail loud, count nothing. A real click at an
    /// occluded point would hit whatever covers it: another app's window.
    @Test func anOccludedSpotRefusesEveryClickAndWarnsInstead() async throws {
        var s = gameSettings()
        s.stopAfterClicks = true
        s.maxClicks = 5          // never reached — the gate refuses everything
        s.stopAfterDuration = true
        s.maxDurationSeconds = 0.3
        try await withStage(with: s, windowList: occludedTargetWindow) { stage, clicker in
            TargetSnapshot.shared.frontmostBundleIDForTests = "com.apple.finder"  // the game is up
            clicker.toggle(.hotkey)
            try await runToIdle(clicker)

            #expect(clicker.clickCount == 0,
                    "a click that would land on another app's window must never be counted")
            #expect(clicker.runWarning?.contains("visible") == true,
                    "the user must learn WHY: the spot is covered, got: \(clicker.runWarning ?? "nil")")
            #expect(stage.hid.events.isEmpty, "nothing may be posted when the gate refuses")
        }
    }

    /// The frontmost guard: while the game is NOT frontmost it discards every posted click
    /// (measured), so the run refuses to post at all — no cursor movement, no counting — and
    /// the banner says what to do. The run keeps looping (self-heals the moment the user
    /// switches back), unlike stop-on-frontmost-change which ends it.
    @Test func aRunRefusesClicksWhileTheGameIsNotFrontmostAndCountsNothing() async throws {
        var s = gameSettings()
        s.stopAfterClicks = true
        s.maxClicks = 5          // never reached — every click is refused
        s.stopAfterDuration = true
        s.maxDurationSeconds = 0.4
        try await withStage(with: s, windowList: targetWindow) { stage, clicker in
            TargetSnapshot.shared.frontmostBundleIDForTests = "com.example.other"  // the user cmd-tabbed away
            clicker.toggle(.hotkey)
            try await runToIdle(clicker)

            #expect(clicker.clickCount == 0,
                    "clicks a backgrounded game discards are never counted, got \(clicker.clickCount)")
            #expect(clicker.runWarning?.contains("frontmost") == true,
                    "the banner must say the game isn't frontmost, got: \(clicker.runWarning ?? "nil")")
            #expect(stage.hid.events.isEmpty,
                    "no real click is posted while the game would eat it — the cursor stays put")
            #expect(stage.raises.calls == 1,
                    "the raise is still attempted once at run start, got \(stage.raises.calls)")
        }
    }

    /// restoreCursor ON, cursor never moved (the reader is pinned to a constant): exactly
    /// [down, up] per click — a spurious restore move would put a mouseMoved between pairs.
    /// The pinned reader is the point: the old version read the REAL cursor and this test
    /// went red whenever the machine's mouse moved during the suite.
    @Test func restoreCursorOnAddsNoMoveWhenTheCursorNeverMoved() async throws {
        var s = gameSettings()
        s.restoreCursor = true
        s.stopAfterClicks = true
        s.maxClicks = 2
        try await withStage(with: s, windowList: targetWindow) { stage, clicker in
            TargetSnapshot.shared.frontmostBundleIDForTests = "com.apple.finder"
            clicker.toggle(.hotkey)
            try await runToIdle(clicker)

            #expect(clicker.clickCount == 2)
            #expect(stage.hid.events.count == 4, "2 clicks × [down, up], no restore move in between")
            for (i, event) in stage.hid.events.enumerated() {
                #expect(event.type != .mouseMoved, "event \(i): no move when the cursor never moved")
            }
        }
    }

    /// The mirror the old suite never covered: when the cursor DID move (here: the reader
    /// seam moves it between the before-read and the after-read — the click's own effect),
    /// the restore move must fire — one real .mouseMoved back to where the cursor was.
    @Test func restoreCursorOnMovesTheCursorBackWhenItMoved() async throws {
        var s = gameSettings()
        s.restoreCursor = true
        s.stopAfterClicks = true
        s.maxClicks = 1
        try await withStage(with: s, windowList: targetWindow) { stage, clicker in
            TargetSnapshot.shared.frontmostBundleIDForTests = "com.apple.finder"
            // The "cursor" starts at (11, 11) and reads as (100, 100) with the click landed:
            EventSynthesizer.cursorLocationReader = CursorReads(first: CGPoint(x: 11, y: 11),
                                                                 then: CGPoint(x: 100, y: 100)).reader
            clicker.toggle(.hotkey)
            try await runToIdle(clicker)

            #expect(clicker.clickCount == 1)
            let events = stage.hid.events
            #expect(events.count == 3, "down, up, then one restore move, got \(events.count)")
            #expect(events[2].type == .mouseMoved, "the third event is the cursor going back")
            #expect(events[2].location == CGPoint(x: 11, y: 11),
                    "back to where the cursor was before the click, got (\(events[2].location.x), \(events[2].location.y))")
        }
    }

    // MARK: Stop-on-frontmost-change — the baseline is pinned to the TARGET

    /// The game coming forward is the route working, not a change: with the game frontmost
    /// (the state after the run's raise), a stop-on-frontmost-change run must keep clicking
    /// to its click limit, not stop after the first check.
    @Test func theRunKeepsClickingWhileTheGameIsFrontmost() async throws {
        var s = gameSettings()
        s.stopOnFrontmostChange = true
        s.stopAfterClicks = true
        s.maxClicks = 3
        try await withStage(with: s, windowList: targetWindow) { _, clicker in
            TargetSnapshot.shared.frontmostBundleIDForTests = "com.apple.finder"   // the raise landed
            clicker.toggle(.hotkey)
            try await runToIdle(clicker)

            #expect(clicker.clickCount == 3,
                    "the target being frontmost is the pinned baseline, not a change — got \(clicker.clickCount)")
        }
    }

    /// And the flip side: the target pinned as the baseline means a run whose raise never
    /// landed (frontmost is someone else) STOPS instead of clicking a game that is
    /// discarding every event — the first click is now refused by the frontmost guard, so
    /// nothing is counted and the warning says why. runToIdle proves the run STOPPED:
    /// without the pin, the sampled baseline would equal the un-raised frontmost and the
    /// run would refuse-click forever without ever ending.
    @Test func theRunStopsWhenTheGameNeverComesForward() async throws {
        var s = gameSettings()
        s.stopOnFrontmostChange = true
        s.stopAfterClicks = true
        s.maxClicks = 3
        try await withStage(with: s, windowList: targetWindow) { _, clicker in
            TargetSnapshot.shared.frontmostBundleIDForTests = "com.example.other"  // raise never landed
            clicker.toggle(.hotkey)
            try await runToIdle(clicker)

            #expect(clicker.clickCount == 0,
                    "frontmost ≠ the pinned target: the run stops with nothing counted, got \(clicker.clickCount)")
            #expect(clicker.runWarning?.contains("frontmost") == true,
                    "and the banner says the game isn't frontmost: \(clicker.runWarning ?? "nil")")
        }
    }

    /// The pin must not LEAK through a stale flag: the toggle lives in the direct-app
    /// section, so switching to fixed-point hides it — with the pin keyed on the flag
    /// alone, a later fixed-point run with stop-on-frontmost-change would baseline itself
    /// on a game bundle that never ran and stop after its first click.
    @Test func theGameRouteBaselinePinStaysInsideDirectApp() async throws {
        var s = gameSettings()
        s.target = .fixedPoint       // leaves the direct-app section; the flag stays ON
        s.directAppGameRoute = true  // the stale flag under test
        s.directAppBundleID = "com.example.game"  // NOT the frontmost — a leaked pin would differ
        s.stopOnFrontmostChange = true
        s.stopAfterClicks = true
        s.maxClicks = 3
        try await withStage(with: s, windowList: targetWindow) { stage, clicker in
            TargetSnapshot.shared.frontmostBundleIDForTests = "com.apple.finder"
            clicker.toggle(.hotkey)
            try await runToIdle(clicker)

            #expect(clicker.clickCount == 3,
                    "a fixed-point run baselines on the real frontmost, not a stale game bundle — got \(clicker.clickCount)")
            let events = stage.hid.events
            #expect(events.count == 6, "three fixed-point clicks, got \(events.count)")
            #expect(events.allSatisfy { $0.location == CGPoint(x: 500, y: 500) },
                    "the fixed point, not the game route's captured spot")
        }
    }

    // MARK: Test Click — a real click the user can watch, with a real raise when needed

    /// The happy path: the game frontmost (no raise needed — none may happen), one REAL
    /// click at the point via the HID seam, never a PID post, and a reply that says the
    /// click was real instead of the old "sent" that read as "it works".
    @Test func aGameRouteTestClickIsRealAndSkipsTheRaiseWhenTheGameIsFrontmost() async throws {
        try await withStage(with: gameSettings(), windowList: targetWindow) { stage, clicker in
            TargetSnapshot.shared.frontmostBundleIDForTests = "com.apple.finder"
            let reply = clicker.testClick()

            #expect(reply.hasPrefix("Test click sent to "), "delivered: \(reply)")
            #expect(reply.contains("real click"), "the reply must say the click was real: \(reply)")
            #expect(stage.hid.events.count == 2, "one down/up pair for a single click")
            #expect(stage.pidPosts.calls == 0, "the PID route is never taken")
            #expect(stage.raises.calls == 0,
                    "the game is already frontmost — raising it anyway would steal the user's focus for nothing")
        }
    }

    /// A covered spot fails the test click loudly, posts nothing, and never claims "sent".
    @Test func aGameRouteTestClickRefusesAnOccludedSpot() async throws {
        try await withStage(with: gameSettings(), windowList: occludedTargetWindow) { stage, clicker in
            TargetSnapshot.shared.frontmostBundleIDForTests = "com.apple.finder"
            let reply = clicker.testClick()

            #expect(!reply.hasPrefix("Test click sent"), "an occluded spot must not claim success: \(reply)")
            #expect(reply.contains("visible"), "the failure must say why: \(reply)")
            #expect(stage.hid.events.isEmpty, "nothing is posted at a spot the user can't see")
        }
    }

    /// The game in the background: the test click raises it for real (a synthetic click does
    /// NOT activate a background window — measured), the raise LANDS (the activator brings
    /// the game forward like production), and only then — after the 250 ms settle, TIMED —
    /// does the real click go out, so the user watches it land.
    @Test func aGameRouteTestClickRaisesABackgroundGameBeforeClicking() async throws {
        try await withStage(with: gameSettings(), windowList: targetWindow) { stage, clicker in
            TargetSnapshot.shared.frontmostBundleIDForTests = "com.example.other"  // game in the back
            let raises = stage.raises
            BackgroundPoster.appActivator = { bundleID in
                raises.activator(bundleID)
                TargetSnapshot.shared.frontmostBundleIDForTests = "com.apple.finder"  // the raise landed
            }
            let t0 = DispatchTime.now().uptimeNanoseconds
            let reply = clicker.testClick()

            #expect(reply.hasPrefix("Test click sent to "), "delivered after the raise: \(reply)")
            #expect(stage.raises.calls == 1,
                    "the raise is the whole point of the game coming to the front, got \(stage.raises.calls)")
            #expect(stage.hid.events.count == 2, "then one real down/up at the point")
            // The settle is load-bearing and TIMED: the raise runs inline on main, and this
            // thread sleeps 250 ms so the game's input gate is OPEN when the click lands.
            // Removing the sleep must go red.
            let first = try #require(stage.hid.times.first)
            #expect(first - t0 >= 200_000_000,
                    "the click must come at least ~250 ms after the raise was issued (the settle), got \((first - t0) / 1_000_000) ms")
        }
    }

    /// The honesty check the shipped version skipped: when the raise NEVER lands (the
    /// activator is a no-op, the game stays in the back), the game is still discarding input
    /// — a real click posted now is eaten while looking delivered. The test click must
    /// refuse, post nothing, and say what happened instead of claiming "sent".
    @Test func aGameRouteTestClickAdmitsItWhenTheRaiseNeverLands() async throws {
        try await withStage(with: gameSettings(), windowList: targetWindow) { stage, clicker in
            TargetSnapshot.shared.frontmostBundleIDForTests = "com.example.other"  // and the raise can't fix it
            let reply = clicker.testClick()

            #expect(!reply.hasPrefix("Test click sent"),
                    "a click the game would discard must never claim success: \(reply)")
            #expect(reply.contains("didn't come to the front"),
                    "the failure must name the raise not landing: \(reply)")
            #expect(stage.hid.events.isEmpty, "nothing is posted into the game's discard window")
            #expect(stage.raises.calls == 1, "the raise was attempted, got \(stage.raises.calls)")
        }
    }

    /// A click whose CGEvent can't be built is refused and not counted — the delivery seam
    /// now reports failure instead of swallowing it (the mouseBuilder seam makes CGEvent
    /// creation fail, which never happens on its own).
    @Test func aClickThatCantBeBuiltIsRefusedNotCounted() async throws {
        var s = gameSettings()
        s.stopAfterClicks = true
        s.maxClicks = 2          // never reached — every click is refused
        s.stopAfterDuration = true
        s.maxDurationSeconds = 0.3
        try await withStage(with: s, windowList: targetWindow) { stage, clicker in
            TargetSnapshot.shared.frontmostBundleIDForTests = "com.apple.finder"
            let savedBuilder = EventSynthesizer.mouseBuilder
            EventSynthesizer.mouseBuilder = { _, _, _, _ in nil }
            defer { EventSynthesizer.mouseBuilder = savedBuilder }
            clicker.toggle(.hotkey)
            try await runToIdle(clicker)

            #expect(clicker.clickCount == 0,
                    "a click whose event couldn't be built is not delivered, so not counted, got \(clicker.clickCount)")
            #expect(clicker.runWarning?.contains("couldn't be built") == true,
                    "the banner must say why: \(clicker.runWarning ?? "nil")")
            #expect(stage.hid.events.isEmpty, "nothing reached the HID tap")
        }
    }

    /// The default raise must run INLINE when its caller is already on the main thread: the
    /// Test Click calls it there and then sleeps 250 ms to let the raise land — an
    /// async-only default (the shipped blocker: three reviewers) leaves the queued activate
    /// behind the sleeping main thread, so the click posted while the game was still
    /// backgrounded, inside its measured discard window, and the reply still said "sent".
    @Test func theDefaultRaiseRunsInlineWhenTheCallerIsAlreadyOnMain() {
        let savedActivator = BackgroundPoster.appActivator
        let savedRunner = BackgroundPoster.mainThreadRunner
        let box = InlineBox()
        BackgroundPoster.mainThreadRunner = box.runner
        defer {
            BackgroundPoster.mainThreadRunner = savedRunner
            BackgroundPoster.appActivator = savedActivator
        }
        // A bundle id that isn't running, so even a body that DID run raises nothing. The
        // assertion is about WHERE the raise runs, not whether the app exists.
        BackgroundPoster.appActivator("com.example.not-running")
        #expect(box.inline == [true],
                "the raise must run inline on main (recorded: \(box.inline)) — a queued hop lands behind its caller's own sleep")
    }

    /// The shipped blocker, EXACTLY: the Test Click calls the raise on main, then sleeps
    /// 250 ms for the game's input gate; if the DEFAULT runner queues the body onto the main
    /// queue instead of running it inline, the activate lands behind its caller's own sleep —
    /// the click posts while the game is still backgrounded (inside its measured discard
    /// window) and the reply still says "sent". The test above pins that the activator
    /// ROUTES through `mainThreadRunner` (its recorder fires inline); THIS one pins the
    /// runner's own default body, which the recorder swap never executes.
    @Test func theDefaultMainThreadRunnerExecutesTheBodyInlineOnMain() {
        let savedRunner = BackgroundPoster.mainThreadRunner
        let savedActivator = BackgroundPoster.appActivator
        let box = InlineBox()
        defer {
            BackgroundPoster.mainThreadRunner = savedRunner
            BackgroundPoster.appActivator = savedActivator
        }
        // Both defaults stay live: the runner's default body is the thing under test. The
        // probe only records — no app is ever looked up, nothing is raised.
        BackgroundPoster.mainThreadRunner(box.probe)
        #expect(box.inline == [true],
                "the default runner must execute the body inline on main (recorded \(box.inline)) — a queued hop lands behind its caller's sleep")
    }

    // MARK: The private-symbol requirement is a PID-route concern

    /// An OS without CGEventSetWindowLocation blocks background window-aimed posts, not
    /// real-input clicks: with the game route ON the run must arm, with it OFF it must not.
    @Test func aMissingWindowTargetingSymbolBlocksThePidRouteButNotTheGameRoute() {
        let clicker = AppModel.shared.autoClicker
        let savedSettings = clicker.settings
        let savedProblem = BackgroundPoster.windowTargetingProblem
        // Force launch-validation's failure state deterministically.
        BackgroundPoster.windowTargetingProblem = "test: CGEventSetWindowLocation missing"
        defer {
            BackgroundPoster.windowTargetingProblem = savedProblem
            clicker.settings = savedSettings
        }

        var s = AutoClickerSettings()
        s.target = .directApp
        s.directAppBundleID = "com.apple.finder"
        s.directAppGameRoute = true
        clicker.settings = s
        #expect(clicker.directAppProblem == nil,
                "the game route posts plain HID events — no private symbol required")

        s.directAppGameRoute = false
        clicker.settings = s
        #expect(clicker.directAppProblem != nil,
                "the PID route must keep refusing to post mis-aimed events on this OS")
    }
}