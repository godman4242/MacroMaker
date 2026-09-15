import Carbon.HIToolbox
import Testing
@testable import MacroMaker

@Suite struct TickScheduleTests {
    @Test func deadlinesDoNotDrift() {
        #expect(TickSchedule.nextDeadline(previous: 0, delay: 100, now: 30) == 100)
        // Slightly late: keep the grid (fires immediately, then back on schedule).
        #expect(TickSchedule.nextDeadline(previous: 0, delay: 100, now: 150) == 100)
    }

    @Test func resyncsInsteadOfBurstingAfterAStall() {
        #expect(TickSchedule.nextDeadline(previous: 0, delay: 100, now: 1_000) == 1_000)
    }

    @Test func jitterNeverGoesBelowTheMinimum() {
        // Values exactly representable in binary, so == is safe.
        #expect(TickSchedule.delay(interval: 0.5, jitter: 0.25, random: 1) == 0.75)
        #expect(TickSchedule.delay(interval: 0.5, jitter: 0.25, random: -1) == 0.25)
        #expect(TickSchedule.delay(interval: 0.005, jitter: 0.5, random: -1) == TickSchedule.minimumDelay)
    }

    @Test func pressDurationIsCapped() {
        #expect(TickSchedule.pressDuration(interval: 1) == 0.010)
        #expect(TickSchedule.pressDuration(interval: 0.004) == 0.001)
    }
}

@Suite struct KeyCodesTests {
    @Test func modifierDirectionUsesLeftRightBits() {
        let leftShiftDown: UInt64 = CGEventFlags.maskShift.rawValue | 0x02
        #expect(KeyCodes.isModifierDown(code: CGKeyCode(kVK_Shift), flags: leftShiftDown))
        // Releasing left Shift while right Shift is still held: Shift flag remains, but left bit is gone.
        let onlyRightShift: UInt64 = CGEventFlags.maskShift.rawValue | 0x04
        #expect(!KeyCodes.isModifierDown(code: CGKeyCode(kVK_Shift), flags: onlyRightShift))
        #expect(KeyCodes.isModifierDown(code: CGKeyCode(kVK_RightShift), flags: onlyRightShift))
        // Without device bits (synthetic input), fall back to the generic flag.
        #expect(KeyCodes.isModifierDown(code: CGKeyCode(kVK_Command), flags: CGEventFlags.maskCommand.rawValue))
        #expect(!KeyCodes.isModifierDown(code: CGKeyCode(kVK_Command), flags: 0))
    }

    @Test func capsLockIsNotTreatedAsAHeldModifier() {
        #expect(KeyCodes.modifierKey(for: CGKeyCode(kVK_CapsLock)) == nil)
    }

    @Test func intrinsicFlagsMatchHardware() {
        #expect(KeyCodes.intrinsicFlags(for: CGKeyCode(kVK_UpArrow)) == [.maskSecondaryFn, .maskNumericPad])
        #expect(KeyCodes.intrinsicFlags(for: CGKeyCode(kVK_F5)) == .maskSecondaryFn)
        #expect(KeyCodes.intrinsicFlags(for: CGKeyCode(kVK_ANSI_A)) == [])
    }

    @Test func carbonAndEventFlagsAgree() {
        let modifiers: KeyModifiers = [.control, .option, .shift, .command]
        #expect(modifiers.carbonFlags == UInt32(controlKey | optionKey | shiftKey | cmdKey))
        #expect(modifiers.cgFlags == [.maskControl, .maskAlternate, .maskShift, .maskCommand])
        #expect(modifiers.symbols == "⌃⌥⇧⌘")
    }
}
