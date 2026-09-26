import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import MacroMaker

/// "Play into" (2026-09-26): a macro replayed into one app's process — the real cursor never
/// moves and the app can sit behind whatever the user is doing. Same measured route as the
/// Auto Clicker's "Send to app" (window-aimed events straight to the pid).
@Suite("Play into an app", .serialized, .seamSerialized)
struct PlayIntoAppTests {
    /// A pid no process owns (checked at authoring time) — the tests must never aim a real one.
    private static let pid: pid_t = 99_991

    private final class Capture: @unchecked Sendable {
        struct Posted {
            let type: CGEventType; let pid: pid_t?; let window: Int64; let key: Int64
            let flags: CGEventFlags; let location: CGPoint
        }
        private let lock = NSLock()
        private var hidEvents: [Posted] = []
        private var appEvents: [Posted] = []
        private var failureApps: [String?] = []
        private var failureDepths: [Int?] = []
        var hid: [Posted] { lock.lock(); defer { lock.unlock() }; return hidEvents }
        var app: [Posted] { lock.lock(); defer { lock.unlock() }; return appEvents }
        var failures: [String?] { lock.lock(); defer { lock.unlock() }; return failureApps }
        func record(_ e: CGEvent, pid: pid_t?) {
            let posted = Posted(type: e.type, pid: pid, window: e.getIntegerValueField(CGEventField(rawValue: 91)!),
                                key: e.getIntegerValueField(.keyboardEventKeycode), flags: e.flags, location: e.location)
            lock.lock(); defer { lock.unlock() }
            if pid == nil { hidEvents.append(posted) } else { appEvents.append(posted) }
        }
        func fail(_ failure: MacroPlayer.ChainFailure) {
            lock.lock(); defer { lock.unlock() }
            failureApps.append(failure.windowApp)
        }
        func appTypes() -> [CGEventType] { app.map(\.type) }
        /// The real (non-primer) mouse events posted into the app.
        func realClicks(_ type: CGEventType) -> [Posted] {
            app.filter { $0.type == type && $0.location != BackgroundPoster.primerPoint }
        }
    }

    private static func window(pid: pid_t, number: Int, x: Int, y: Int) -> [String: Any] {
        [kCGWindowOwnerPID as String: Int(pid), kCGWindowLayer as String: 0, kCGWindowNumber as String: number,
         kCGWindowBounds as String: ["X": x, "Y": y, "Width": 600, "Height": 400]]
    }

    /// Runs `plan` with every seam pointed at fake apps (default: pid 99991, one window numbered
    /// 7 at (100,200) 600×400) — nothing reaches the real window server, the real cursor or a
    /// real process. `cancelAfter` presses Stop mid-run.
    private static func play(_ plan: MacroPlayer.Plan,
                             apps: [String: pid_t] = ["com.example.app": pid],
                             windows: [[String: Any]] = [window(pid: pid, number: 7, x: 100, y: 200)],
                             cancelAfter: TimeInterval? = nil) -> Capture {
        let capture = Capture()
        let priorHID = EventSynthesizer.eventPoster
        let priorApp = BackgroundPoster.eventPoster
        let priorList = BackgroundPoster.windowListCopy
        let priorPID = BackgroundPoster.pidResolver
        let priorActivation = BackgroundPoster.activationSymbols
        EventSynthesizer.eventPoster = { capture.record($0, pid: nil) }
        BackgroundPoster.eventPoster = { capture.record($0, pid: $1) }
        BackgroundPoster.windowListCopy = { _ in windows }
        BackgroundPoster.pidResolver = { apps[$0] }
        BackgroundPoster.activationSymbols = { nil }   // never touch real focus
        defer {
            EventSynthesizer.eventPoster = priorHID
            BackgroundPoster.eventPoster = priorApp
            BackgroundPoster.windowListCopy = priorList
            BackgroundPoster.pidResolver = priorPID
            BackgroundPoster.activationSymbols = priorActivation
        }
        let done = DispatchSemaphore(value: 0)
        let worker = WorkerThread.start(name: "play-into") { worker in
            MacroPlayer.play(plan, worker: worker, report: { _, _ in }, chainFailure: { capture.fail($0) })
            done.signal()
        }
        if let cancelAfter {
            Thread.sleep(forTimeInterval: cancelAfter)
            worker.cancel()
        }
        _ = done.wait(timeout: .now() + 5)
        return capture
    }

