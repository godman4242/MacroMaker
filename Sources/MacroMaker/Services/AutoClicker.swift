import CoreGraphics
import Foundation

@MainActor @Observable
final class AutoClicker {
    private static let storageKey = "autoClicker"

    var settings = Persistence.load(AutoClickerSettings.self, key: AutoClicker.storageKey) ?? AutoClickerSettings() {
        didSet { Persistence.save(settings, key: Self.storageKey) }
    }

    let session = RunSession()
    private(set) var clickCount = 0
    /// Seconds left while capturing a fixed point from the cursor; nil when not capturing.
    private(set) var pickCountdown: Int?

    @ObservationIgnored private let permissions: PermissionService
    @ObservationIgnored private var pickTask: Task<Void, Never>?
    @ObservationIgnored private var runID = 0

    init(permissions: PermissionService) {
        self.permissions = permissions
    }

    /// An immutable snapshot of the settings, handed to the worker thread.
    private struct Plan: Sendable {
        let button: MouseButton
        let point: CGPoint?
        let interval: TimeInterval
        let jitter: TimeInterval
        let maxClicks: Int?
        let maxDuration: TimeInterval?

        init(_ s: AutoClickerSettings) {
            button = s.button
            point = s.target == .fixedPoint ? CGPoint(x: s.x, y: s.y) : nil
            interval = max(TickSchedule.minimumDelay, s.intervalMs / 1000)
            jitter = s.randomizeInterval ? max(0, s.randomOffsetMs) / 1000 : 0
            maxClicks = s.stopAfterClicks ? max(1, s.maxClicks) : nil
            maxDuration = s.stopAfterDuration ? max(0.1, s.maxDurationSeconds) : nil
        }
    }

    func toggle(_ trigger: StartTrigger) {
        if session.phase.isActive {
            session.stop()
            return
        }
        guard permissions.ensureAccessibility() else { return }
        cancelPick()
        let plan = Plan(settings)
        session.start(withCountdown: trigger == .button) { [weak self] token in
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
        let hold = TickSchedule.pressDuration(interval: plan.interval)
        var deadline = start
        var count = 0
        var lastReport: UInt64 = 0

        while !worker.isCancelled, DispatchTime.now().uptimeNanoseconds < end {
            EventSynthesizer.click(plan.button, at: plan.point, holdFor: hold)
            count += 1
            if let maxClicks = plan.maxClicks, count >= maxClicks { break }

            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastReport > 50_000_000 {
                report(count, false)
                lastReport = now
            }
            let delay = TickSchedule.delay(interval: plan.interval, jitter: plan.jitter, random: .random(in: -1...1))
            deadline = TickSchedule.nextDeadline(previous: deadline, delay: UInt64(delay * 1_000_000_000), now: now)
            guard worker.sleep(untilUptime: min(deadline, end)) else { break }
        }
        report(count, true)
    }

    /// Counts down so the user can move the cursor to the target, then stores its position.
    func pickFixedPoint() {
        cancelPick()
        pickTask = Task { [weak self] in
            for remaining in stride(from: RunSession.countdownSeconds, to: 0, by: -1) {
                self?.pickCountdown = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            guard let self else { return }
            let location = EventSynthesizer.cursorLocation
            var updated = settings
            updated.x = location.x.rounded()
            updated.y = location.y.rounded()
            updated.target = .fixedPoint
            settings = updated
            pickCountdown = nil
        }
    }

    func cancelPick() {
        pickTask?.cancel()
        pickTask = nil
        pickCountdown = nil
    }
}
