import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing

@testable import MacroMaker

/// Wave 4 — recorder/player correctness (adversarial review 2026-09-18, findings #1, #6, #7).
/// One serialized suite: these tests swap global seams (`MacroRecorder.tapBuilder`,
/// `EventSynthesizer.eventPoster`) that no other suite must see mid-flight.
@Suite("Recorder/player correctness", .serialized)
struct RecorderPlayerTests {

    // MARK: Finding 1 — recorded offsets follow the event's own timestamp

    /// Two events stamped 0.5 s apart in *event* time, injected back-to-back: the recorded gap
    /// must be the stamps' 0.5 s, not the (near-zero) main-run-loop arrival spacing. The old
    /// code stamped `Date()`-style arrival on main, where the live-event table repaints.
    @Test @MainActor func recordedOffsetsFollowEventStampsNotMainLoopArrival() throws {
        _ = NSApplication.shared   // handle(_:) reads NSApp.isActive; an unactivated accessory
        NSApp.setActivationPolicy(.accessory)   // app is never active, so key events are kept
        let priorTap = MacroRecorder.tapBuilder
        MacroRecorder.tapBuilder = { _, _ in CFMachPortCreate(nil, nil, nil, nil) }
        defer { MacroRecorder.tapBuilder = priorTap }

        let recorder = MacroRecorder()
        #expect(recorder.start(), "start must succeed on the inert tap seam")
        defer { _ = recorder.stop() }

        let base = DispatchTime.now().uptimeNanoseconds
        let stamps: [(keyCode: CGKeyCode, stamp: UInt64)] = [
            (CGKeyCode(kVK_ANSI_A), base &+ 100_000_000),
            (CGKeyCode(kVK_ANSI_S), base &+ 600_000_000),
        ]
        for entry in stamps {
            let cgEvent = try #require(CGEvent(keyboardEventSource: nil, virtualKey: entry.keyCode, keyDown: true))
            cgEvent.timestamp = entry.stamp   // the window server's own clock: ns since startup
            recorder.handle(TapEvent(type: .keyDown, event: cgEvent))
        }

        let times = recorder.liveEvents.map(\.time)
        #expect(times.count == 2, "both injected events must be recorded")
        guard times.count == 2 else { return }
        #expect(abs(times[0] - 0.1) < 0.05,
                "the first offset must follow its stamp (0.1 s after start), got \(times[0])")
        #expect(abs(times[1] - times[0] - 0.5) < 0.05,
                "the gap must be the stamps' 0.5 s, not arrival spacing, got \(times[1] - times[0])")
    }

    // MARK: Finding 6 — a drag replays as recorded, with nothing fabricated

    /// A recording of down…up with movement between (what a real drag records as — the tap
    /// mask has no dragged events) must replay exactly its recorded transitions. The player
    /// used to fabricate a single dragged event at the release point: a jump-click, not a drag.
    @Test func replaysADownUpWithMovementWithoutFabricatingADrag() throws {
        final class PostBox: @unchecked Sendable { var events: [CGEvent] = [] }
        let box = PostBox()
        let priorPoster = EventSynthesizer.eventPoster
        EventSynthesizer.eventPoster = { box.events.append($0) }
        defer { EventSynthesizer.eventPoster = priorPoster }

        let downPoint = CGPoint(x: 100, y: 100)
        let upPoint = CGPoint(x: 300, y: 220)
        let plan = MacroPlayer.Plan(events: [
            MacroEvent(time: 0, action: .mouseDown(.left, downPoint, clickCount: 1), flags: 0),
            MacroEvent(time: 0.05, action: .mouseUp(.left, upPoint, clickCount: 1), flags: 0),
        ], repeats: 1, speed: 1, humanizer: HumanizerSettings())

        let done = DispatchSemaphore(value: 0)
        _ = WorkerThread.start(name: "w4-faithful-drag") { worker in
            MacroPlayer.play(plan, worker: worker) { _, _ in }
            done.signal()
        }
        let settled = done.wait(timeout: .now() + 5) == .success
        #expect(settled, "playback must finish on its own")
        guard settled else { return }

        let types = box.events.map(\.type)
        #expect(types == [.mouseMoved, .leftMouseDown, .leftMouseUp],
                "replay must post the aim-move, the recorded down, then the recorded up — nothing else, got \(types)")
    }

    // MARK: Finding 7 — a cancelled run is not a finished one

    /// Every exit path used to fall through to `report(progress, true)`, so a cancelled run
    /// claimed natural completion — the exact reporting lie AutoClicker had to patch (Wave 1).
    @Test func aCancelledPlaybackReportsNotFinished() {
        let plan = MacroPlayer.Plan(events: [
            MacroEvent(time: 5, action: .keyDown(CGKeyCode(kVK_ANSI_A), isRepeat: false), flags: 0),
        ], repeats: 1, speed: 1, humanizer: HumanizerSettings())

        final class ReportBox: @unchecked Sendable { var finished: [Bool] = [] }
        let box = ReportBox()
        let worker = WorkerThread.start(name: "w4-cancel") { worker in
            MacroPlayer.play(plan, worker: worker) { _, finished in box.finished.append(finished) }
        }
        worker.cancelAndWait()

        #expect(box.finished.last == false,
                "a cancelled run's final report must say finished: false, got \(box.finished)")
    }

    // MARK: Wave 6 N8 — the unstamped-event arrival fallback

    /// An event whose stamp is 0 (the window server didn't stamp it) falls back to arrival
    /// time. The branch is one line and was never exercised; the assertion is only that it
    /// produces a sane, non-negative offset rather than trapping or going backwards.
    @Test @MainActor func anUnstampedEventFallsBackToArrivalTime() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let priorTap = MacroRecorder.tapBuilder
        MacroRecorder.tapBuilder = { _, _ in CFMachPortCreate(nil, nil, nil, nil) }
        defer { MacroRecorder.tapBuilder = priorTap }

        let recorder = MacroRecorder()
        #expect(recorder.start(), "start must succeed on the inert tap seam")
        defer { _ = recorder.stop() }

        let cgEvent = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_A), keyDown: true))
        cgEvent.timestamp = 0   // unstamped: the recorder must fall back to arrival time
        recorder.handle(TapEvent(type: .keyDown, event: cgEvent))

        let times = recorder.liveEvents.map(\.time)
        #expect(times.count == 1, "the unstamped event must still be recorded")
        guard times.count == 1 else { return }
        #expect(times[0] >= 0 && times[0] < 5,
                "an unstamped event records an arrival-time offset, got \(times[0])")
    }
}