    private static let clickAndKey: [MacroEvent] = [
        MacroEvent(time: 0, action: .mouseDown(.left, CGPoint(x: 300, y: 400), clickCount: 1), flags: 0),
        MacroEvent(time: 0.02, action: .mouseUp(.left, CGPoint(x: 300, y: 400), clickCount: 1), flags: 0),
        MacroEvent(time: 0.03, action: .keyDown(0, isRepeat: false), flags: 0),
        MacroEvent(time: 0.04, action: .keyUp(0), flags: 0),
        MacroEvent(time: 0.05, action: .move(CGPoint(x: 10, y: 10)), flags: 0),
    ]

    /// The whole point: nothing goes through the real cursor. The click reaches the app's
    /// process aimed at its window (field 91 = the window's number), the keys reach the same
    /// process, and a recorded cursor move has no job to do there — it isn't posted at all.
    @Test func aMacroPlayedIntoAnAppNeverTouchesTheRealCursor() {
        let plan = MacroPlayer.Plan(events: Self.clickAndKey, repeats: 1, speed: 1,
                                    humanizer: HumanizerSettings(), playInto: "com.example.app")
        let capture = Self.play(plan)
        #expect(capture.hid.isEmpty, "nothing may go through the real cursor — got \(capture.hid)")
        let types = capture.appTypes()
        #expect(types.contains(.leftMouseDown) && types.contains(.leftMouseUp),
                "the click reaches the app — got \(types)")
        #expect(types.contains(.keyDown) && types.contains(.keyUp), "the keys reach the app — got \(types)")
        #expect(capture.app.allSatisfy { $0.pid == Self.pid }, "every event goes to the target's process")
        let realClicks = capture.app.filter { [.leftMouseDown, .leftMouseUp].contains($0.type) && $0.window == 7 }
        #expect(realClicks.count >= 2, "the click is aimed at the target's window")
    }

    /// The app quit (or never ran): the run stops LOUD naming the app — never a silent
    /// no-op, and never a fallback into the real cursor.
    @Test func theAppGoneStopsTheRunLoud() {
        let plan = MacroPlayer.Plan(events: Self.clickAndKey, repeats: 1, speed: 1,
                                    humanizer: HumanizerSettings(), playInto: "com.example.app")
        let capture = Self.play(plan, apps: [:])
        #expect(capture.hid.isEmpty, "no fallback into the real cursor")
        #expect(capture.appTypes().isEmpty)
        #expect(capture.failures == ["com.example.app"], "the run names the missing app — got \(capture.failures)")
    }

    /// Settings: absent → the normal replay (empty), and the choice round-trips.
    @Test func thePlayIntoChoiceDecodesTolerantlyAndRoundTrips() throws {
        #expect(try JSONDecoder().decode(PlaybackSettings.self, from: Data("{}".utf8)).playIntoBundleID == "")
        var s = PlaybackSettings(); s.playIntoBundleID = "com.brave.Browser"
        #expect(try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(s)).playIntoBundleID
                == "com.brave.Browser")
    }

    /// Launch check: Roblox is refused up front with the measured reason (it discards input
    /// while it isn't the front app) instead of a run that silently does nothing; an app that
    /// isn't running is refused too; the normal replay has nothing to check.
    @Test func robloxAndMissingAppsAreRefusedBeforeTheRun() {
        #expect(MacroPlayer.playIntoProblem(bundleID: "", isRunning: false) == nil)
        #expect(MacroPlayer.playIntoProblem(bundleID: "com.example.app", isRunning: true) == nil)
        let missing = MacroPlayer.playIntoProblem(bundleID: "com.example.app", isRunning: false)
        #expect(missing?.contains("isn't running") == true, "got \(String(describing: missing))")
        let roblox = MacroPlayer.playIntoProblem(bundleID: "com.roblox.RobloxPlayer", isRunning: true)
        #expect(roblox?.contains("Roblox") == true, "got \(String(describing: roblox))")
    }

    // MARK: Review fixes (2026-09-26)

    private static let point = CGPoint(x: 300, y: 400)
    private static func down(_ at: CGPoint = point, _ t: TimeInterval = 0, flags: CGEventFlags = [],
                             anchor: WindowAnchor? = nil) -> MacroEvent {
        MacroEvent(time: t, action: .mouseDown(.left, at, clickCount: 1), flags: flags.rawValue, windowAnchor: anchor)
    }
    private static func up(_ at: CGPoint = point, _ t: TimeInterval = 0.02, flags: CGEventFlags = []) -> MacroEvent {
        MacroEvent(time: t, action: .mouseUp(.left, at, clickCount: 1), flags: flags.rawValue)
    }

    /// F1: a recorded ⌘-click stays a ⌘-click in the app (a plain click on a link navigates;
    /// a ⌘-click opens a tab — dropping the flag changes what the macro does).
    @Test func aModifierClickKeepsItsModifier() {
        let plan = MacroPlayer.Plan(events: [Self.down(flags: .maskCommand), Self.up(flags: .maskCommand)],
                                    repeats: 1, speed: 1, humanizer: HumanizerSettings(), playInto: "com.example.app")
        let capture = Self.play(plan)
        let real = capture.realClicks(.leftMouseDown) + capture.realClicks(.leftMouseUp)
        #expect(real.count == 2)
        #expect(real.allSatisfy { $0.flags.contains(.maskCommand) },
                "the ⌘ must ride the real down and up — got \(real.map(\.flags))")
    }

    /// F2: Stop while a chained macro holds a key releases it — in the app AND through the
    /// real cursor — and a Stop is not reported as "the macro isn't in the library".
    @Test func stopInsideAChainedMacroReleasesWhatItHeld() {
        let child = Macro(name: "Hold W", createdAt: Date(), events: [
            MacroEvent(time: 0, action: .keyDown(13, isRepeat: false), flags: 0),
            MacroEvent(time: 10, action: .keyUp(13), flags: 0),
        ])
        let childID = UUID()
        for into in [nil, "com.example.app"] as [String?] {
            let plan = MacroPlayer.Plan(events: [MacroEvent(time: 0, action: .runMacro(childID), flags: 0)],
                                        repeats: 1, speed: 1, humanizer: HumanizerSettings(),
                                        chain: ChainedMacros { $0 == childID ? child : nil }, playInto: into)
            let capture = Self.play(plan, cancelAfter: 0.3)
            let posted = into == nil ? capture.hid : capture.app
            #expect(posted.contains { $0.type == .keyUp && $0.key == 13 },
                    "Stop must release the chained macro's held W (\(into ?? "real cursor")) — got \(posted.map(\.type))")
            #expect(capture.failures.isEmpty, "a Stop is not a chain failure — got \(capture.failures)")
        }
    }

    /// F3: a chained macro whose window is gone stops right there — its later steps must not
    /// keep typing into whatever app is in front.
    @Test func aChainedMacroStopsAtItsMissingWindow() {
        let child = Macro(name: "Click then type", createdAt: Date(), events: [
            Self.down(anchor: WindowAnchor(bundleID: "com.example.app", origin: CGPoint(x: 100, y: 200))),
            MacroEvent(time: 0.01, action: .keyDown(0, isRepeat: false), flags: 0),
            MacroEvent(time: 0.02, action: .keyUp(0), flags: 0),
        ])
        let childID = UUID()
        let plan = MacroPlayer.Plan(events: [MacroEvent(time: 0, action: .runMacro(childID), flags: 0)],
                                    repeats: 1, speed: 1, humanizer: HumanizerSettings(),
                                    chain: ChainedMacros { $0 == childID ? child : nil })
        let capture = Self.play(plan, windows: [])   // the app runs, its window is gone
        #expect(!capture.hid.contains { $0.type == .keyDown },
                "no key may follow the missing window into the front app — got \(capture.hid.map(\.type))")
        #expect(capture.failures == ["com.example.app"], "got \(capture.failures)")
    }

    /// F4a: a click outside every window of the target app is refused LOUD — never aimed at
    /// the app's front window instead.
    @Test func aClickOutsideTheAppsWindowsIsRefusedNotAimedElsewhere() {
        let plan = MacroPlayer.Plan(events: [Self.down(CGPoint(x: 5000, y: 5000)), Self.up(CGPoint(x: 5000, y: 5000))],
                                    repeats: 1, speed: 1, humanizer: HumanizerSettings(), playInto: "com.example.app")
        let capture = Self.play(plan)
        #expect(capture.realClicks(.leftMouseDown).isEmpty, "nothing aimed at a window the click isn't in")
        #expect(capture.failures == ["com.example.app"], "got \(capture.failures)")
    }

    /// F4b: two clicks in two windows of the app, fast: each aims at its OWN window (a
    /// resolver cached for 300 ms aimed the second at the first).
    @Test func consecutiveClicksInTwoWindowsEachAimAtTheirOwn() {
        let second = CGPoint(x: 900, y: 400)
        let plan = MacroPlayer.Plan(events: [Self.down(), Self.up(),
                                             Self.down(second, 0.03), Self.up(second, 0.04)],
                                    repeats: 1, speed: 1, humanizer: HumanizerSettings(), playInto: "com.example.app")
        let capture = Self.play(plan, windows: [Self.window(pid: Self.pid, number: 7, x: 100, y: 200),
                                                Self.window(pid: Self.pid, number: 8, x: 800, y: 200)])
        #expect(capture.realClicks(.leftMouseDown).map(\.window) == [7, 8],
                "got \(capture.realClicks(.leftMouseDown).map(\.window))")
    }

    /// F5: "Follow the window" follows only the play-into app's own windows — a click recorded
    /// in another app must not shift by THAT app's window move.
    @Test func followTheWindowOnlyFollowsThePlayIntoApp() {
        let other: pid_t = 99_992
        let plan = MacroPlayer.Plan(events: [
            Self.down(anchor: WindowAnchor(bundleID: "com.example.other", origin: .zero)), Self.up()],
                                    repeats: 1, speed: 1, humanizer: HumanizerSettings(),
                                    followWindow: true, playInto: "com.example.app")
        let capture = Self.play(plan, apps: ["com.example.app": Self.pid, "com.example.other": other],
                                windows: [Self.window(pid: Self.pid, number: 7, x: 100, y: 200),
                                          Self.window(pid: other, number: 9, x: 50, y: 50)])
        #expect(capture.realClicks(.leftMouseDown).map(\.location) == [Self.point],
                "got \(capture.realClicks(.leftMouseDown).map(\.location))")
    }

    /// F6: a typed-text step (virtual key 0, the "a" key) must not erase a held "a" from
    /// what Stop releases.
    @Test func stopReleasesAHeldAEvenAfterATextStep() {
        let plan = MacroPlayer.Plan(events: [
            MacroEvent(time: 0, action: .keyDown(0, isRepeat: false), flags: 0),
            MacroEvent(time: 0.01, action: .keyDown(0, isRepeat: false), flags: 0, textOverride: "Z"),
            MacroEvent(time: 0.02, action: .keyUp(0), flags: 0, textOverride: "Z"),
            MacroEvent(time: 10, action: .keyUp(0), flags: 0),
        ], repeats: 1, speed: 1, humanizer: HumanizerSettings(), playInto: "com.example.app")
        let capture = Self.play(plan, cancelAfter: 0.3)
        #expect(capture.app.filter { $0.type == .keyUp && $0.key == 0 }.count == 2,
                "the text's own key-up AND Stop's release of the held a — got \(capture.app.map(\.type))")
    }

    /// F8: the pre-warm list reaches into chained macros — their window anchors are looked up
    /// on the worker too, and a cold lookup reads as "app quit".
    @Test func chainedAnchorsArePrewarmedToo() {
        let childID = UUID()
        let child = Macro(name: "Child", createdAt: Date(), events: [
            Self.down(anchor: WindowAnchor(bundleID: "com.example.child", origin: .zero))])
        let root = Macro(name: "Root", createdAt: Date(), events: [
            Self.down(anchor: WindowAnchor(bundleID: "com.example.root", origin: .zero)),
            MacroEvent(time: 1, action: .runMacro(childID), flags: 0)])
        #expect(MacroPlayer.bundleIDsToPrewarm(for: root, playInto: "com.example.target",
                                               resolve: { $0 == childID ? child : nil })
                == ["com.example.root", "com.example.child", "com.example.target"])
    }
}
