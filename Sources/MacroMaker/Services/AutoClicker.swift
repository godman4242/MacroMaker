import AppKit
import CoreGraphics
import Foundation

@MainActor @Observable
final class AutoClicker {
    /// Internal so tests can save/restore the persisted blob around run-lifecycle tests.
    static let storageKey = "autoClicker"

    var settings = Persistence.load(AutoClickerSettings.self, key: AutoClicker.storageKey) ?? AutoClickerSettings() {
        didSet {
            Persistence.save(settings, key: Self.storageKey)
            // Hold-to-click needs the toggle hotkey's key-up event; make sure it's wired.
            configureHoldRelease()
        }
    }

    let session = RunSession()
    private(set) var clickCount = 0
    /// A one-line note about the live run (target-window loss, pause-monitor failure); nil = fine.
    private(set) var runWarning: String?

    /// A cursor-capture countdown: pick one point (fixed mode) or two corners (region mode).
    enum PickMode { case point, regionCorner1, regionCorner2, directAppPoint }
    private(set) var pickCountdown: Int?
    private(set) var activePick: PickMode?

    /// The live plan of the current run, re-created on resume after a pause.
    @ObservationIgnored private var currentPlan: Plan?
    /// Clicks already done across pause/resume of the current run.
    @ObservationIgnored private var clicksDone = 0
    /// Last time the user's own input was seen, for auto-resume.
    @ObservationIgnored private var lastRealInputAt = Date.distantPast
    @ObservationIgnored private var resumeTimer: Timer?

    /// Why direct-app targeting can't post reliably right now, if it can't.
    var directAppProblem: String? {
        guard settings.target == .directApp else { return nil }
        // The game route posts plain HID events, not window-aimed ones — the private
        // CGEventSetWindowLocation symbol is a requirement of the default PID route only.
        if !settings.directAppGameRoute {
            guard BackgroundPoster.targetingSupported else {
                // Launch validation says exactly what failed (missing symbol / failed round-trip).
                return BackgroundPoster.windowTargetingProblem
                    ?? "This macOS build doesn't support background clicks: the CGEventSetWindowLocation call is missing."
            }
        }
        guard !settings.directAppBundleID.isEmpty else { return "Pick an app to click in." }
        guard BackgroundPoster.processID(forBundleID: settings.directAppBundleID) != nil else {
            return "The target app isn't running. Open it, then start clicking."
        }
        return nil
    }

    @ObservationIgnored private let permissions: PermissionService
    @ObservationIgnored private weak var hotkeys: HotkeyService?
    @ObservationIgnored private var pickTask: Task<Void, Never>?
    /// The current run's id; a stop retires it so late worker reports land nowhere.
    @ObservationIgnored private(set) var runID = 0
    @ObservationIgnored private var holdReleaseHooked = false

    init(permissions: PermissionService, hotkeys: HotkeyService) {
        self.permissions = permissions
        self.hotkeys = hotkeys
        // Every stop of an active session ends the run the same way: "Stop Everything",
        // hold-release, profile apply and shutdown all stop the session directly, and they
        // used to skip the teardown below — leaking the input monitor and resume timer.
        session.onStop = { [weak self] in self?.tearDownRun() }
        configureHoldRelease()
    }

    /// An immutable snapshot of the settings, handed to the worker thread.
    private struct Plan: Sendable {
        let button: MouseButton
        let target: AutoClickerSettings.Target
        let fixedPoint: CGPoint
        let region: CGRect
        let clickCountPerEvent: Int
        let burstSize: Int
        let interval: TimeInterval
        let jitterSeconds: TimeInterval
        let positionJitterPx: Double
        let maxClicks: Int?
        let maxDuration: TimeInterval?
        let stopOnFrontmostChange: Bool
        /// Sampled at `begin` — after the countdown — never at toggle, when the user may still
        /// be holding the shortcut (and thus frontmost in Macro Maker's own windows).
        let initialFrontmost: String?
        let restoreCursor: Bool
        let humanizer: HumanizerSettings
        /// Direct-app delivery: the target app's bundle id and a *screen-space* point on its window.
        let directAppBundleID: String
        let directScreenPoint: CGPoint
        /// Direct-app route for game-class targets: real HID clicks that move the cursor,
        /// not PID-posted ones (games read a click's position from the system cursor and
        /// drop input while not frontmost — both measured). Same-named settings flag.
        let directAppGameRoute: Bool

        init(_ s: AutoClickerSettings, initialFrontmost: String?) {
            button = s.button
            target = s.target
            fixedPoint = CGPoint(x: s.x, y: s.y)
            region = s.region.cgRect
            clickCountPerEvent = max(1, s.clickCountPerEvent.rawValue)
            burstSize = max(1, min(10, s.burstSize))
            interval = max(TickSchedule.minimumDelay, s.intervalMs / 1000)
            jitterSeconds = s.randomizeInterval ? max(0, s.randomOffsetMs) / 1000 : 0
            positionJitterPx = s.jitterEnabled ? max(0, s.jitterPx) : 0
            let limits = AutoClicker.stopLimits(s)
            maxClicks = limits.clicks
            maxDuration = limits.duration
            stopOnFrontmostChange = s.stopOnFrontmostChange
            self.initialFrontmost = s.stopOnFrontmostChange ? initialFrontmost : nil
            restoreCursor = s.restoreCursor
            humanizer = s.humanizer
            directAppBundleID = s.directAppBundleID
            directScreenPoint = CGPoint(x: s.directAppX, y: s.directAppY)
            directAppGameRoute = s.directAppGameRoute
        }
    }

