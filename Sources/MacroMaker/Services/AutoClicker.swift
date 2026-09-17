import AppKit
import CoreGraphics
import Foundation

@MainActor @Observable
final class AutoClicker {
    private static let storageKey = "autoClicker"

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
        guard BackgroundPoster.targetingSupported else {
            return "This macOS build doesn't support background clicks: the CGEventSetWindowLocation call is missing."
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
    @ObservationIgnored private var runID = 0
    @ObservationIgnored private var holdReleaseHooked = false

    init(permissions: PermissionService, hotkeys: HotkeyService) {
        self.permissions = permissions
        self.hotkeys = hotkeys
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
            maxClicks = s.stopAfterClicks ? max(1, s.maxClicks) : nil
            maxDuration = s.stopAfterDuration ? max(0.1, s.maxDurationSeconds) : nil
            stopOnFrontmostChange = s.stopOnFrontmostChange
            self.initialFrontmost = s.stopOnFrontmostChange ? initialFrontmost : nil
            restoreCursor = s.restoreCursor
            humanizer = s.humanizer
            directAppBundleID = s.directAppBundleID
            directScreenPoint = CGPoint(x: s.directAppX, y: s.directAppY)
        }
    }

    /// The clock-time start feature is a menu-level concept, not a per-feature one (see AppModel.schedule).

    func toggle(_ trigger: StartTrigger) {
        if session.phase.isActive {
            endRun()
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

    /// Stops the run and tears down its watchers; the only "run over" path.
    private func endRun() {
        tearDownPauseWatching()
        session.stop()
        clicksDone = 0
        elapsedBefore = 0
        workerStartedAt = nil
        runWarning = nil
    }

    private func begin(_ plan0: Plan, token: Int) -> (() -> Void)? {
        var plan = plan0
        if plan.stopOnFrontmostChange {
            plan = Plan(settings, initialFrontmost: TargetSnapshot.shared.frontmostBundleID)
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
                    guard let self, self.runID == run else { return }
                    self.clicksDone = count
                    self.clickCount = count
                    // A pause cancels the worker, and a cancelled worker reports exactly like a
                    // finished one. `session.finish` already ignores it (it requires .running),
                    // but the teardown did not — so every pause invalidated the 1s resume timer
                    // and stopped the input monitor, and `resumeIfIdle` is driven ONLY by that
                    // timer, which is only re-armed from inside a start. Auto-resume was
                    // therefore structurally unreachable, not merely racy.
                    if finished, !self.session.isPaused {
                        self.runWarning = warning
                        self.tearDownPauseWatching()
                        self.session.finish(token)
                    } else if let warning {
                        self.runWarning = warning
                    }
                }
            }
        }
        return { worker.cancelAndWait() }
    }

    /// Seconds a time-limited run has already spent across earlier (paused) workers.
    @ObservationIgnored private var elapsedBefore: TimeInterval = 0
    @ObservationIgnored private var workerStartedAt: Date?

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
            direct = DirectRun(bundleID: plan.directAppBundleID, snapshot: snapshot)
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
                    case .alive(let pid, let isActive):
                        if directClickOnce(plan, pid: pid, isActive: isActive, resolver: directRun.resolver) {
                            count += 1
                        } else {
                            // Undelivered click: never counted — the counter must mean "clicks
                            // that reached the target", or stopAfterClicks lies.
                            lastWarning = "Target window not found — bring it on-screen at least once; undelivered clicks aren't counted."
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
        private var state = State.unchecked
        private enum State { case unchecked, gone }
        private let snapshot: TargetSnapshot

        init(bundleID: String, snapshot: TargetSnapshot) {
            self.bundleID = bundleID
            self.snapshot = snapshot
        }

        enum Check { case alive(pid: pid_t, isActive: Bool), dead }

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
            return .alive(pid: pid, isActive: target.isActive)
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

    /// Direct-app click: no cursor movement, no app raising — posted into the process.
    /// Returns false (and counts nothing) when no window can be resolved, even occluded ones
    /// via the WindowResolver's .optionAll fallback.
    @discardableResult
    nonisolated private static func directClickOnce(_ plan: Plan, pid: pid_t, isActive: Bool,
                                                    resolver: BackgroundPoster.WindowResolver) -> Bool {
        guard let window = resolver.window(ofPID: pid) else { return false }
        // Same single-randomness rule: this point is fixed, positional jitter applies.
        let screenPoint = plan.positionJitterPx == 0 ? plan.directScreenPoint
            : ClickGeometry.jitter(plan.directScreenPoint, amount: plan.positionJitterPx,
                                   u1: .random(in: 0...1), u2: .random(in: 0...1))
        BackgroundPoster.click(plan.button, screenPoint: screenPoint,
                               holdFor: TickSchedule.pressDuration(interval: plan.interval),
                               clickCount: plan.clickCountPerEvent,
                               window: window, pid: pid, appIsActive: isActive)
        return true
    }

    // MARK: Direct-app helpers (main-actor queries)

    /// One line of truth about where direct-app clicks will land, or why they can't.
    var directAppStatus: String {
        let bundleID = settings.directAppBundleID
        guard !bundleID.isEmpty else { return "No app chosen yet." }
        guard let pid = BackgroundPoster.processID(forBundleID: bundleID) else {
            return "The target app isn't running."
        }
        guard let window = BackgroundPoster.resolveWindowLive(ofPID: pid) else {
            return "Target window not found — bring it on-screen at least once."
        }
        let point = BackgroundPoster.windowPoint(
            fromScreenPoint: CGPoint(x: settings.directAppX, y: settings.directAppY), window: window)
        return "Window \(Int(window.bounds.width))×\(Int(window.bounds.height)) — clicks land at (\(Int(point.x)), \(Int(point.y))) inside it."
    }

    /// Posts one click at the chosen target without starting a run. Reports loudly when it skips.
    func testClick() -> String {
        guard BackgroundPoster.targetingSupported else { return directAppProblem ?? "Background clicks aren't supported here." }
        guard let pid = BackgroundPoster.processID(forBundleID: settings.directAppBundleID) else {
            return "Test click failed — the target app isn't running."
        }
        guard let window = BackgroundPoster.resolveWindowLive(ofPID: pid) else {
            return "Test click failed — target window not found. Bring it on-screen at least once."
        }
        let point = ClickGeometry.jitter(CGPoint(x: settings.directAppX, y: settings.directAppY),
                                         amount: settings.jitterEnabled ? settings.jitterPx : 0,
                                         u1: .random(in: 0...1), u2: .random(in: 0...1))
        BackgroundPoster.click(settings.button, screenPoint: point, holdFor: 0.05,
                               clickCount: max(1, settings.clickCountPerEvent.rawValue),
                               window: window, pid: pid,
                               appIsActive: BackgroundPoster.isActive(bundleID: settings.directAppBundleID))
        return "Test click sent."
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
        endRun()
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
        settings = updated
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
