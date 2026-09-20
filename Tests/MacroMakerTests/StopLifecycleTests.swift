import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import MacroMaker

/// Wave 1 — the stop paths ("Stop Everything", hold-release, profile apply, shutdown) used to
/// call `RunSession.stop()` directly, bypassing the feature's teardown: the real-input monitor
/// stayed installed forever, the 1 Hz resume timer kept firing, and the next run start tripped
/// the monitor's single-subscriber debug assert.
///
/// One serialized suite: these tests share the `RealInputMonitor` singleton and the
/// `BackgroundPoster` event-poster seam.
@Suite("Stop-path lifecycle", .serialized, .seamSerialized)
@MainActor
struct StopLifecycleTests {

    // MARK: RealInputMonitor subscriber counting

    /// A resume re-starts the same watcher (begin and resume both land in
    /// `startPauseWatching`); the old debug assert trapped on that second start, and a
    /// double count kept the monitors installed after `endRun` for the rest of the process.
    @Test func aSecondStartOfTheSameWatcherDoesNotCrashOrDoubleCount() {
        let monitor = RealInputMonitor.shared
        defer { monitor.stop() }
        monitor.start(onRealInput: {})
        monitor.start(onRealInput: {})
        #expect(monitor.subscribers == 1, "one watcher, re-started — not two")
        monitor.stop()
        #expect(monitor.subscribers == 0, "stop removes the watcher, so endRun's stop must land")
        monitor.stop()
        #expect(monitor.subscribers == 0, "stop is idempotent")
    }

    // MARK: Stop Everything tears the run down like the in-app Stop

    /// The pause-on-input run scenario: start → Stop Everything → start again. Before the
    /// fix, `stopAll` called the bare session stop, so the input monitor stayed installed
    /// (subscribers never returned to 0), the 1 Hz resume timer kept firing, and the next
    /// start tripped the monitor's single-subscriber debug assert.
    @Test func stopEverythingRemovesThePauseWatcherAndTheNextRunStartsClean() {
        let model = AppModel.shared
        let clicker = model.autoClicker
        let defaults = UserDefaults.standard
        let savedSettingsBlob = defaults.data(forKey: AutoClicker.storageKey)
        let savedSettings = clicker.settings
        let savedPoster = BackgroundPoster.eventPoster
        model.permissions.forceAccessibilityTrusted = true
        // The run aims at an app that is always running (Finder); clicks go through the
        // event-poster seam, so nothing is ever posted to the real window server.
        BackgroundPoster.eventPoster = { _, _ in }
        defer {
            BackgroundPoster.eventPoster = savedPoster
            model.permissions.forceAccessibilityTrusted = false
            model.stopAll()
            clicker.settings = savedSettings
            // Byte-identical defaults restore: the re-assign above re-encoded the blob.
            if let savedSettingsBlob { defaults.set(savedSettingsBlob, forKey: AutoClicker.storageKey) }
            else { defaults.removeObject(forKey: AutoClicker.storageKey) }
        }

        var settings = clicker.settings
        settings.pauseOnRealInput = true
        settings.target = .directApp
        settings.directAppBundleID = "com.apple.finder"
        clicker.settings = settings

        clicker.toggle(.hotkey)   // hotkey trigger: no countdown, running immediately
        #expect(clicker.session.phase == .running)
        #expect(RealInputMonitor.shared.subscribers == 1)

        model.stopAll()
        #expect(clicker.session.phase == .idle)
        #expect(RealInputMonitor.shared.subscribers == 0,
                "Stop Everything must remove the watcher, not just flip the phase")

