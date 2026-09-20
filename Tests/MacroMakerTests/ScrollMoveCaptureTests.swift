import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import MacroMaker

/// Wave 7, feature 2 — scroll and throttled cursor-move capture (features.json F-13).
/// The recorder's tap gains `.scrollWheel` and `.mouseMoved`; scrolls record as new
/// `.scroll` steps (point + pixel deltas), moves as `.move` steps throttled to one per
/// 100 ms (only the last move before a click aims it — the player aims every click
/// anyway, so the pixel path between is noise). The file format becomes version 2,
/// and every version-1 file must keep opening unchanged.
@Suite("Scroll and cursor-move capture", .serialized)
struct ScrollMoveCaptureTests {

    // MARK: File format version 2

    /// New step kinds round-trip through the file, and the file says version 2.
    @Test func scrollAndMoveStepsRoundTripAsFormatVersionTwo() throws {
        let macro = Macro(
            name: "ScrollMove",
            createdAt: Date(timeIntervalSince1970: 1_789_000_000),
            events: [
                MacroEvent(time: 0, action: .move(CGPoint(x: 100, y: 150)), flags: 0),
                MacroEvent(time: 0.2, action: .scroll(CGPoint(x: 100, y: 150), dx: 3, dy: -24), flags: 256),
            ]
        )
        let data = try macro.jsonData()
        #expect(try Macro(jsonData: data) == macro, "scroll/move steps must survive save + open")

        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["version"] as? Int) == 2, "new steps need format version 2")
    }

    /// A pinned version-2 file with scroll/move steps decodes (fields: x/y = point,
    /// dx/dy = pixel deltas).
    @Test func aPinnedVersionTwoFileWithScrollAndMoveStepsDecodes() throws {
        let json = """
        { "format": "macromaker", "version": 2, "name": "Pinned", "createdAt": "2026-09-16T10:00:00Z",
          "events": [
            { "t": 0,   "type": "move",   "x": 100, "y": 150, "flags": 0 },
            { "t": 0.2, "type": "scroll", "x": 100, "y": 150, "dx": 3, "dy": -24, "flags": 256 }
          ] }
        """
        let macro = try Macro(jsonData: Data(json.utf8))
        #expect(macro.events.map(\.action) == [
            .move(CGPoint(x: 100, y: 150)),
            .scroll(CGPoint(x: 100, y: 150), dx: 3, dy: -24),
        ])
        #expect(macro.events[1].flags == 256)
    }

    /// The version-1 guard still accepts 1 and still rejects a future version.
    @Test func versionOneIsAcceptedAndVersionThreeIsNot() throws {
        let v1 = #"{ "format": "macromaker", "version": 1, "name": "x", "createdAt": "2026-09-16T10:00:00Z", "events": [] }"#
        #expect(try Macro(jsonData: Data(v1.utf8)).name == "x", "v1 files must keep opening")
        let v3 = #"{ "format": "macromaker", "version": 3, "name": "x", "createdAt": "2026-09-16T10:00:00Z", "events": [] }"#
        #expect(throws: DecodingError.self) { try Macro(jsonData: Data(v3.utf8)) }
    }

    // MARK: Recording — scroll

    /// A scroll-wheel tap event records one `.scroll` step carrying the cursor point and
    /// BOTH pixel deltas — and scrolls are not throttled (two 10 ms apart both record).
    @Test @MainActor func scrollWheelEventsRecordTheirPointAndDeltas() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let priorTap = MacroRecorder.tapBuilder
        MacroRecorder.tapBuilder = { _, _ in CFMachPortCreate(nil, nil, nil, nil) }
        defer { MacroRecorder.tapBuilder = priorTap }

        let recorder = MacroRecorder()
        #expect(recorder.start(), "start must succeed on the inert tap seam")
        defer { _ = recorder.stop() }

        let base = DispatchTime.now().uptimeNanoseconds
        for (offset, dy, dx) in [(UInt64(100_000_000), -24, 3), (UInt64(110_000_000), -6, 0)] {
            let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                               wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0))
            cgEvent.timestamp = base &+ offset
            recorder.handle(TapEvent(type: .scrollWheel, event: cgEvent))
        }

        let actions = recorder.liveEvents.map(\.action)
        #expect(actions.count == 2, "both scrolls record — scrolls are not throttled, got \(actions)")
        guard actions.count == 2,
              case let .scroll(point0, dx0, dy0) = actions[0],
              case let .scroll(_, dx1, dy1) = actions[1]
        else { return }
        #expect(dx0 == 3 && dy0 == -24, "the first scroll's deltas must round-trip, got dx \(dx0) dy \(dy0)")
        #expect(dx1 == 0 && dy1 == -6, "the second scroll's deltas must round-trip, got dx \(dx1) dy \(dy1)")
        #expect(point0.x > 0 && point0.y > 0, "the scroll's cursor point is recorded (the probe showed a real location)")
    }

    // MARK: Recording — throttled moves

    /// The pure rule: a move records only ≥100 ms after the previous RECORDED move —
    /// the first move must clear 100 ms since recording started.
    @Test func theMoveThrottleRule() {
        let spacing = UInt64(100_000_000)
        #expect(!MacroRecorder.shouldRecordMove(lastRecordedAt: 0, proposedAt: spacing - 1))
        #expect(MacroRecorder.shouldRecordMove(lastRecordedAt: 0, proposedAt: spacing))
        #expect(!MacroRecorder.shouldRecordMove(lastRecordedAt: spacing, proposedAt: spacing + 50_000_000))
        #expect(MacroRecorder.shouldRecordMove(lastRecordedAt: spacing, proposedAt: spacing + 100_000_000))
    }

    /// Injected moves follow the throttle: a burst at 0/50/120/170/1000 ms past start
    /// records exactly the two that clear a 100 ms gap since the previous RECORDED move.
    @Test @MainActor func aMoveBurstRecordsOnlyTheStepsThatClearTheThrottle() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let priorTap = MacroRecorder.tapBuilder
        MacroRecorder.tapBuilder = { _, _ in CFMachPortCreate(nil, nil, nil, nil) }
        defer { MacroRecorder.tapBuilder = priorTap }

        let recorder = MacroRecorder()
        #expect(recorder.start(), "start must succeed on the inert tap seam")
        defer { _ = recorder.stop() }

        let base = DispatchTime.now().uptimeNanoseconds
        let offsets: [UInt64] = [0, 50_000_000, 120_000_000, 170_000_000, 1_000_000_000]
        for (i, offset) in offsets.enumerated() {
            let point = CGPoint(x: 10 + i, y: 20)
            let cgEvent = try #require(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                               mouseCursorPosition: point, mouseButton: .left))
            cgEvent.timestamp = base &+ offset
            recorder.handle(TapEvent(type: .mouseMoved, event: cgEvent))
        }

        let moves = recorder.liveEvents.filter { if case .move = $0.action { return true }; return false }
        #expect(moves.count == 2, "only the 120 ms and 1000 ms moves clear the throttle, got \(moves.count)")
        guard moves.count == 2 else { return }
        #expect(abs(moves[0].time - 0.12) < 0.05, "the first recorded move is the 120 ms one, got \(moves[0].time)")
        #expect(abs(moves[1].time - 1.0) < 0.05, "the second recorded move is the 1000 ms one, got \(moves[1].time)")
    }

    // MARK: Recording clean-up

    /// Scrolls and moves hold nothing down: they survive the cleaner, a trailing one is
    /// not stripped as "still held", and an orphan scroll before an unmatched mouseUp stays.
    @Test func theCleanerKeepsScrollsAndMoves() {
        let scroll = MacroEvent(time: 0, action: .scroll(CGPoint(x: 1, y: 2), dx: 0, dy: -10), flags: 0)
        let move = MacroEvent(time: 0.05, action: .move(CGPoint(x: 3, y: 4)), flags: 0)
        let heldDown = MacroEvent(time: 0.1, action: .keyDown(0, isRepeat: false), flags: 0)
        let orphanUp = MacroEvent(time: 0.15, action: .mouseUp(.left, CGPoint(x: 5, y: 6), clickCount: 1), flags: 0)

        let cleaned = RecordingCleaner.clean([scroll, move, heldDown])
        #expect(cleaned.map(\.action) == [scroll.action, move.action],
                "the trailing held key is stripped, the scroll and move stay")

        let cleanedOrphan = RecordingCleaner.clean([scroll, orphanUp])
        #expect(cleanedOrphan.map(\.action) == [scroll.action],
                "the orphan up is dropped, the scroll before it stays")
    }

    // MARK: Playback

    /// A recorded move + scroll replays as a real `mouseMoved` and a real `scrollWheel`
    /// carrying the same point and pixel deltas — before the click they aimed.
    @Test func playbackReplaysScrollAndMoveSteps() throws {
        final class PostBox: @unchecked Sendable { var events: [CGEvent] = [] }
        let box = PostBox()
        let priorPoster = EventSynthesizer.eventPoster
        EventSynthesizer.eventPoster = { box.events.append($0) }
        defer { EventSynthesizer.eventPoster = priorPoster }

        let point = CGPoint(x: 100, y: 150)
        let plan = MacroPlayer.Plan(events: [
            MacroEvent(time: 0, action: .move(point), flags: 0),
            MacroEvent(time: 0.01, action: .scroll(point, dx: 3, dy: -24), flags: 0),
            MacroEvent(time: 0.02, action: .mouseDown(.left, point, clickCount: 1), flags: 0),
        ], repeats: 1, speed: 1, humanizer: HumanizerSettings())

        let done = DispatchSemaphore(value: 0)
        _ = WorkerThread.start(name: "w7-scroll-replay") { worker in
            MacroPlayer.play(plan, worker: worker) { _, _ in }
            done.signal()
        }
        let settled = done.wait(timeout: .now() + 5) == .success
        #expect(settled, "playback must finish on its own")
        guard settled else { return }

        let types = box.events.map(\.type)
        // The trailing leftMouseUp is the pass-end release() — the plan holds the button down
        // (down with no up), and the run's teardown guarantees nothing stays pressed.
        #expect(types == [.mouseMoved, .scrollWheel, .mouseMoved, .leftMouseDown, .leftMouseUp],
                "replay posts the recorded move, the scroll, the click's aim + down, then the pass-end release, got raw \(box.events.map { $0.type.rawValue })")
        guard let scrollEvent = box.events.first(where: { $0.type == .scrollWheel }) else { return }
        #expect(scrollEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -24,
                "the vertical pixel delta must round-trip")
        #expect(scrollEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 3,
                "the horizontal pixel delta must round-trip")
        #expect(scrollEvent.location == point, "the scroll replays at the recorded point, got \(scrollEvent.location)")
    }
}