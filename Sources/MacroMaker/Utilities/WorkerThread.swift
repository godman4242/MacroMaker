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

    private static let log = Logger(subsystem: "MacroMaker", category: "WorkerThread")

    /// Cancels, then blocks until the body has returned. The body never waits on the main thread,
    /// so calling this from the main thread can't deadlock.
    ///
    /// A missed deadline is no longer silent: the wait is retried once on a background queue
    /// (Stop never blocks the main thread beyond its single budget — a wedged window-server
    /// call holds the worker past any timeout), the overrun is logged, and if the retry also
    /// misses, `onOverrun` reports it on the main actor. The old callers dropped the result
    /// and declared the run stopped while the worker could still be posting.
    @discardableResult
    func cancelAndWait(timeout: TimeInterval = 1,
                       onOverrun: (@MainActor @Sendable () -> Void)? = nil) -> Bool {
        cancel()
        if finished.wait(timeout: .now() + timeout) == .success { return true }
        Self.log.error("Worker overran Stop's \(timeout, privacy: .public)-second budget; retrying the wait off the main thread")
        DispatchQueue.global(qos: .userInitiated).async {
            let settled = self.finished.wait(timeout: .now() + timeout) == .success
            if !settled {
                Self.log.error("Worker still live after Stop — it may still be clicking or typing")
                if let onOverrun { performOnMain { onOverrun() } }
            }
        }
        return false
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