    /// The run's count/duration bounds (F-11 "repeat until the stop shortcut"). Until-hotkey
    /// is a stop CONDITION like frontmost-change is, not a fourth bound: the run's end is
    /// the stop-run hotkey, so the numeric limits come off entirely — a 5-click bound on an
    /// until-hotkey run would silently end it long before the keypress ever mattered.
    nonisolated static func stopLimits(_ s: AutoClickerSettings) -> (clicks: Int?, duration: TimeInterval?) {
        if s.stopOnHotkey { return (nil, nil) }
        return (s.stopAfterClicks ? max(1, s.maxClicks) : nil,
                s.stopAfterDuration ? max(0.1, s.maxDurationSeconds) : nil)
    }

    /// The clock-time start feature is a menu-level concept, not a per-feature one (see AppModel.schedule).

    func toggle(_ trigger: StartTrigger) {
        if session.phase.isActive {
            session.stop()
            return
        }
        guard directAppProblem == nil else {
            NSSound.beep()
            return
        }
        guard permissions.ensureAccessibility() else { return }
        cancelPick()
        clicksDone = 0
        elapsedBefore = 0
        workerStartedAt = nil
        runWarning = nil
        // The frontmost-app baseline is sampled in begin(), after the countdown — at toggle()
        // time the user's shortcut hand is still on the keyboard, which can leave Macro Maker
        // frontmost and immediately trip the stop rule.
        let plan = Plan(settings, initialFrontmost: nil)
        session.start(withCountdown: trigger == .button,
                      countdownExtra: Int(max(0, settings.delayedStartSeconds).rounded())) { [weak self] token in
            guard let begin = self?.begin(plan, token: token) else { return nil }
            self?.startPauseWatching()
            return begin
        }
    }

    /// Everything a stopped run must leave behind: no pause watcher (input monitor plus
    /// its 1 Hz resume timer), no stale run state — and a retired run id, so a report
    /// queued before the stop (the worker finishing naturally in the same instant)
    /// resurrects nothing; see `handleWorkerReport`. Runs on every stop path — the in-app
    /// Stop and the external ones ("Stop Everything", hold-release, profile apply,
    /// shutdown) alike, via the session's stop hook.
    private func tearDownRun() {
        runID += 1
        tearDownPauseWatching()
        clicksDone = 0
        elapsedBefore = 0
        workerStartedAt = nil
        runWarning = nil
    }

    private func begin(_ plan0: Plan, token: Int) -> (() -> Void)? {
        var plan = plan0
        if plan.stopOnFrontmostChange {
            // Game route: pin the baseline to the TARGET, not the real frontmost — the run
            // itself raises the game at start (below, in clickLoop), and that raise would
            // read as a frontmost change and stop the run on its first check. Any OTHER app
            // coming forward still stops it. Default modes keep sampling the real frontmost.
            // The pin is gated on the TARGET too: the toggle lives in the direct-app section,
            // so switching to fixed-point hides it — a stale ON flag there must not baseline
            // a fixed-point run on a game that never ran.
            let gameRoute = plan.target == .directApp && plan.directAppGameRoute
            let baseline = gameRoute ? plan.directAppBundleID
                                     : TargetSnapshot.shared.frontmostBundleID
            plan = Plan(settings, initialFrontmost: baseline)
        }
        /// The run's own copy of the plan (initialFrontmost sampled at begin) lives here so
        /// resume() can rebuild the worker from it.
        currentPlan = plan
        runID += 1
        let run = runID
        let skip = clicksDone
        // Time already spent before a pause, so a time-limited run cannot restart its budget on
        // every resume. This mirrors what `skip`/`clicksDone` already does for the click count.
        let elapsed = elapsedBefore
        workerStartedAt = Date()
        // Window/app lookups that would otherwise cost a worker→main sync per click.
        let snapshot = TargetSnapshot.shared
        if plan.target == .directApp { snapshot.prewarm(bundleID: plan.directAppBundleID) }
        let runPlan = plan  // immutable copy for the @Sendable worker closure
        let worker = WorkerThread.start(name: "AutoClicker") { worker in
            Self.clickLoop(runPlan, skipping: skip, elapsed: elapsed, worker: worker, snapshot: snapshot) { count, finished, warning in
                performOnMain { [weak self] in
                    self?.handleWorkerReport(run: run, token: token, count: count, finished: finished, warning: warning)
                }
            }
        }
        return worker.stopClosure(named: "Auto Clicker") { [weak self] in
            guard let self, self.session.phase == .idle else { return }
            self.runWarning = "Stop didn't finish within its 1-second budget — the run may still be completing in the background."
        }
    }

