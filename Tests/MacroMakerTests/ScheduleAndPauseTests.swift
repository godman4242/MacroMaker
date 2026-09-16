import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import MacroMaker

@Suite("ScheduleRules")
struct ScheduleRulesTests {
    private static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-09-16 10:00:00 UTC.
    private static let tenAM = Date(timeIntervalSince1970: 1_789_552_800)

    @Test func parsesClockTimes() {
        #expect(ScheduleRules.parseClock("7:30") == 27_000)
        #expect(ScheduleRules.parseClock("18:05") == 65_100)
        #expect(ScheduleRules.parseClock("0:00") == 0)
        #expect(ScheduleRules.parseClock("23:59") == 86_340)
    }

    @Test func rejectsMalformedClockText() {
        #expect(ScheduleRules.parseClock("") == nil)
        #expect(ScheduleRules.parseClock("7") == nil)
        #expect(ScheduleRules.parseClock("7:30:15") == nil)
        #expect(ScheduleRules.parseClock("25:00") == nil)
        #expect(ScheduleRules.parseClock("10:60") == nil)
        #expect(ScheduleRules.parseClock("ten o'clock") == nil)
        #expect(ScheduleRules.parseClock("7:-1") == nil)
    }

    @Test func formatsClockTimesBack() {
        #expect(ScheduleRules.clockString(seconds: 7 * 3600 + 1800) == "7:30")
        #expect(ScheduleRules.clockString(seconds: 0) == "0:00")
        #expect(ScheduleRules.clockString(seconds: 23 * 3600 + 59 * 60) == "23:59")
        // Out-of-day values clamp into the day rather than print nonsense.
        #expect(ScheduleRules.clockString(seconds: 24 * 3600 + 5) == "23:59")
        #expect(ScheduleRules.clockString(seconds: -10) == "0:00")
    }

    @Test func tenAMConstantIsActuallyTenAMUTC() {
        // Guard the fixture itself — the tests below only mean anything if tenAM is 10:00 UTC.
        #expect(Self.calendar().component(.hour, from: Self.tenAM) == 10)
        #expect(Self.calendar().component(.minute, from: Self.tenAM) == 0)
    }

    @Test func disabledScheduleHasNoDeadline() {
        let schedule = AppModel.Schedule(enabled: false, seconds: 12 * 3600, feature: .autoClicker)
        #expect(ScheduleRules.nextOccurrence(of: schedule, from: Self.tenAM, calendar: Self.calendar()) == nil)
    }

    @Test func upcomingTimeSchedulesToday() {
        let calendar = Self.calendar()
        let schedule = AppModel.Schedule(enabled: true, seconds: 12 * 3600, feature: .autoClicker)
        let deadline = ScheduleRules.nextOccurrence(of: schedule, from: Self.tenAM, calendar: calendar)
        #expect(deadline == calendar.startOfDay(for: Self.tenAM).addingTimeInterval(12 * 3600))
    }

    @Test func passedTimeSchedulesTomorrow() {
        let calendar = Self.calendar()
        let schedule = AppModel.Schedule(enabled: true, seconds: 8 * 3600, feature: .webTarget)
        let deadline = ScheduleRules.nextOccurrence(of: schedule, from: Self.tenAM, calendar: calendar)
        let expected = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Self.tenAM))!
            .addingTimeInterval(8 * 3600)
        #expect(deadline == expected)
    }

    @Test func exactNowGoesToTomorrow() {
        let calendar = Self.calendar()
        let schedule = AppModel.Schedule(enabled: true, seconds: 10 * 3600, feature: .keyPresser)
        let deadline = ScheduleRules.nextOccurrence(of: schedule, from: Self.tenAM, calendar: calendar)
        // "At exactly the configured second" isn't a future occurrence — next day wins.
        #expect(deadline == calendar.startOfDay(for: Self.tenAM).addingTimeInterval(24 * 3600 + 10 * 3600))
    }

    @Test func describesDeadlinesAtHumanScale() {
        let now = Self.tenAM
        #expect(ScheduleRules.describe(deadline: now.addingTimeInterval(45), from: now) == "in 46 s")
        #expect(ScheduleRules.describe(deadline: now.addingTimeInterval(300), from: now) == "in 5 min")
        #expect(ScheduleRules.describe(deadline: now.addingTimeInterval(5400), from: now) == "in 1 h 30 min")
        #expect(ScheduleRules.describe(deadline: now.addingTimeInterval(86_400 * 3), from: now) == "in 3 d")
        #expect(ScheduleRules.describe(deadline: now, from: now) == "now")
    }
}

@Suite("RunSession pause")
@MainActor
struct RunSessionPauseTests {
    @Test func pauseMovesRunningToPaused() {
        let session = RunSession()
        session.start(withCountdown: false) { _ in { } }
        #expect(session.phase == .running)
        session.pause()
        #expect(session.phase == .paused)
        #expect(session.isPaused)
    }

    @Test func pauseIsIgnoredOutsideRunning() {
        let session = RunSession()
        session.pause()
        #expect(session.phase == .idle)
    }

    @Test func startFromPausedResumesWithoutCountdown() {
        let session = RunSession()
        var runs = 0
        session.start(withCountdown: false) { _ in runs += 1; return { } }
        session.pause()
        session.start(withCountdown: false) { _ in runs += 1; return { } }
        #expect(runs == 2)
        #expect(session.phase == .running)
    }

    @Test func countdownCannotStartWhilePaused() {
        let session = RunSession()
        session.start(withCountdown: false) { _ in { } }
        session.pause()
        session.start(withCountdown: true) { _ in Issue.record("countdown begin shouldn't run"); return nil }
        #expect(session.phase == .paused)
    }
}

@Suite("Real-input rules")
struct RealInputRulesTests {
    @Test func mouseEventsRespectTheSelfTag() {
        // isReal consults the raw CGEvent, where the tag lives — the same check the recorder does.
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                  mouseCursorPosition: .zero, mouseButton: .left),
              let nsEvent = NSEvent(cgEvent: event)
        else { Issue.record("event creation failed"); return }
        #expect(RealInputRules.isReal(nsEvent))
        // Events built *and posted* through the synthesizer carry the tag in the tap stream; here
        // we set it by hand — Global monitors would see exactly this.
        event.setIntegerValueField(.eventSourceUserData, value: EventSynthesizer.eventTag)
        guard let tagged = NSEvent(cgEvent: event) else { Issue.record("event creation failed"); return }
        #expect(!RealInputRules.isReal(tagged))
    }

    @Test func idleDeadlineMatchesElapsedTime() {
        // Auto resume waits the configured quiet seconds before restarting.
        let lastInput = Date(timeIntervalSinceNow: -10)
        #expect(RealInputRules.idleEnough(lastInputAt: lastInput, afterSeconds: 5, now: Date()))
        #expect(!RealInputRules.idleEnough(lastInputAt: lastInput, afterSeconds: 30, now: Date()))
        // Never any input → idle.
        #expect(RealInputRules.idleEnough(lastInputAt: .distantPast, afterSeconds: 5, now: Date()))
    }
}