        clicker.toggle(.hotkey)   // the next start re-installs the watcher cleanly — no assert
        #expect(clicker.session.phase == .running)
        #expect(RealInputMonitor.shared.subscribers == 1)
        model.stopAll()
        #expect(RealInputMonitor.shared.subscribers == 0)
    }

    // MARK: Stop's cancel-and-wait must fail loud

    /// Blocks the first click post until the test opens the gate — the wedge sits exactly
    /// where a slow window-server call would, past any cancellation check.
    private final class ClickGate: @unchecked Sendable {
        private let entered = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var opened = false

        var poster: (CGEvent, pid_t) -> Void {
            { [self] _, _ in
                entered.signal()
                lock.lock()
                let open = opened
                lock.unlock()
                if !open { release.wait() }
            }
        }

        func awaitEntry() throws {
            guard entered.wait(timeout: .now() + 3) == .success else {
                throw NSError(domain: "StopLifecycleTests", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: "the worker never reached the click post"])
            }
        }

        func open() {
            lock.lock()
            opened = true
            lock.unlock()
            release.signal()
        }
    }

    /// Records what reached the shared loud-failure seam, swapped in by the per-service
    /// overrun tests (the services have no warning banner of their own — os_log is their
    /// surface, and this seam is how a test observes it).
    private final class OverrunBox: @unchecked Sendable {
        var services: [String] = []
    }

    /// N1: the same fail-loud contract as the AutoClicker test above, for the Key Presser —
    /// its stop closure used to return `{ worker.cancelAndWait() }`, discarding the result
    /// and declaring the run stopped while a wedged worker could still be typing into the
    /// target app. The overrun must reach the shared loud-failure surface.
    @Test func keyPresserStopThatOutrunsItsBudgetSurfacesTheOverrun() async throws {
        let model = AppModel.shared
        let presser = model.keyPresser
        let defaults = UserDefaults.standard
        let savedSettingsBlob = defaults.data(forKey: "keyPresser")
        let savedSettings = presser.settings
        let savedPoster = BackgroundPoster.eventPoster
        let savedSurface = WorkerThread.overrunSurface
        let gate = ClickGate()
        let box = OverrunBox()
        model.permissions.forceAccessibilityTrusted = true
        BackgroundPoster.eventPoster = gate.poster
        WorkerThread.overrunSurface = { box.services.append($0) }
        defer {
            gate.open()
            BackgroundPoster.eventPoster = savedPoster
            WorkerThread.overrunSurface = savedSurface
            model.permissions.forceAccessibilityTrusted = false
            model.stopAll()
            presser.settings = savedSettings
            if let savedSettingsBlob { defaults.set(savedSettingsBlob, forKey: "keyPresser") }
            else { defaults.removeObject(forKey: "keyPresser") }
        }

        var settings = presser.settings
        settings.keyText = "space"
        settings.mode = .autoPress
        // Direct-app delivery: the press posts through the (gated) BackgroundPoster seam.
        settings.sendToBundleID = "com.apple.finder"
        presser.settings = settings

        presser.toggle(.hotkey)
        #expect(presser.session.phase == .running)
        try gate.awaitEntry()   // the worker is now wedged inside its key post

        let stopStarted = Date()
        presser.toggle(.hotkey)  // Stop: waits the budget, then must give up loudly
        #expect(Date().timeIntervalSince(stopStarted) < 1.5,
                "Stop's main-thread cost stays within its single 1 s budget")
        #expect(presser.session.phase == .idle)

        let deadline = Date().addingTimeInterval(5)
        while box.services.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(box.services.contains("Key Presser"),
                "a key-presser worker that outlives Stop must surface, not be silently declared stopped")
    }

    /// N1 for the Macro Player: identical contract, wedged through the playback post seam.
    /// The old stop closure discarded the wait result, so a wedged replay could keep
    /// clicking and typing behind the user's back with nothing anywhere saying so.
    @Test func playbackStopThatOutrunsItsBudgetSurfacesTheOverrun() async throws {
        let model = AppModel.shared
        let player = model.player
        let defaults = UserDefaults.standard
        let savedSettingsBlob = defaults.data(forKey: "playback")
        let savedSettings = player.settings
        let savedPoster = EventSynthesizer.eventPoster
        let savedSurface = WorkerThread.overrunSurface
        let gate = ClickGate()
        let box = OverrunBox()
        model.permissions.forceAccessibilityTrusted = true
        EventSynthesizer.eventPoster = { gate.poster($0, 0) }
        WorkerThread.overrunSurface = { box.services.append($0) }
        defer {
            gate.open()
            EventSynthesizer.eventPoster = savedPoster
            WorkerThread.overrunSurface = savedSurface
            model.permissions.forceAccessibilityTrusted = false
            model.stopAll()
            player.settings = savedSettings
            if let savedSettingsBlob { defaults.set(savedSettingsBlob, forKey: "playback") }
            else { defaults.removeObject(forKey: "playback") }
        }

        // One key-down due immediately: the worker's very first post wedges on the gate.
        let macro = Macro(name: "wedge", events: [MacroEvent(time: 0, action: .keyDown(49, isRepeat: false), flags: 0)])
        player.toggle(macro, trigger: .hotkey)
        #expect(player.session.phase == .running)
        try gate.awaitEntry()

        let stopStarted = Date()
        player.toggle(macro, trigger: .hotkey)
        #expect(Date().timeIntervalSince(stopStarted) < 1.5,
                "Stop's main-thread cost stays within its single 1 s budget")
        #expect(player.session.phase == .idle)

        let deadline = Date().addingTimeInterval(5)
        while box.services.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(box.services.contains("Macro Player"),
                "a playback worker that outlives Stop must surface, not be silently declared stopped")
    }

    /// A worker that misses Stop's one-second budget used to be silently declared stopped:
    /// `cancelAndWait` returned `false` and every caller dropped it, leaving a live worker
    /// that could still post clicks. The overrun must fail loud.
    @Test func aStopThatOutrunsItsBudgetSurfacesAWarning() async throws {
        let model = AppModel.shared
        let clicker = model.autoClicker
        let defaults = UserDefaults.standard
        let savedSettingsBlob = defaults.data(forKey: AutoClicker.storageKey)
        let savedSettings = clicker.settings
        let savedPoster = BackgroundPoster.eventPoster
        let gate = ClickGate()
        model.permissions.forceAccessibilityTrusted = true
        BackgroundPoster.eventPoster = gate.poster
        defer {
            gate.open()
            BackgroundPoster.eventPoster = savedPoster
            model.permissions.forceAccessibilityTrusted = false
            model.stopAll()
            clicker.settings = savedSettings
            if let savedSettingsBlob { defaults.set(savedSettingsBlob, forKey: AutoClicker.storageKey) }
            else { defaults.removeObject(forKey: AutoClicker.storageKey) }
        }

        var settings = clicker.settings
        settings.target = .directApp
        settings.directAppBundleID = "com.apple.finder"
        clicker.settings = settings

        clicker.toggle(.hotkey)
        try gate.awaitEntry()   // the worker is now wedged inside its click post

        let stopStarted = Date()
        clicker.toggle(.hotkey)       // Stop: waits the budget, then must give up loudly
        #expect(Date().timeIntervalSince(stopStarted) < 1.5,
                "Stop's main-thread cost stays within its single 1 s budget")
        #expect(clicker.session.phase == .idle)

        // The retry happens off the main thread; the warning lands when it also misses.
        let deadline = Date().addingTimeInterval(5)
        while clicker.runWarning == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(clicker.runWarning != nil,
                "a timed-out Stop must be visible, not silently declared done")
    }

    // MARK: Wave 2 — an undeliverable click must fail loud, not count

    /// F5: a click whose NSEvent conversion returns nil used to vanish silently — nothing
    /// posted, no warning, and `directClickOnce` still counted it as delivered. The failure
    /// must surface through the runWarning channel and never tick the "clicks that reached
    /// the target" counter.
    @Test func anUndeliverableClickSurfacesAWarningInsteadOfCounting() async throws {
        let model = AppModel.shared
        let clicker = model.autoClicker
        let defaults = UserDefaults.standard
        let savedSettingsBlob = defaults.data(forKey: AutoClicker.storageKey)
        let savedSettings = clicker.settings
        let savedPoster = BackgroundPoster.eventPoster
        let savedBuilder = BackgroundPoster.nsMouseEventBuilder
        model.permissions.forceAccessibilityTrusted = true
        BackgroundPoster.eventPoster = { _, _ in }
        // Force F5's failure path: the AppKit conversion returns nil for every event.
        BackgroundPoster.nsMouseEventBuilder = { _, _, _, _, _ in nil }
        defer {
            BackgroundPoster.eventPoster = savedPoster
            BackgroundPoster.nsMouseEventBuilder = savedBuilder
            model.permissions.forceAccessibilityTrusted = false
            model.stopAll()
            clicker.settings = savedSettings
            if let savedSettingsBlob { defaults.set(savedSettingsBlob, forKey: AutoClicker.storageKey) }
            else { defaults.removeObject(forKey: AutoClicker.storageKey) }
        }

        var settings = clicker.settings
        settings.target = .directApp
        settings.directAppBundleID = "com.apple.finder"
        // Both limits: old code counted the undelivered clicks and would race the click limit;
        // new code never counts them, so the duration limit is what ends the run.
        settings.stopAfterClicks = true
        settings.maxClicks = 5
        settings.stopAfterDuration = true
        settings.maxDurationSeconds = 0.3
        clicker.settings = settings

        clicker.toggle(.hotkey)
        let deadline = Date().addingTimeInterval(5)
        while clicker.session.phase != .idle, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(clicker.session.phase == .idle, "the duration limit must end the run")
        #expect(clicker.clickCount == 0,
                "a click that never became an event must never be counted as delivered")
        #expect(clicker.runWarning != nil,
                "the swallowed conversion failure must be visible in the UI, not silent")
    }

    /// Fix 6 (appkit-accept #2): testClick used to say "sent" merely because it called the
    /// poster. Truth now: AX granted AND a fully-aimed event (window fields, self-tag, no fake
    /// modifiers) actually went out the poster seam — a failed build says so instead of lying.
    @Test func testClickReportsSentOnlyForADeliveredWellAimedEvent() async throws {
        let model = AppModel.shared
        let clicker = model.autoClicker
        let defaults = UserDefaults.standard
        let savedSettingsBlob = defaults.data(forKey: AutoClicker.storageKey)
        let savedSettings = clicker.settings
        let savedPoster = BackgroundPoster.eventPoster
        let savedBuilder = BackgroundPoster.nsMouseEventBuilder
        model.permissions.forceAccessibilityTrusted = true
        final class EventBox: @unchecked Sendable { var events: [CGEvent] = [] }
        let box = EventBox()
        BackgroundPoster.eventPoster = { event, _ in box.events.append(event) }
        defer {
            BackgroundPoster.eventPoster = savedPoster
            BackgroundPoster.nsMouseEventBuilder = savedBuilder
            model.permissions.forceAccessibilityTrusted = false
            model.stopAll()
            clicker.settings = savedSettings
            if let savedSettingsBlob { defaults.set(savedSettingsBlob, forKey: AutoClicker.storageKey) }
            else { defaults.removeObject(forKey: AutoClicker.storageKey) }
        }

        var settings = clicker.settings
        settings.target = .directApp
        settings.directAppBundleID = "com.apple.finder"
        clicker.settings = settings

        let reply = clicker.testClick()
        // A healthy click reports sent AND tells the user to go and look: "sent" alone reads as
        // "it works", which is false for any target that silently eats background clicks.
        #expect(reply.hasPrefix("Test click sent to "), "a healthy click must report sent, got: \(reply)")
        #expect(reply.contains("look at it now"),
                "the reply must send the user to check the target, since delivery can't be confirmed: \(reply)")
        // Five, not two: a background click is a stamped move, an off-screen primer down/up,
        // then the real down/up — the sequence Chromium-class targets need (BackgroundPoster.click).
        #expect(box.events.count == 5, "a click is move + primer pair + down/up, got \(box.events.count)")
        for event in box.events {
            #expect(NSEvent(cgEvent: event)?.windowNumber ?? 0 > 0,
                    "the test event must name a real window of the target app")
            #expect(event.getIntegerValueField(CGEventField(rawValue: 91)!) > 0)
            #expect(event.getIntegerValueField(CGEventField(rawValue: 92)!) > 0)
            #expect(event.flags == .maskNonCoalesced, "no fake modifiers on a test click")
            #expect(event.getIntegerValueField(.eventSourceUserData) == EventSynthesizer.eventTag)
        }

        // The failure branch: the AppKit conversion dies, so "sent" would be a lie.
        BackgroundPoster.nsMouseEventBuilder = { _, _, _, _, _ in nil }
        box.events.removeAll()
        let failed = clicker.testClick()
        #expect(!failed.hasPrefix("Test click sent"), "an undeliverable test click must not claim success")
        #expect(failed.contains("failed"), "the failure must say so, got: \(failed)")
        #expect(box.events.isEmpty, "nothing may be posted when the event can't be built")
    }

    // MARK: a stale natural-finish report cannot resurrect the warning

    /// The worker finished naturally (limit reached) and queued its final report; the user
    /// pressed Stop before main drained it. The report belongs to a run the user already
    /// dismissed — it must set neither the warning banner nor the counters.
    @Test func aFinishReportQueuedBeforeAStopResurrectsNothingAfterIt() {
        let clicker = AppModel.shared.autoClicker
        clicker.session.start(withCountdown: false) { _ in { } }
        let stoppedRun = clicker.runID   // the id the (already finished) worker reports under
        clicker.session.stop()
        clicker.handleWorkerReport(run: stoppedRun, token: 0, count: 5, finished: true,
                                   warning: "The target app quit or was replaced mid-run — the run stopped rather than click the wrong process.")
        #expect(clicker.runWarning == nil, "a stopped run's late report must resurrect nothing")
    }
}