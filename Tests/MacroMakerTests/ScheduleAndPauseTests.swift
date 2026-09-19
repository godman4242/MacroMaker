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

    /// Stops that come from outside the feature ("Stop Everything", hold-release, profile
    /// apply, shutdown) must trigger the feature's teardown too — the hook is how a
    /// session stop reaches watchers the state machine can't know about.
    @Test func stoppingAnActiveSessionRunsTheStopHookOnce() {
        let session = RunSession()
        var stops = 0
        session.onStop = { stops += 1 }
        session.start(withCountdown: false) { _ in { } }
        session.stop()
        #expect(stops == 1, "an active session's stop must fire the teardown hook")
        session.stop()
        #expect(stops == 1, "an idle session has nothing to tear down")
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

/// Three rules the v2.0.5 sweep found broken. Key codes are the raw virtual codes:
/// 59 = left Control, 58 = left Option, 56 = left Shift.
@Suite("Hold and schedule rules")
struct HoldAndScheduleRuleTests {
    private static func utc() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    private static let combo = KeyCombo(keyCode: 8, modifiers: [.control, .option])   // ⌃⌥C

    // MARK: C2 — a modifier PRESS was reported as a release

    /// `.flagsChanged` fires on both the press and the release of a modifier. Reading only
    /// "is this modifier part of the combo" meant pressing ⌃ during a ⌃⌥C hold-run stopped it.
    @Test func pressingAModifierDoesNotEndAHold() {
        #expect(!Self.combo.isEndedByFlagsChange(keyCode: 59, modifiersAfter: [.control]),
                "⌃ is still held after the change — that is a press, not a release")
        #expect(!Self.combo.isEndedByFlagsChange(keyCode: 58, modifiersAfter: [.control, .option]))
    }

    @Test func releasingAModifierStillEndsAHold() {
        // ⌃ let go while ⌥ stays down: the control flag is absent afterwards.
        #expect(Self.combo.isEndedByFlagsChange(keyCode: 59, modifiersAfter: [.option]))
        #expect(Self.combo.isEndedByFlagsChange(keyCode: 58, modifiersAfter: [.control]))
        #expect(Self.combo.isEndedByFlagsChange(keyCode: 59, modifiersAfter: []))
    }

    @Test func aModifierOutsideTheComboIsIgnoredEitherWay() {
        #expect(!Self.combo.isEndedByFlagsChange(keyCode: 56, modifiersAfter: []))
        #expect(!Self.combo.isEndedByFlagsChange(keyCode: 56, modifiersAfter: [.shift]))
    }

    // MARK: U4 — an armed schedule disarmed itself on every relaunch

    @Test func aScheduleStillAheadTodaySurvivesARelaunch() {
        let schedule = AppModel.Schedule(enabled: true, seconds: 19 * 3600, feature: .autoClicker)
        let sixPM = Date(timeIntervalSince1970: 1_789_581_600)   // 2026-09-16 18:00 UTC
        #expect(ScheduleRules.staysArmedOnLaunch(schedule, now: sixPM, calendar: Self.utc()),
                "19:00 is still ahead at 18:00 — a relaunch must not silently switch it off")
    }

    @Test func aScheduleWhoseTimeHasPassedIsDisarmed() {
        let schedule = AppModel.Schedule(enabled: true, seconds: 8 * 3600, feature: .autoClicker)
        let tenAM = Date(timeIntervalSince1970: 1_789_552_800)   // 2026-09-16 10:00 UTC
        #expect(!ScheduleRules.staysArmedOnLaunch(schedule, now: tenAM, calendar: Self.utc()),
                "08:00 has gone — re-arming would surprise-fire tomorrow")
    }

    @Test func aDisabledScheduleNeverArms() {
        let schedule = AppModel.Schedule(enabled: false, seconds: 19 * 3600, feature: .autoClicker)
        let sixPM = Date(timeIntervalSince1970: 1_789_581_600)
        #expect(!ScheduleRules.staysArmedOnLaunch(schedule, now: sixPM, calendar: Self.utc()))
    }

    // MARK: U11 — a clock time drifted an hour on DST days

    /// Adding raw seconds to midnight assumes every day is 24 hours. On a spring-forward day it
    /// is 23, so a 07:00 alarm fired at 08:00. 2026-03-29 is the European transition.
    @Test func aClockTimeKeepsItsWallClockHourAcrossDST() {
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        let schedule = AppModel.Schedule(enabled: true, seconds: 7 * 3600, feature: .autoClicker)
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 29
        components.hour = 0; components.minute = 30
        let justAfterMidnight = london.date(from: components)!
        let deadline = ScheduleRules.nextOccurrence(of: schedule, from: justAfterMidnight, calendar: london)!
        #expect(london.component(.hour, from: deadline) == 7,
                "07:00 must stay 07:00 across the transition, got \(london.component(.hour, from: deadline))")
        #expect(london.component(.minute, from: deadline) == 0)
    }
}

/// U6 — a scheduled start that arrives late. A non-repeating `Timer` does not fire while the
/// machine is asleep; the run loop delivers the overdue timer the instant the Mac wakes, so the
/// feature started at whatever moment the user opened the lid rather than at the chosen time.
@Suite("Late schedule fire")
struct LateScheduleFireTests {
    private static let noon = Date(timeIntervalSince1970: 1_789_560_000)

    @Test func afireAtItsDeadlineIsOnTime() {
        #expect(ScheduleRules.isOnTime(deadline: Self.noon, now: Self.noon))
        #expect(ScheduleRules.isOnTime(deadline: Self.noon, now: Self.noon.addingTimeInterval(20)))
    }

    @Test func aFireHoursLateIsRefused() {
        #expect(!ScheduleRules.isOnTime(deadline: Self.noon, now: Self.noon.addingTimeInterval(4 * 3600)),
                "four hours asleep then a start the moment the lid opens is a surprise, not a schedule")
        #expect(!ScheduleRules.isOnTime(deadline: Self.noon, now: Self.noon.addingTimeInterval(600)))
    }

    @Test func anEarlyOrUnknownDeadlineIsAllowed() {
        // Timers can fire a hair early, and a nil deadline means we have nothing to judge against.
        #expect(ScheduleRules.isOnTime(deadline: Self.noon, now: Self.noon.addingTimeInterval(-1)))
        #expect(ScheduleRules.isOnTime(deadline: nil, now: Self.noon))
    }
}
