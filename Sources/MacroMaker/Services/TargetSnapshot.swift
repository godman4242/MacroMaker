import AppKit
import Foundation

/// A lock-protected snapshot of "which app is in front / is running" that worker threads can
/// read **without** touching the main queue. Refreshed on main by NSWorkspace notifications
/// plus a 500 ms timer, so no worker ever calls `DispatchQueue.main.sync` — the deadlock risk
/// it replaces (main's `cancelAndWait` waiting on a worker that is itself waiting on main).
final class TargetSnapshot: @unchecked Sendable {
    static let shared = TargetSnapshot()

    /// The bundle id of the app running a pid, captured when the pid was first resolved and
    /// kept until the process exits — guards against pid reuse mid-run.
    private struct ResolvedApp: Sendable {
        let bundleID: String
        let pid: pid_t
    }

    private let lock = NSLock()
    nonisolated(unsafe) private var _frontmostBundleID: String?
    nonisolated(unsafe) private var _resolvedApps: [String: ResolvedApp] = [:]
    nonisolated(unsafe) private var _started = false

    private init() {}

    /// Starts listening on the main actor (idempotent). The app model calls this at launch.
    @MainActor func start() {
        lock.lock()
        let already = _started
        _started = true
        lock.unlock()
        guard !already else { return }
        refreshFromMain()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshFromMain() }
            }
        }
        // The notifications cover switching and quitting; the timer is the belt-and-braces for
        // states that don't fire them (e.g. an app that crashes between notifications).
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshFromMain() }
        }
    }

    /// Re-reads NSWorkspace/NSRunningApplication on the main actor and publishes the snapshot.
    /// Dropping entries for pids that vanished is the pid-reuse guard: a reused pid re-resolves
    /// to the *new* owner's bundle id, so a stale bundle-id match can't survive it.
    @MainActor func refreshFromMain() {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        lock.lock()
        let known = _resolvedApps
        lock.unlock()
        var resolved: [String: ResolvedApp] = [:]
        known.forEach { bundleID, app in
            if NSRunningApplication(processIdentifier: app.pid)?.bundleIdentifier == bundleID {
                resolved[bundleID] = app
            }
        }
        lock.lock()
        _frontmostBundleID = frontmost
        _resolvedApps = resolved
        lock.unlock()
    }

    /// The frontmost app's bundle id (nil before the first refresh), readable from any thread.
    nonisolated var frontmostBundleID: String? {
        lock.lock()
        defer { lock.unlock() }
        return _frontmostBundleID
    }

    /// The target app's pid and active state from the snapshot — safe from worker threads.
    /// The first lookup of a bundle id hops to the main actor **asynchronously** (refresh) and
    /// reports not-found until the snapshot catches up; runs start after a countdown, so a
    /// pre-warm at arm-time means the click loop never sees the cold state.
    nonisolated func targetState(forBundleID bundleID: String) -> (pid: pid_t?, isActive: Bool) {
        lock.lock()
        let app = _resolvedApps[bundleID]
        let frontmost = _frontmostBundleID
        lock.unlock()
        guard let app else {
            Task { @MainActor [weak self] in self?.resolveFromMain(bundleID) }
            return (nil, false)
        }
        return (app.pid, frontmost == bundleID)
    }

    /// Puts the target app into the snapshot ahead of a run (called on main when arming),
    /// so the worker's first tick already has a pid.
    @MainActor func prewarm(bundleID: String) {
        resolveFromMain(bundleID)
    }

    /// NSRunningApplication lookup on the main actor, written into the lock-protected cache.
    @MainActor private func resolveFromMain(_ bundleID: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return }
        let resolved = ResolvedApp(bundleID: bundleID, pid: app.processIdentifier)
        lock.lock()
        _resolvedApps[bundleID] = resolved
        lock.unlock()
    }
}
