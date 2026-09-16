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

    /// A cursor-capture countdown: pick one point (fixed mode) or two corners (region mode).
    enum PickMode { case point, regionCorner1, regionCorner2, directAppPoint }
    private(set) var pickCountdown: Int?
    private(set) var activePick: PickMode?

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
        let initialFrontmost = settings.stopOnFrontmostChange ? Self.frontmostBundleID() : nil
        let plan = Plan(settings, initialFrontmost: initialFrontmost)
        session.start(withCountdown: trigger == .button,
                      countdownExtra: Int(max(0, settings.delayedStartSeconds).rounded())) { [weak self] token in
            self?.begin(plan, token: token)
        }
    }

    private func begin(_ plan: Plan, token: Int) -> (() -> Void)? {
        runID += 1
        let run = runID
        clickCount = 0
        let worker = WorkerThread.start(name: "AutoClicker") { worker in
            Self.clickLoop(plan, worker: worker) { count, finished in
                performOnMain { [weak self] in
                    guard let self, self.runID == run else { return }
                    self.clickCount = count
                    if finished { self.session.finish(token) }
                }
            }
        }
        return { worker.cancelAndWait() }
    }

    nonisolated private static func clickLoop(_ plan: Plan, worker: WorkerThread,
                                              report: @Sendable (_ count: Int, _ finished: Bool) -> Void) {
        let start = DispatchTime.now().uptimeNanoseconds
        let end = plan.maxDuration.map { start + UInt64($0 * 1_000_000_000) } ?? .max
        var deadline = start
        var count = 0
        var lastReport: UInt64 = 0
        var humanizer = Humanizer(plan.humanizer)

        while !worker.isCancelled, DispatchTime.now().uptimeNanoseconds < end {
            for _ in 0..<plan.burstSize {
                clickOnce(plan)
                count += 1
                if let maxClicks = plan.maxClicks, count >= maxClicks { break }
            }
            if plan.stopOnFrontmostChange,
               FrontmostStopRule.changed(from: plan.initialFrontmost, to: frontmostBundleID()) { break }
            if let maxClicks = plan.maxClicks, count >= maxClicks { break }

            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastReport > 50_000_000 {
                report(count, false)
                lastReport = now
            }
            var delay = TickSchedule.delay(interval: plan.interval, jitter: plan.jitterSeconds,
                                           random: .random(in: -1...1))
            delay = humanizer.nextDelay(interval: delay)
            deadline = TickSchedule.nextDeadline(previous: deadline,
                                                 delay: UInt64(delay * 1_000_000_000), now: now)
            guard worker.sleep(untilUptime: min(deadline, end)) else { break }
        }
        report(count, true)
    }

    /// One click event: resolves the point for this event, then down/up.
    nonisolated private static func clickOnce(_ plan: Plan) {
        if plan.target == .directApp {
            directClickOnce(plan)
            return
        }
        let base: CGPoint? = switch plan.target {
        case .cursor: nil
        case .fixedPoint: plan.fixedPoint
        case .region: ClickGeometry.randomPoint(in: plan.region,
                                                u1: .random(in: 0...1), u2: .random(in: 0...1))
        case .directApp: nil  // never reached: early-returned to directClickOnce above
        }
        var point = base.map {
            ClickGeometry.jitter($0, amount: plan.positionJitterPx,
                                 u1: .random(in: 0...1), u2: .random(in: 0...1))
        } ?? EventSynthesizer.cursorLocation
        if plan.target == .cursor, plan.positionJitterPx > 0 {
            point = ClickGeometry.jitter(point, amount: plan.positionJitterPx,
                                         u1: .random(in: 0...1), u2: .random(in: 0...1))
        }

        let before = plan.restoreCursor ? EventSynthesizer.cursorLocation : nil
        EventSynthesizer.click(plan.button, at: plan.target == .cursor ? nil : point,
                               holdFor: TickSchedule.pressDuration(interval: plan.interval),
                               clickCount: plan.clickCountPerEvent)
        // The real cursor follows HID clicks; optionally put it back where it was.
        if let before, EventSynthesizer.cursorLocation != before {
            EventSynthesizer.postMouse(.mouseMoved, button: .left, at: before)
        }
    }

    /// Direct-app click: no cursor movement, no app raising — posted into the process.
    /// The window's on-screen rect is re-queried each click, so a moving window is followed.
    nonisolated private static func directClickOnce(_ plan: Plan) {
        let state = BackgroundPoster.targetState(forBundleID: plan.directAppBundleID)
        guard let pid = state.pid,
              let window = BackgroundPoster.primaryWindow(ofPID: pid)
        else { return }  // App quit or hid its window mid-run: skip the click, keep the loop alive.
        let screenPoint = ClickGeometry.jitter(plan.directScreenPoint, amount: plan.positionJitterPx,
                                               u1: .random(in: 0...1), u2: .random(in: 0...1))
        BackgroundPoster.click(plan.button, screenPoint: screenPoint,
                               holdFor: TickSchedule.pressDuration(interval: plan.interval),
                               clickCount: plan.clickCountPerEvent,
                               window: window, pid: pid, appIsActive: state.isActive)
    }

    // MARK: Direct-app helpers (main-actor queries)

    /// One line of truth about where direct-app clicks will land, or why they can't.
    var directAppStatus: String {
        let bundleID = settings.directAppBundleID
        guard !bundleID.isEmpty else { return "No app chosen yet." }
        guard let pid = BackgroundPoster.processID(forBundleID: bundleID) else {
            return "The target app isn't running."
        }
        guard let window = BackgroundPoster.primaryWindow(ofPID: pid) else {
            return "No usable window on screen — clicks can't land until one is visible."
        }
        let point = BackgroundPoster.windowPoint(
            fromScreenPoint: CGPoint(x: settings.directAppX, y: settings.directAppY), window: window)
        return "Window \(Int(window.bounds.width))×\(Int(window.bounds.height)) — clicks land at (\(Int(point.x)), \(Int(point.y))) inside it."
    }

    /// Posts one click at the chosen target without starting a run. Reports when it skips.
    func testClick() -> String {
        guard BackgroundPoster.targetingSupported else { return directAppProblem ?? "Background clicks aren't supported here." }
        guard let pid = BackgroundPoster.processID(forBundleID: settings.directAppBundleID) else {
            return "The target app isn't running."
        }
        guard let window = BackgroundPoster.primaryWindow(ofPID: pid) else {
            return "Test click skipped — the app has no on-screen window."
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

    /// Sampled at tick boundaries so the app-switch check costs one call per tick.
    nonisolated static func frontmostBundleID() -> String? {
        DispatchQueue.main.sync {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
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
