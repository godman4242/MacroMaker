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

    /// A mouseDown during recording carries the frontmost app's bundle id and its window's
    /// origin; key steps and scrolls don't pay for one (their points aren't replay targets
    /// of the binding — a scroll replays where the cursor is, and a key doesn't aim).
    @Test @MainActor func aMouseDownRecordsTheFrontmostAppAndWindowOrigin() throws {
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
        defer {
            MacroRecorder.tapBuilder = priorTap
            BackgroundPoster.windowListCopy = priorList
            TargetSnapshot.shared.frontmostBundleIDForTests = priorFront
            BackgroundPoster.pidResolver = priorPID
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
        #expect(anchor.bundleID == "com.example.app", "the frontmost app is captured")
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
}