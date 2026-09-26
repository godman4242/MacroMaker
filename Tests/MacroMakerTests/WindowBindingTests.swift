import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import MacroMaker

/// Wave 7, feature 5 — per-app window binding (features.json F-14): a recording captures,
/// per mouse step, the frontmost app and its window's frame origin; "Follow the window"
/// (on by default) replays translated by (current origin − recorded origin), so a window
/// that moved since recording still gets its clicks. The window missing at replay is a
/// LOUD failure, not a click into whatever sits there now.
@Suite("Window binding", .serialized, .seamSerialized)
struct WindowBindingTests {

    // MARK: The pure rule — translate a recorded point to the window's current frame

    /// A step recorded at (30, 40) inside a window then at origin (100, 200) replays at
    /// (30, 40) + (current − recorded) origin — the same spot INSIDE the window wherever
    /// it moved. A window that didn't move is a no-op.
    @Test func theRuleTranslatesByTheOriginDelta() {
        let recorded = CGPoint(x: 100, y: 200)
        let step = CGPoint(x: 30, y: 40)
        #expect(WindowBinding.translated(step, recordedOrigin: recorded, currentOrigin: recorded) == step,
                "a window that didn't move changes nothing")
        #expect(WindowBinding.translated(step, recordedOrigin: recorded, currentOrigin: CGPoint(x: 150, y: 180))
                == CGPoint(x: 80, y: 20), "the point follows the window's move")
        // Window gone to another display: the delta still applies (points are global).
        #expect(WindowBinding.translated(step, recordedOrigin: recorded, currentOrigin: CGPoint(x: -50, y: 0))
                == CGPoint(x: -120, y: -160))
    }

    /// A step recorded with NO anchor (an old file, or a recording made while the window
    /// couldn't be resolved) plays verbatim — the pre-binding absolute replay.
    @Test func anUnanchoredStepPlaysVerbatim() {
        #expect(WindowBinding.translated(CGPoint(x: 7, y: 8), recordedOrigin: nil,
                                        currentOrigin: CGPoint(x: 500, y: 500)) == CGPoint(x: 7, y: 8),
                "nothing to translate against — the recorded point stands")
    }

    // MARK: The file format — the anchor rides along, tolerance for older files

    /// A mouse step with an anchor round-trips through the file (version 2 carries
    /// "app" and "wx"/"wy"); a step without one round-trips as nil; a PINNED older
    /// file with none of the keys decodes with a nil anchor — every existing macro
    /// keeps opening and playing exactly as before.
    @Test func anchorsRoundTripAndOldFilesDecodeWithoutThem() throws {
        let anchored = Macro(name: "Anchored", createdAt: Date(timeIntervalSince1970: 1_789_000_000), events: [
            MacroEvent(time: 0, action: .mouseDown(.left, CGPoint(x: 30, y: 40), clickCount: 1), flags: 256,
                       windowAnchor: WindowAnchor(bundleID: "com.apple.finder", origin: CGPoint(x: 100, y: 200))),
            MacroEvent(time: 0.1, action: .mouseUp(.left, CGPoint(x: 30, y: 40), clickCount: 1), flags: 256),
        ])
        let decoded = try Macro(jsonData: anchored.jsonData())
        #expect(decoded.events[0].windowAnchor == anchored.events[0].windowAnchor,
                "the anchor survives save + open")
        #expect(decoded.events[1].windowAnchor == nil, "a step recorded without one stays unanchored")

        let pinned = """
        { "format": "macromaker", "version": 2, "name": "Old", "createdAt": "2026-09-16T10:00:00Z",
          "events": [ { "t": 0, "type": "mouseDown", "button": "left", "x": 512, "y": 384, "flags": 0 } ] }
        """
        let legacy = try Macro(jsonData: Data(pinned.utf8))
        #expect(legacy.events[0].windowAnchor == nil,
                "an older file decodes with no anchor and plays absolute, as before")
    }

    /// A corrupt anchor (a non-finite origin) is dropped at decode, not trusted — a NaN
    /// reaching the translation would poison every downstream point.
    @Test func aCorruptAnchorIsDroppedAtDecode() throws {
        let pinned = """
        { "format": "macromaker", "version": 2, "name": "Bad", "createdAt": "2026-09-16T10:00:00Z",
          "events": [ { "t": 0, "type": "mouseDown", "button": "left", "x": 5, "y": 5, "flags": 0,
                        "app": "com.apple.finder", "wx": 1e400, "wy": 10 } ] }
        """
        let macro = try Macro(jsonData: Data(pinned.utf8))
        #expect(macro.events[0].windowAnchor == nil,
                "a non-finite origin makes the anchor unusable — the step falls back to absolute")
    }

    // MARK: The recorder — each mouseDown captures the anchor

    /// A mouseDown during recording carries the bundle id of the app that owns the clicked
    /// window, and that window's origin; key steps and scrolls don't pay for one (their points
    /// aren't replay targets of the binding — a scroll replays where the cursor is, and a key
    /// doesn't aim).
    @Test @MainActor func aMouseDownRecordsTheClickedWindowsAppAndOrigin() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let priorTap = MacroRecorder.tapBuilder
        MacroRecorder.tapBuilder = { _, _ in CFMachPortCreate(nil, nil, nil, nil) }
        let priorList = BackgroundPoster.windowListCopy
        BackgroundPoster.windowListCopy = { _ in [
            [kCGWindowOwnerPID as String: 401, kCGWindowLayer as String: 0,
             kCGWindowNumber as String: 7, kCGWindowBounds as String: ["X": 100, "Y": 200, "Width": 600, "Height": 400]] ]
        }
        let priorFront = TargetSnapshot.shared.frontmostBundleIDForTests
        TargetSnapshot.shared.frontmostBundleIDForTests = "com.example.app"
        let priorPID = BackgroundPoster.pidResolver
        BackgroundPoster.pidResolver = { bundleID in bundleID == "com.example.app" ? 401 : nil }
        let priorBundle = BackgroundPoster.bundleIDResolver
        BackgroundPoster.bundleIDResolver = { $0 == 401 ? "com.example.app" : nil }
        defer {
            MacroRecorder.tapBuilder = priorTap
            BackgroundPoster.windowListCopy = priorList
            TargetSnapshot.shared.frontmostBundleIDForTests = priorFront
            BackgroundPoster.pidResolver = priorPID
            BackgroundPoster.bundleIDResolver = priorBundle
        }

        let recorder = MacroRecorder()
        #expect(recorder.start())
        defer { _ = recorder.stop() }

        let down = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                        mouseCursorPosition: CGPoint(x: 130, y: 240),
                                        mouseButton: .left))
        down.setIntegerValueField(.eventSourceUserData, value: 0)   // not the player's own event
        recorder.handle(TapEvent(type: .leftMouseDown, event: down))

        let events = recorder.liveEvents
        #expect(events.count == 1, "one mouseDown recorded, got \(events.count)")
        let anchor = try #require(events.first?.windowAnchor)
        #expect(anchor.bundleID == "com.example.app", "the clicked window's app is captured")
        #expect(anchor.origin == CGPoint(x: 100, y: 200),
                "the window's frame origin is captured at the click")
    }

    // MARK: The settings toggle

    /// "Follow the window" decodes tolerantly (absent → ON, the feature's default) and
    /// round-trips; the plan carries it through to the play path.
    @Test func followTheWindowDefaultsOnAndRoundTrips() throws {
        let fromEmpty = try JSONDecoder().decode(PlaybackSettings.self, from: Data("{}".utf8))
        #expect(fromEmpty.followWindow == true, "the toggle is on unless the user turns it off")
        var on = PlaybackSettings(); on.followWindow = true
        var off = PlaybackSettings(); off.followWindow = false
        #expect(try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(on)).followWindow == true)
        #expect(try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(off)).followWindow == false)
    }

    // MARK: Playback — translation at run time

    /// The player translates an anchored mouse step by the window's CURRENT origin when
    /// "Follow the window" is on, and plays the recorded point verbatim when it's off.
    /// The window missing at replay fails the run LOUD.
    @Test func playbackTranslatesAnchoredStepsAndFailsLoudWhenTheWindowIsGone() throws {
        final class PostBox: @unchecked Sendable {
            var points: [CGPoint] = []; var warnings: [String] = []; let lock = NSLock()
        }
        let box = PostBox()
        let priorPoster = EventSynthesizer.eventPoster
        let priorList = BackgroundPoster.windowListCopy
        EventSynthesizer.eventPoster = { event in
            box.lock.lock(); defer { box.lock.unlock() }
            box.points.append(CGPoint(x: event.location.x, y: event.location.y))
        }
        BackgroundPoster.windowListCopy = { _ in [
            [kCGWindowOwnerPID as String: 401, kCGWindowLayer as String: 0,
             kCGWindowNumber as String: 7, kCGWindowBounds as String: ["X": 250, "Y": 220, "Width": 600, "Height": 400]] ]
        }
        defer {
            EventSynthesizer.eventPoster = priorPoster
            BackgroundPoster.windowListCopy = priorList
        }

        let anchor = WindowAnchor(bundleID: "com.example.app", origin: CGPoint(x: 100, y: 200))
        let events = [
            MacroEvent(time: 0, action: .mouseDown(.left, CGPoint(x: 130, y: 240), clickCount: 1),
                       flags: 0, windowAnchor: anchor),
            MacroEvent(time: 0.01, action: .mouseUp(.left, CGPoint(x: 130, y: 240), clickCount: 1),
                       flags: 0, windowAnchor: anchor),
        ]

        // A pid seam: the anchor's bundle resolves to a pid whose window moved to (250, 220).
        let priorPID = BackgroundPoster.pidResolver
        BackgroundPoster.pidResolver = { bundleID in bundleID == "com.example.app" ? 401 : nil }
        defer { BackgroundPoster.pidResolver = priorPID }

        let settings = PlaybackSettings()
        let plan = MacroPlayer.Plan(events: events, repeats: 1, speed: 1, humanizer: HumanizerSettings(),
                                    followWindow: true)
        let done = DispatchSemaphore(value: 0)
        _ = WorkerThread.start(name: "w7-window") { worker in
            MacroPlayer.play(plan, worker: worker) { _, _ in }
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 5) == .success)
        box.lock.lock()
        let posted = box.points
        box.lock.unlock()
        #expect(posted.contains(CGPoint(x: 280, y: 260)),
                "the click lands at the recorded spot inside the window's CURRENT frame: (130,240)+(250−100,220−200), got \(posted)")

        // The window gone: the run ends LOUD with a warning naming the app, never a click
        // into whatever moved in. The failure reuses the chainFailure channel — one loud
        // banner for "the run couldn't do what it promised".
        box.points.removeAll()
        BackgroundPoster.windowListCopy = { _ in [] }
        let gonePlan = MacroPlayer.Plan(events: [events[0]], repeats: 1, speed: 1,
                                        humanizer: HumanizerSettings(), followWindow: true)
        let goneDone = DispatchSemaphore(value: 0)
        _ = WorkerThread.start(name: "w7-window-gone") { worker in
            MacroPlayer.play(gonePlan, worker: worker, report: { _, _ in },
                              chainFailure: { failure in
                                  box.lock.lock(); defer { box.lock.unlock() }
                                  box.warnings.append(failure.macroID.uuidString)
                              })
            goneDone.signal()
        }
        #expect(goneDone.wait(timeout: .now() + 5) == .success)
        box.lock.lock()
        let warnings = box.warnings
        box.lock.unlock()
        #expect(!warnings.isEmpty,
                "a missing window must fail the run loud, not post into whatever sits there")
        #expect(box.points.isEmpty, "no event was posted")
    }

    /// "Follow the window" OFF: the same anchored macro plays its recorded points verbatim —
    /// the toggle is the escape hatch back to pure absolute replay.
    @Test func playbackOffPlaysTheRecordedPointVerbatim() throws {
        final class PostBox: @unchecked Sendable { var points: [CGPoint] = []; let lock = NSLock() }
        let box = PostBox()
        let priorPoster = EventSynthesizer.eventPoster
        let priorList = BackgroundPoster.windowListCopy
        EventSynthesizer.eventPoster = { event in
            box.lock.lock(); defer { box.lock.unlock() }
            box.points.append(CGPoint(x: event.location.x, y: event.location.y))
        }
        BackgroundPoster.windowListCopy = { _ in [
            [kCGWindowOwnerPID as String: 401, kCGWindowLayer as String: 0,
             kCGWindowNumber as String: 7, kCGWindowBounds as String: ["X": 250, "Y": 220, "Width": 600, "Height": 400]] ]
        }
        defer {
            EventSynthesizer.eventPoster = priorPoster
            BackgroundPoster.windowListCopy = priorList
        }

        let anchor = WindowAnchor(bundleID: "com.example.app", origin: CGPoint(x: 100, y: 200))
        let plan = MacroPlayer.Plan(events: [
            MacroEvent(time: 0, action: .mouseDown(.left, CGPoint(x: 130, y: 240), clickCount: 1),
                       flags: 0, windowAnchor: anchor),
        ], repeats: 1, speed: 1, humanizer: HumanizerSettings(), followWindow: false)
        let done = DispatchSemaphore(value: 0)
        _ = WorkerThread.start(name: "w7-window-off") { worker in
            MacroPlayer.play(plan, worker: worker) { _, _ in }
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 5) == .success)
        box.lock.lock()
        let posted = box.points
        box.lock.unlock()
        #expect(posted.contains(CGPoint(x: 130, y: 240)),
                "the toggle off means the recorded point verbatim, got \(posted)")
    }

    // MARK: 2026-09-26 — replay bugs that made recorded clicks miss

    /// Posts captured by a test, plus the seams every replay test swaps.
    private final class Posted: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(type: CGEventType, point: CGPoint)] = []
        func add(_ event: CGEvent) {
            lock.lock(); defer { lock.unlock() }
            events.append((event.type, event.location))
        }
        func points(of type: CGEventType) -> [CGPoint] {
            lock.lock(); defer { lock.unlock() }
            return events.filter { $0.type == type }.map(\.point)
        }
    }

    private static func window(pid: Int, number: Int, x: Int, y: Int, layer: Int = 0) -> [String: Any] {
        [kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
         kCGWindowNumber as String: number,
         kCGWindowBounds as String: ["X": x, "Y": y, "Width": 600, "Height": 400]]
    }

    private static func replay(_ plan: MacroPlayer.Plan, windows: [[String: Any]]) -> Posted {
        let posted = Posted()
        let priorPoster = EventSynthesizer.eventPoster
        let priorList = BackgroundPoster.windowListCopy
        let priorPID = BackgroundPoster.pidResolver
        EventSynthesizer.eventPoster = { posted.add($0) }
        BackgroundPoster.windowListCopy = { _ in windows }
        BackgroundPoster.pidResolver = { $0 == "com.example.app" ? 401 : nil }
        defer {
            EventSynthesizer.eventPoster = priorPoster
            BackgroundPoster.windowListCopy = priorList
            BackgroundPoster.pidResolver = priorPID
        }
        let done = DispatchSemaphore(value: 0)
        _ = WorkerThread.start(name: "binding-replay") { worker in
            MacroPlayer.play(plan, worker: worker) { _, _ in }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        return posted
    }

    /// The recorder anchors only the mouseDown (see `anchorForMouseDown`) — so a replay that
    /// translated the down but played the un-anchored up verbatim split every moved-window
    /// click into a DRAG from the new spot back to the old one. The up must land where its
    /// down landed: a click stays a click.
    @Test func aRecordedClickStaysAClickWhenTheWindowMoved() {
        let anchor = WindowAnchor(bundleID: "com.example.app", origin: CGPoint(x: 100, y: 200))
        let plan = MacroPlayer.Plan(events: [
            MacroEvent(time: 0, action: .mouseDown(.left, CGPoint(x: 130, y: 240), clickCount: 1),
                       flags: 0, windowAnchor: anchor),
            // Exactly what the recorder writes: the up carries NO anchor.
            MacroEvent(time: 0.01, action: .mouseUp(.left, CGPoint(x: 130, y: 240), clickCount: 1), flags: 0),
        ], repeats: 1, speed: 1, humanizer: HumanizerSettings(), followWindow: true)
        let posted = Self.replay(plan, windows: [Self.window(pid: 401, number: 7, x: 250, y: 220)])
        #expect(posted.points(of: .leftMouseDown) == [CGPoint(x: 280, y: 260)])
        #expect(posted.points(of: .leftMouseUp) == [CGPoint(x: 280, y: 260)],
                "the up must land where the down did — got \(posted.points(of: .leftMouseUp))")
    }

    /// An app with two windows: the click was recorded in the BACK one, which hasn't moved.
    /// Replay used to measure the delta against the app's FRONT window — shifting every
    /// click by the distance between two unrelated windows. A window still sitting at the
    /// recorded origin means nothing moved: the click plays exactly where it was recorded.
    @Test func replayMeasuresAgainstTheRecordedWindowNotTheFrontOne() {
        let anchor = WindowAnchor(bundleID: "com.example.app", origin: CGPoint(x: 100, y: 200))
        let plan = MacroPlayer.Plan(events: [
            MacroEvent(time: 0, action: .mouseDown(.left, CGPoint(x: 130, y: 240), clickCount: 1),
                       flags: 0, windowAnchor: anchor),
        ], repeats: 1, speed: 1, humanizer: HumanizerSettings(), followWindow: true)
        let posted = Self.replay(plan, windows: [
            Self.window(pid: 401, number: 8, x: 900, y: 500),   // front window, elsewhere
            Self.window(pid: 401, number: 7, x: 100, y: 200),   // the recorded one, unmoved
        ])
        #expect(posted.points(of: .leftMouseDown) == [CGPoint(x: 130, y: 240)],
                "an unmoved recorded window means no shift — got \(posted.points(of: .leftMouseDown))")
    }

    /// A chained macro's steps obey the "Follow the window" toggle like the root's do —
    /// OFF means the recorded point verbatim at every depth.
    @Test func aChainedMacroObeysTheFollowWindowToggle() {
        let anchor = WindowAnchor(bundleID: "com.example.app", origin: CGPoint(x: 100, y: 200))
        let child = Macro(name: "Child", createdAt: Date(), events: [
            MacroEvent(time: 0, action: .mouseDown(.left, CGPoint(x: 130, y: 240), clickCount: 1),
                       flags: 0, windowAnchor: anchor),
        ])
        let childID = UUID()
        let plan = MacroPlayer.Plan(events: [MacroEvent(time: 0, action: .runMacro(childID), flags: 0)],
                                    repeats: 1, speed: 1, humanizer: HumanizerSettings(),
                                    chain: ChainedMacros { $0 == childID ? child : nil },
                                    followWindow: false)
        let posted = Self.replay(plan, windows: [Self.window(pid: 401, number: 7, x: 250, y: 220)])
        #expect(posted.points(of: .leftMouseDown) == [CGPoint(x: 130, y: 240)],
                "toggle off must mean verbatim inside a chain too — got \(posted.points(of: .leftMouseDown))")
    }

    /// The anchor names the app that OWNS the clicked window. At the moment of a mouseDown
    /// the frontmost app is still the PREVIOUS one (the click is what activates the target) —
    /// usually Macro Maker itself right after pressing Record — so the first click of nearly
    /// every recording was bound to the wrong app's window, and moving that window shifted it.
    @Test @MainActor func theAnchorIsTheClickedWindowsOwnerNotTheFrontmostApp() {
        let priorList = BackgroundPoster.windowListCopy
        let priorPID = BackgroundPoster.pidResolver
        let priorBundle = BackgroundPoster.bundleIDResolver
        let priorFront = TargetSnapshot.shared.frontmostBundleIDForTests
        BackgroundPoster.windowListCopy = { _ in [
            Self.window(pid: 999, number: 3, x: 1500, y: 0, layer: 25), // a status-bar surface elsewhere
            Self.window(pid: 402, number: 9, x: 400, y: 300),          // the clicked window (topmost here)
            Self.window(pid: 401, number: 7, x: 100, y: 200),          // the frontmost app's window
        ] }
        BackgroundPoster.pidResolver = { ["com.example.app": 401, "com.example.target": 402][$0] }
        BackgroundPoster.bundleIDResolver = { [401: "com.example.app", 402: "com.example.target"][$0] }
        TargetSnapshot.shared.frontmostBundleIDForTests = "com.example.app"
        defer {
            BackgroundPoster.windowListCopy = priorList
            BackgroundPoster.pidResolver = priorPID
            BackgroundPoster.bundleIDResolver = priorBundle
            TargetSnapshot.shared.frontmostBundleIDForTests = priorFront
        }

        let anchor = MacroRecorder.anchorForMouseDown(at: CGPoint(x: 450, y: 350))
        #expect(anchor == WindowAnchor(bundleID: "com.example.target", origin: CGPoint(x: 400, y: 300)),
                "the window under the click owns the anchor — got \(String(describing: anchor))")
        // A click on a non-app surface (menu bar, Dock: layer ≠ 0) has no window to follow.
        #expect(MacroRecorder.anchorForMouseDown(at: CGPoint(x: 1510, y: 10)) == nil,
                "a click on a system surface plays absolute")
    }
}
