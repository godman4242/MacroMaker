import Foundation

/// The idle → countdown → running state machine shared by every start/stop feature.
@MainActor @Observable
final class RunSession {
    static let countdownSeconds = 3

    private(set) var phase: RunPhase = .idle
    private(set) var startedAt: Date?

    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var cancelWork: (() -> Void)?
    /// Bumped on every start and stop, so late callbacks from an old run are ignored.
    @ObservationIgnored private var generation = 0

    /// Starts the work, optionally after a countdown.
    ///
    /// `begin` receives a token for `finish(_:)` and returns a closure that stops the work (or nil
    /// if the work couldn't start). The work must report finishing asynchronously, never from
    /// inside `begin`.
    func start(withCountdown: Bool, begin: @escaping @MainActor (_ token: Int) -> (() -> Void)?) {
        guard phase == .idle else { return }
        generation += 1
        let token = generation
        guard withCountdown else {
            run(token, begin)
            return
        }
        countdownTask = Task { [weak self] in
            for remaining in stride(from: Self.countdownSeconds, to: 0, by: -1) {
                guard let self, self.generation == token else { return }
                self.phase = .countdown(secondsLeft: remaining)
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, self.generation == token else { return }
            self.run(token, begin)
        }
    }

    func stop() {
        generation += 1
        countdownTask?.cancel()
        countdownTask = nil
        let cancel = cancelWork
        cancelWork = nil
        cancel?()
        startedAt = nil
        if phase != .idle { phase = .idle }
    }

    /// Called by the work when it ends on its own (limit reached, macro finished, error).
    func finish(_ token: Int) {
        guard token == generation, phase == .running else { return }
        cancelWork = nil
        startedAt = nil
        phase = .idle
    }

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