    /// Seconds a time-limited run has already spent across earlier (paused) workers.
    @ObservationIgnored private var elapsedBefore: TimeInterval = 0
    @ObservationIgnored private var workerStartedAt: Date?

    /// The worker's report, drained on the main actor in FIFO order. `run` is the id the
    /// report was issued under: a stop retires the id, so a report queued just before a
    /// manual Stop — the worker finishing naturally in the same instant — resurrects
    /// neither the warning banner nor the counters for a run the user already dismissed.
    func handleWorkerReport(run: Int, token: Int, count: Int, finished: Bool, warning: String?) {
        guard runID == run else { return }
        clicksDone = count
        clickCount = count
        // A pause cancels the worker, and a cancelled worker reports exactly like a
        // finished one. `session.finish` already ignores it (it requires .running),
        // but the teardown did not — so every pause invalidated the 1s resume timer
        // and stopped the input monitor, and `resumeIfIdle` is driven ONLY by that
        // timer, which is only re-armed from inside a start. Auto-resume was
        // therefore structurally unreachable, not merely racy.
        if finished, !session.isPaused {
            runWarning = warning
            tearDownPauseWatching()
            session.finish(token)
        } else if let warning {
            runWarning = warning
        }
    }

    // MARK: Pause on real input

    /// Pausing a run cancels the worker (via RunSession.pause) but keeps the count; resuming
    /// restarts the worker without a countdown, skipping the clicks already done.
    private func pauseIfNeeded() {
        guard settings.pauseOnRealInput else { return }
        // Stamp the input BEFORE the phase check. Behind the `.running` guard the timestamp
        // froze at the first keystroke, so auto-resume would count its idle seconds from the
        // moment the user STARTED typing and restart the run mid-sentence.
        lastRealInputAt = Date()
        guard session.phase == .running else { return }
        // Bank the time this worker ran for; `begin` subtracts it from the limit on resume.
        if let workerStartedAt { elapsedBefore += Date().timeIntervalSince(workerStartedAt) }
        workerStartedAt = nil
        session.pause()
    }

    /// Called when the user chooses Resume now, or by the idle timer.
    func resume() {
        guard session.isPaused else { return }
        guard let plan = currentPlan else { session.stop(); return }
        clickCount = clicksDone
        session.start(withCountdown: false) { [weak self] token in
            guard let begin = self?.begin(plan, token: token) else { return nil }
            self?.startPauseWatching()
            return begin
        }
    }

    private func resumeIfIdle() {
        guard RealInputRules.idleEnough(lastInputAt: lastRealInputAt, afterSeconds: settings.autoResumeSeconds, now: Date()) else { return }
        resume()
    }

