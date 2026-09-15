import Foundation
import os

/// A dedicated high-priority thread for time-critical loops (clicking, key presses, playback).
///
/// Unlike `Task.sleep`, cancelling wakes a sleeping worker immediately, so "Stop" is instant even
/// with a 60-second interval — and `cancelAndWait` guarantees cleanup (releasing held keys) has
/// happened before it returns.
final class WorkerThread: Sendable {
    private let wakeUp = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    private init() {}

    static func start(name: String, _ body: @escaping @Sendable (WorkerThread) -> Void) -> WorkerThread {
        let worker = WorkerThread()
        let thread = Thread {
            body(worker)
            worker.finished.signal()
        }
        thread.name = "MacroMaker.\(name)"
        thread.qualityOfService = .userInteractive
        thread.start()
        return worker
    }

    var isCancelled: Bool { cancelled.withLock { $0 } }

    func cancel() {
        let wasRunning = cancelled.withLock { isCancelled in
            defer { isCancelled = true }
            return !isCancelled
        }
        if wasRunning { wakeUp.signal() }
    }

    /// Cancels, then blocks until the body has returned. The body never waits on the main thread,
    /// so calling this from the main thread can't deadlock.
    @discardableResult
    func cancelAndWait(timeout: TimeInterval = 1) -> Bool {
        cancel()
        return finished.wait(timeout: .now() + timeout) == .success
    }

    /// Sleeps until `deadline` (in `DispatchTime` uptime nanoseconds).
    /// Returns `false` — immediately if necessary — once the worker is cancelled.
    func sleep(untilUptime deadline: UInt64) -> Bool {
        if isCancelled { return false }
        if wakeUp.wait(timeout: DispatchTime(uptimeNanoseconds: deadline)) == .success { return false }
        return !isCancelled
    }

    func sleep(seconds: TimeInterval) -> Bool {
        sleep(untilUptime: DispatchTime.now().uptimeNanoseconds + UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// Hops to the main actor in FIFO order (unlike spawning a `Task`), so progress updates from a
/// worker can never arrive after its "finished" message.
func performOnMain(_ body: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated(body)
    }
}
