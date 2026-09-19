import Foundation

/// The idle → countdown → running state machine shared by every start/stop feature.
@MainActor @Observable
final class RunSession {
    static let countdownSeconds = 3

    private(set) var phase: RunPhase = .idle
    private(set) var startedAt: Date?

    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var cancelWork: (() -> Void)?
    /// The feature's teardown, run on every stop of an *active* session. Stops come from
    /// outside the feature too ("Stop Everything", hold-release, profile apply, shutdown)
    /// and those callers can't know about the feature's own watchers — the pause-on-input
    /// monitor and its 1 Hz resume timer used to leak on exactly those paths.
    @ObservationIgnored var onStop: (() -> Void)?
    /// Bumped on every start and stop, so late callbacks from an old run are ignored.
    @ObservationIgnored private var generation = 0

    /// Starts the work, optionally after a countdown.
    ///
    /// `begin` receives a token for `finish(_:)` and returns a closure that stops the work (or nil
    /// if the work couldn't start). The work must report finishing asynchronously, never from
    /// inside `begin`. `countdownExtra` adds seconds to the standard countdown (delayed start).
    func start(withCountdown: Bool, countdownExtra: Int = 0, begin: @escaping @MainActor (_ token: Int) -> (() -> Void)?) {
        guard phase == .idle || phase == .paused else { return }
        generation += 1
        let token = generation
        guard withCountdown else {
            run(token, begin)
            return
        }
        let total = DelayedStart.total(base: Self.countdownSeconds, extra: Double(countdownExtra))
        countdownTask = Task { [weak self] in
            for remaining in stride(from: total, to: 0, by: -1) {
                guard let self, self.generation == token else { return }
                self.phase = .countdown(secondsLeft: remaining)
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, self.generation == token else { return }
            self.run(token, begin)
        }
    }

    func stop() {
        let wasActive = phase != .idle
        generation += 1
        countdownTask?.cancel()
        countdownTask = nil
        let cancel = cancelWork
        cancelWork = nil
        cancel?()
        startedAt = nil
        if phase != .idle { phase = .idle }
        // After the work is cancelled, so teardown sees the session in its final state.
        if wasActive { onStop?() }
    }

    /// Called by the work when it ends on its own (limit reached, macro finished, error).
    func finish(_ token: Int) {
        guard token == generation, phase == .running else { return }
        cancelWork = nil
        startedAt = nil
        phase = .idle
    }

    /// Marks the run paused (pause-on-real-input): the work is cancelled but `finish(_:)`
    /// is not sent, so the feature can resume — with the same plan — via
    /// `start(withCountdown: false, ...)`. Ignored unless actually running.
    func pause() {
        guard phase == .running else { return }
        let cancel = cancelWork
        cancelWork = nil
        cancel?()
        startedAt = nil
        phase = .paused
    }

    /// Returns true when the run is paused and can resume.
    var isPaused: Bool { phase == .paused }

    private func run(_ token: Int, _ begin: @MainActor (Int) -> (() -> Void)?) {
        countdownTask = nil
        guard let cancel = begin(token) else {
            phase = .idle
            return
        }
        cancelWork = cancel
        startedAt = Date()
        phase = .running
    }
}