    private func startPauseWatching() {
        guard settings.pauseOnRealInput else { return }
        if !RealInputMonitor.shared.start(onRealInput: { [weak self] in self?.pauseIfNeeded() }) {
            // The monitor couldn't install even on the local fallback: say so instead of
            // letting the user believe their input will pause the run.
            runWarning = RealInputMonitor.shared.lastFailure
        }
        // Idle check: once per second asks whether auto-resume's deadline passed.
        resumeTimer?.invalidate()
        resumeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.settings.autoResumeSeconds > 0 else { return }
                self.resumeIfIdle()
            }
        }
    }

    private func tearDownPauseWatching() {
        resumeTimer?.invalidate()
        resumeTimer = nil
        RealInputMonitor.shared.stop()
    }

    /// Longest a single run may be scheduled for — a ceiling that keeps the conversion in range.
    nonisolated static let maximumRunSeconds: TimeInterval = 86_400

    /// When a time-limited run must stop, counted in the worker's uptime clock.
    ///
    /// `alreadyElapsed` is the time spent by earlier workers of the same run. Without it, each
    /// resume started a brand-new budget — "stop after 60 s" ran 60 s *per resume*, unbounded.
    /// The clamp also keeps `UInt64(_:)` out of its trapping range (measured: exit 133 on a
    /// non-finite or negative value).
    nonisolated static func runDeadlineNanos(start: UInt64, maxDuration: TimeInterval?,
                                             alreadyElapsed: TimeInterval) -> UInt64 {
        guard let maxDuration else { return .max }
        let remaining = maxDuration - alreadyElapsed
        guard !remaining.isNaN else { return start }
        return start + UInt64(min(max(remaining, 0), maximumRunSeconds) * 1_000_000_000)
    }

    nonisolated private static func clickLoop(_ plan: Plan, skipping skip: Int,
                                              elapsed alreadyElapsed: TimeInterval, worker: WorkerThread,
                                              snapshot: TargetSnapshot,
                                              report: @Sendable (_ count: Int, _ finished: Bool, _ warning: String?) -> Void) {
        let start = DispatchTime.now().uptimeNanoseconds
        let end = runDeadlineNanos(start: start, maxDuration: plan.maxDuration, alreadyElapsed: alreadyElapsed)
        var deadline = start
        var count = skip
        var lastReport: UInt64 = 0
        var humanizer = Humanizer(plan.humanizer)
        // Per-run caches (perf H1/H3/H4): window listing + app lookup ride on the snapshot and a
        // TTL'd resolver; one event source serves every posted event of the run.
        let source = EventSynthesizer.EventSource()
        var direct: DirectRun?
        if plan.target == .directApp {
            direct = DirectRun(bundleID: plan.directAppBundleID, snapshot: snapshot, interval: plan.interval)
            // The game route's one raise per worker: games discard posted input while not
            // frontmost (measured), and the run's clicks alone won't bring the game forward
            // (measured: a synthetic click does NOT activate a background window).
            if plan.directAppGameRoute { raiseTargetIfNeeded(plan, snapshot: snapshot, worker: worker, end: end) }
        }
        var lastWarning: String?

        while !worker.isCancelled, DispatchTime.now().uptimeNanoseconds < end {
            burst: for _ in 0..<plan.burstSize {
                if var directRun = direct {
                    switch directRun.verifyTarget() {
                    case .dead:
                        direct = directRun
                        report(count, true, "The target app quit or was replaced mid-run — the run stopped rather than click the wrong process.")
                        return
                    case .alive(let pid):
                        if let undelivered = directClickOnce(plan, pid: pid, snapshot: snapshot,
                                                            resolver: directRun.resolver,
                                                            activator: directRun.activator,
                                                            gate: directRun.gate, source: source) {
                            // Undelivered click: never counted — the counter must mean "clicks
                            // that reached the target", or stopAfterClicks lies. The warning
                            // string says WHY (no window / undeliverable event) so the banner
                            // tells the user what to do instead of counting silence.
                            lastWarning = undelivered
                        } else {
                            count += 1
                        }
                        direct = directRun
                        guard !worker.isCancelled else { break burst }
                    }
                } else {
                    clickOnce(plan, source: source)
                    count += 1
                }
                if let maxClicks = plan.maxClicks, count >= maxClicks { break burst }
            }
            if plan.stopOnFrontmostChange,
               FrontmostStopRule.changed(from: plan.initialFrontmost, to: snapshot.frontmostBundleID) { break }
            if let maxClicks = plan.maxClicks, count >= maxClicks { break }

            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastReport > 50_000_000 {
                report(count, false, lastWarning)
                lastReport = now
            }
            var delay = TickSchedule.delay(interval: plan.interval, jitter: plan.jitterSeconds,
                                           random: .random(in: -1...1))
            delay = humanizer.nextDelay(interval: delay)
            deadline = TickSchedule.nextDeadline(previous: deadline,
                                                 delay: UInt64(delay * 1_000_000_000), now: now)
            guard worker.sleep(untilUptime: min(deadline, end)) else { break }
        }
        report(count, true, lastWarning)
    }

    /// The direct-app run's per-run identity check: the pid captured when the run began must
    /// still belong to the target bundle id (pid-reuse guard) — the snapshot holds pid→bundle,
    /// so a process replaced by another app's never matches the plan's target.
    /// A struct (not a class): the loop is the only caller and its `var` is exclusive to the
    /// worker thread, so Sendable-by-exclusivity applies.
    nonisolated private struct DirectRun: Sendable {
        let bundleID: String
        let resolver = BackgroundPoster.WindowResolver()
        /// Armed once per (pid, window): Chromium-class targets ignore background clicks until
        /// their app is input-active. See BackgroundPoster.activateWithoutRaise.
        let activator = BackgroundPoster.Activator()
        /// The game route's per-click visibility gate: a real click lands on whatever is
        /// topmost at the point, so a covered or off-screen point is refused instead of
        /// clicked blind. Its listing TTL follows the run's cadence (one refresh per tick),
        /// because a stale listing on a REAL-click route is up to a TTL of misdirected clicks
        /// after something pops over the spot. Unused by the default PID route.
        let gate: BackgroundPoster.VisibilityGate
        private var state = State.unchecked
        private enum State { case unchecked, gone }
        private let snapshot: TargetSnapshot

        init(bundleID: String, snapshot: TargetSnapshot, interval: TimeInterval) {
            self.bundleID = bundleID
            self.snapshot = snapshot
            self.gate = BackgroundPoster.VisibilityGate(interval: interval)
        }

        enum Check { case alive(pid: pid_t), dead }

        /// Polled per burst: the app must still be running *as the same process*.
        mutating func verifyTarget() -> Check {
            if case .gone = state { return .dead }
            let target = snapshot.targetState(forBundleID: bundleID)
            // The snapshot's resolve drops entries whose pid no longer owns the bundle id, so
            // this pid always matches — a reused pid resolves to the new owner instead.
            guard let pid = target.pid else {
                state = .gone
                return .dead
            }
            return .alive(pid: pid)
        }
    }

    /// One click event: resolves the point for this event, then down/up.
    nonisolated private static func clickOnce(_ plan: Plan, source: EventSynthesizer.EventSource) {
        let base: CGPoint? = switch plan.target {
        case .cursor: nil
        case .fixedPoint: plan.fixedPoint
        case .region: ClickGeometry.randomPoint(in: plan.region,
                                                u1: .random(in: 0...1), u2: .random(in: 0...1))
        case .directApp: nil  // never reached: direct clicks are handled in the loop
        }
        let point = base ?? EventSynthesizer.cursorLocation
        // One source of randomness per point: region mode picked its random point already, so
        // positional jitter applies only to fixed/cursor targeting.
        let jiggled = plan.target == .region || plan.positionJitterPx == 0 ? point
            : ClickGeometry.jitter(point, amount: plan.positionJitterPx,
                                   u1: .random(in: 0...1), u2: .random(in: 0...1))

        let before = plan.restoreCursor ? EventSynthesizer.cursorLocation : nil
        // `at: nil` re-reads the raw cursor position, which threw the jitter away for the
        // DEFAULT target — "Vary the point by up to ± N px" silently did nothing on it. Keep the
        // nil fast path only when there is no jitter to apply.
        EventSynthesizer.click(plan.button, at: plan.target == .cursor && plan.positionJitterPx == 0 ? nil : jiggled,
                               holdFor: TickSchedule.pressDuration(interval: plan.interval),
                               clickCount: plan.clickCountPerEvent, source: source)
        // The real cursor follows HID clicks; optionally put it back where it was.
        if let before, EventSynthesizer.cursorLocation != before {
            EventSynthesizer.postMouse(.mouseMoved, button: .left, at: before, source: source)
        }
    }

    /// Direct-app click. Two routes share this entry point: the default PID route (no cursor
    /// movement, no app raising — posted into the process) and the game route (`gameRouteClick`
    /// below). Returns nil when the click was delivered; otherwise a one-line warning naming
    /// why, and nothing is counted when this returns a warning.
    nonisolated private static func directClickOnce(_ plan: Plan, pid: pid_t,
                                                    snapshot: TargetSnapshot,
                                                    resolver: BackgroundPoster.WindowResolver,
                                                    activator: BackgroundPoster.Activator,
                                                    gate: BackgroundPoster.VisibilityGate,
                                                    source: EventSynthesizer.EventSource) -> String? {
        if plan.directAppGameRoute {
            return gameRouteClick(plan, pid: pid, snapshot: snapshot, resolver: resolver,
                                  gate: gate, source: source)
        }
        // Same single-randomness rule: this point is fixed, positional jitter applies.
        let picked = plan.positionJitterPx == 0 ? plan.directScreenPoint
            : ClickGeometry.jitter(plan.directScreenPoint, amount: plan.positionJitterPx,
                                   u1: .random(in: 0...1), u2: .random(in: 0...1))
        // F6/H6: prefer the app's window that CONTAINS the point over its front-most one —
        // for multi-window apps the captured spot lives in a specific window.
        guard let window = resolver.window(ofPID: pid, containing: picked) else {
            return "Target window not found — bring it on-screen at least once; undelivered clicks aren't counted."
        }
        // Chromium-class targets drop every background click until their app is input-active.
        // The effect persists for the run, so this is once per (pid, window), not per click —
        // re-running it per click would thrash window-server focus at click rates.
        activator.activateIfNeeded(pid: pid, windowID: window.id)
        // H5: jitter can push the point outside the window it must land in — clamp it back.
        let screenPoint = ClickGeometry.clamp(picked, to: window.bounds)
        guard BackgroundPoster.click(plan.button, screenPoint: screenPoint,
                                     holdFor: TickSchedule.pressDuration(interval: plan.interval),
                                     clickCount: plan.clickCountPerEvent,
                                     window: window, pid: pid) else {
            return "Clicks couldn't be delivered to the target app (its event or window aim failed); undelivered clicks aren't counted."
        }
        return nil
    }

    /// The game route: one REAL click at the point, posted at the HID tap like the foreground
    /// modes. Games read a click's position from the system cursor, not from the posted
    /// event's fields (measured: the PID route's clicks land at the LIVE cursor in Roblox),
    /// and they discard input while not frontmost (measured) — so this branch moves the real
    /// cursor to the point instead of posting into the process. No primer pair and no
    /// window-target fields (those serve the PID recipe — and RobloxAuto shows an
    /// off-screen primer pair registering as a click of its own): the down's location IS the
    /// cursor move, because the WindowServer processes a HID-tap event's location into cursor
    /// state (measured: cursor 470,873 → exactly the click point, no leading move).
    nonisolated private static func gameRouteClick(_ plan: Plan, pid: pid_t,
                                                   snapshot: TargetSnapshot,
                                                   resolver: BackgroundPoster.WindowResolver,
                                                   gate: BackgroundPoster.VisibilityGate,
                                                   source: EventSynthesizer.EventSource) -> String? {
        // A real click posted while the game isn't frontmost is discarded (measured) while
        // it still moves the cursor — refuse like the gate does, or stopAfterClicks counts
        // clicks that never reached the game. Checked FIRST (cheapest, and every click that
        // passes it re-reads the snapshot, so a switch back to the game self-heals within
        // one tick — no re-raise: stealing the front back from the user would be hostile).
        guard snapshot.targetState(forBundleID: plan.directAppBundleID).isActive else {
            return "The game isn't frontmost right now — it ignores clicks until you switch back to it; undelivered clicks aren't counted."
        }
        // Resolve by the CAPTURED point, then jitter, then clamp: jittering first can step
        // outside the window the user anchored to, and unclamped jitter on a REAL-click
        // route can click a neighbouring app's window.
        guard let window = resolver.window(ofPID: pid, containing: plan.directScreenPoint) else {
            return "Target window not found — bring it on-screen at least once; undelivered clicks aren't counted."
        }
        let picked = plan.positionJitterPx == 0 ? plan.directScreenPoint
            : ClickGeometry.jitter(plan.directScreenPoint, amount: plan.positionJitterPx,
                                   u1: .random(in: 0...1), u2: .random(in: 0...1))
        let screenPoint = ClickGeometry.clamp(picked, to: window.bounds)
        // A real click goes to whatever is topmost at the point — refuse to click a spot the
        // user can't see the target owning (occluded, another Space, off-screen).
        guard gate.isVisible(pid: pid, at: screenPoint) else {
            return "The captured spot isn't visible on the game right now — something covers it, or its window is on another screen; undelivered clicks aren't counted."
        }
        let before = plan.restoreCursor ? EventSynthesizer.cursorLocation : nil
        let delivered = EventSynthesizer.click(plan.button, at: screenPoint,
                                               holdFor: TickSchedule.gameRouteHold(interval: plan.interval),
                                               clickCount: plan.clickCountPerEvent, source: source)
        // Same restore contract as the foreground modes (clickOnce): a real click moves the
        // cursor, so put it back when the user asked for that — also when the up half failed
        // (the down half already moved it).
        if let before, EventSynthesizer.cursorLocation != before {
            EventSynthesizer.postMouse(.mouseMoved, button: .left, at: before, source: source)
        }
        // The restore runs before this guard on purpose; a half-built pair moved the cursor,
        // so it gets undone either way.
        guard delivered else {
            return "The click's event couldn't be built — nothing was delivered; undelivered clicks aren't counted."
        }
        return nil
    }

    /// The game route's one raise per worker: skip it when the target is already frontmost,
    /// otherwise raise for real and settle before the first click. Runs once per worker
    /// (clickLoop setup), so begin AND resume both pass through it — a run resumed after a
    /// pause re-raises if the game lost the front in between.
    ///
    /// The settle is clamped to the run's `end` like every other sleep, so a duration-limited
    /// run never spends past its budget settling. The isCancelled pre-check skips a raise
    /// that could no longer serve a click; a Stop racing the call can still enqueue one raise
    /// before cancellation lands (the main-queue hop isn't cancellable) — bounded, harmless
    /// and rarer than the pre-check's case, which is why it's a residual, not a guard.
    nonisolated private static func raiseTargetIfNeeded(_ plan: Plan, snapshot: TargetSnapshot,
                                                        worker: WorkerThread, end: UInt64) {
        guard !worker.isCancelled else { return }
        guard !snapshot.targetState(forBundleID: plan.directAppBundleID).isActive else { return }
        BackgroundPoster.appActivator(plan.directAppBundleID)
        // Settle before the first click: the target's input gate opens after the raise lands,
        // not at the call (the focus-blip measurements needed the same 250 ms).
        _ = worker.sleep(untilUptime: min(end, DispatchTime.now().uptimeNanoseconds + 250_000_000))
    }

    // MARK: Direct-app helpers (main-actor queries)

    /// One line of truth about where direct-app clicks will land, or why they can't.
    var directAppStatus: String {
        let bundleID = settings.directAppBundleID
        guard !bundleID.isEmpty else { return "No app chosen yet." }
        guard let pid = BackgroundPoster.processID(forBundleID: bundleID) else {
            return "The target app isn't running."
        }
        let point = CGPoint(x: settings.directAppX, y: settings.directAppY)
        guard let window = BackgroundPoster.resolveWindowLive(ofPID: pid, containing: point) else {
            return "Target window not found — bring it on-screen at least once."
        }
        let local = BackgroundPoster.windowPoint(fromScreenPoint: point, window: window)
        func shown(_ v: CGFloat) -> Int { v.isFinite ? Int(min(max(v, -100_000), 100_000)) : 0 }
        if settings.directAppGameRoute {
            // The game route clicks for REAL at the point, so the truth that matters is
            // whether the spot is VISIBLY the game's — not which window it would be aimed at.
            let visible = BackgroundPoster.topmostOwner(at: point) == pid
            return "Real-input route: the cursor jumps to (\(shown(local.x)), \(shown(local.y))) of this window and the game comes to the front."
                + (visible ? "" : " The captured spot isn't visible on the game right now: something covers it, or its window is on another screen.")
        }
        // H4: say it when the captured spot lies outside every window of the app — the click
        // then falls back to the front-most window and lands wherever that one is.
        let whereItLands = window.bounds.contains(point)
            ? "inside it"
            : "outside it — clicks fall back to the app's front-most window"
        return "Window \(shown(window.bounds.width))×\(shown(window.bounds.height)) — captured spot is (\(shown(local.x)), \(shown(local.y))) \(whereItLands)."
    }

    /// The pick-time half of H4: a direct-app point captured outside every window of the chosen
    /// app is a user mistake that used to surface only as silently undelivered clicks. Nil =
    /// fine (no app chosen / app not running yet — the status line covers those) or the point
    /// lies inside one of the app's windows.
    func directAppPickWarning(for point: CGPoint) -> String? {
        guard !settings.directAppBundleID.isEmpty,
              let pid = BackgroundPoster.processID(forBundleID: settings.directAppBundleID) else { return nil }
        let windows = BackgroundPoster.resolveWindowsLive(ofPID: pid)
        guard !windows.isEmpty else { return nil }  // nothing to check against yet
        guard windows.contains(where: { $0.bounds.contains(point) }) else {
            return "That spot isn't inside any window of the chosen app — background clicks aim at its windows; pick again inside one."
        }
        return nil
    }

    /// Posts one click at the chosen target without starting a run. "Sent" only when the event
    /// really went out fully aimed; every skip says why.
    func testClick() -> String {
        if settings.directAppGameRoute { return gameRouteTestClick() }
        guard BackgroundPoster.targetingSupported else { return directAppProblem ?? "Background clicks aren't supported here." }
        guard permissions.ensureAccessibility() else {
            return "Test click failed — Accessibility permission is off, so the click can't be posted."
        }
        guard let pid = BackgroundPoster.processID(forBundleID: settings.directAppBundleID) else {
            return "Test click failed — the target app isn't running."
        }
        let base = CGPoint(x: settings.directAppX, y: settings.directAppY)
        guard let window = BackgroundPoster.resolveWindowLive(ofPID: pid, containing: base) else {
            return "Test click failed — target window not found. Bring it on-screen at least once."
        }
        let point = ClickGeometry.clamp(
            ClickGeometry.jitter(base, amount: settings.jitterEnabled ? settings.jitterPx : 0,
                                 u1: .random(in: 0...1), u2: .random(in: 0...1)),
            to: window.bounds)
        guard BackgroundPoster.click(settings.button, screenPoint: point, holdFor: 0.05,
                                     clickCount: max(1, settings.clickCountPerEvent.rawValue),
                                     window: window, pid: pid) else {
            return "Test click failed — the click's event couldn't be built or aimed at the window."
        }
        // "Sent" is ALL this can honestly claim: delivery is one-way, so nothing here can see
        // whether the target acted on the click. Saying only "Test click sent." read as "it
        // works" — and for a game it never did, which is hours of hunting a bug in the wrong
        // place. The message now names the one check the app can't make, and the one class of
        // target that silently eats background clicks (measured: Roblox, unchanged pixel for
        // pixel; the same click works the moment the game is frontmost).
        let name = BackgroundPoster.targetableApps()
            .first { $0.bundleID == settings.directAppBundleID }?.name ?? "the target app"
        return "Test click sent to \(name) — look at it now. If nothing happened there, it's a "
            + "game or a drawing-canvas app: those only accept clicks while they're in front."
    }

    /// The game route's Test Click: bring the game forward (for real — a synthetic click
    /// does NOT activate a background window, measured), then one REAL click at the captured
    /// point so the user can watch it land. The reply says exactly what happened, because
    /// "Test click sent" over a click the game silently ate is the bug this route exists to
    /// fix.
    ///
    /// This runs on main and deliberately blocks it for the ~250 ms settle: user-initiated,
    /// bounded, and the raise runs INLINE on main (`BackgroundPoster.mainThreadRunner`), so
    /// it lands inside the sleep. The alternative — probing from a background task while
    /// the user keeps typing — would let the user's own mouse wander into the click.
    private func gameRouteTestClick() -> String {
        guard permissions.ensureAccessibility() else {
            return "Test click failed — Accessibility permission is off, so the click can't be posted."
        }
        guard let pid = BackgroundPoster.processID(forBundleID: settings.directAppBundleID) else {
            return "Test click failed — the target app isn't running."
        }
        let base = CGPoint(x: settings.directAppX, y: settings.directAppY)
        guard let window = BackgroundPoster.resolveWindowLive(ofPID: pid, containing: base) else {
            return "Test click failed — target window not found. Bring it on-screen at least once."
        }
        if !TargetSnapshot.shared.targetState(forBundleID: settings.directAppBundleID).isActive {
            BackgroundPoster.appActivator(settings.directAppBundleID)
            // Same settle the run uses: the target's input gate opens after the raise lands —
            // and the raise runs inline (see mainThreadRunner), so it CAN land inside this sleep.
            Thread.sleep(forTimeInterval: 0.25)
            // The honesty check the shipped version skipped: a game that never came forward
            // is still discarding input (measured), so a real click posted now is eaten
            // while looking delivered. Refuse and say so instead of claiming "sent".
            guard TargetSnapshot.shared.targetState(forBundleID: settings.directAppBundleID).isActive else {
                return "Test click failed — the game didn't come to the front when asked (its window may "
                    + "refuse activation). Click the game once to bring it forward, then try again."
            }
        }
        let point = ClickGeometry.clamp(
            ClickGeometry.jitter(base, amount: settings.jitterEnabled ? settings.jitterPx : 0,
                                 u1: .random(in: 0...1), u2: .random(in: 0...1)),
            to: window.bounds)
        guard BackgroundPoster.topmostOwner(at: point) == pid else {
            return "Test click failed — the captured spot isn't visible on the game right now: "
                + "something covers it, or its window is on another screen. Make the spot visible, then try again."
        }
        guard EventSynthesizer.click(settings.button, at: point, holdFor: 0.05,
                                     clickCount: max(1, settings.clickCountPerEvent.rawValue)) else {
            return "Test click failed — the click's event couldn't be built, so nothing was posted."
        }
        let name = BackgroundPoster.targetableApps()
            .first { $0.bundleID == settings.directAppBundleID }?.name ?? "the target app"
        return "Test click sent to \(name) — look at it now. That was a real click: your cursor "
            + "moved to the point, and the game should now be in front."
    }

    /// Sampled at tick boundaries so the app-switch check costs one lock-protected read per tick —
    /// never a main-queue hop (that's the deadlock this snapshot replaces).
    nonisolated static func frontmostBundleID() -> String? {
        TargetSnapshot.shared.frontmostBundleID
    }

    // MARK: Hold-to-click

    private func configureHoldRelease() {
        if settings.holdToClick {
            guard !holdReleaseHooked else { return }
            holdReleaseHooked = true
            hotkeys?.onRelease = { [weak self] action, combo in
                guard let self, action == .toggleAutoClicker,
                      self.hotkeys?.combos[.toggleAutoClicker] == combo else { return }
                self.session.stop()
            }
        } else if holdReleaseHooked {
            hotkeys?.onRelease = nil
            holdReleaseHooked = false
        }
    }

    /// Reassigning the toggle shortcut mid-hold ends the hold run before it leaks: the worker is
    /// cancelled by session.stop() and the new combo can never release a run it didn't start.
    func hotkeyReassigned(for action: HotkeyAction) {
        guard action == .toggleAutoClicker, session.phase.isActive, settings.holdToClick else { return }
        session.stop()
    }

    // MARK: Point capture

    /// Counts down so the user can move the cursor to the target, then stores its position.
    func pickFixedPoint() {
        beginPick(.point)
    }

    /// Two-step corner capture for region mode.
    func pickRegionCorner(_ second: Bool) {
        beginPick(second ? .regionCorner2 : .regionCorner1)
    }

    /// Hover over the spot inside the target window; captured in screen coordinates and
    /// re-anchored to the window's live bounds on every click.
    func pickDirectAppPoint() {
        beginPick(.directAppPoint)
    }

    private func beginPick(_ mode: PickMode) {
        cancelPick()
        activePick = mode
        pickTask = Task { [weak self] in
            for remaining in stride(from: RunSession.countdownSeconds, to: 0, by: -1) {
                self?.pickCountdown = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.completePick(mode)
        }
    }

    private func completePick(_ mode: PickMode) {
        let location = EventSynthesizer.cursorLocation
        var updated = settings
        switch mode {
        case .point:
            updated.x = location.x.rounded()
            updated.y = location.y.rounded()
            updated.target = .fixedPoint
        case .regionCorner1:
            updated.region = ClickRegion(x: location.x.rounded(), y: location.y.rounded(),
                                         width: updated.region.width, height: updated.region.height)
        case .regionCorner2:
            let corner1 = CGPoint(x: updated.region.x, y: updated.region.y)
            updated.region = ClickRegion(corner1: corner1, corner2: location)
        case .directAppPoint:
            updated.directAppX = location.x.rounded()
            updated.directAppY = location.y.rounded()
            updated.target = .directApp
        }
        // H4's pick-time check: warn the moment a direct-app spot is captured outside every
        // window of the chosen app — the run itself still posts (occlusion/another Space is
        // legitimate), but the user learns immediately instead of from missing clicks.
        var pickWarning: String?
        if mode == .directAppPoint {
            pickWarning = directAppPickWarning(for: location)
        }
        settings = updated
        runWarning = pickWarning
        pickCountdown = nil
        activePick = nil
    }

    func cancelPick() {
        pickTask?.cancel()
        pickTask = nil
        pickCountdown = nil
        activePick = nil
    }
}
