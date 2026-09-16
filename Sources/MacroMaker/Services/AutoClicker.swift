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
    enum PickMode { case point, regionCorner1, regionCorner2 }
    private(set) var pickCountdown: Int?
    private(set) var activePick: PickMode?

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
        }
    }

    func toggle(_ trigger: StartTrigger) {
        if session.phase.isActive {
            session.stop()
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
            let delay = TickSchedule.delay(interval: plan.interval, jitter: plan.jitterSeconds,
                                           random: .random(in: -1...1))
            deadline = TickSchedule.nextDeadline(previous: deadline,
                                                 delay: UInt64(delay * 1_000_000_000), now: now)
            guard worker.sleep(untilUptime: min(deadline, end)) else { break }
        }
        report(count, true)
    }

    /// One click event: resolves the point for this event, then down/up.
    nonisolated private static func clickOnce(_ plan: Plan) {
        let base: CGPoint? = switch plan.target {
        case .cursor: nil
        case .fixedPoint: plan.fixedPoint
        case .region: ClickGeometry.randomPoint(in: plan.region,
                                                u1: .random(in: 0...1), u2: .random(in: 0...1))
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
