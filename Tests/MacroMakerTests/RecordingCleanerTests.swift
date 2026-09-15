import Carbon.HIToolbox
import Testing
@testable import MacroMaker

@Suite struct RecordingCleanerTests {
    private let control = CGKeyCode(kVK_Control)
    private let option = CGKeyCode(kVK_Option)
    private let keyR = CGKeyCode(kVK_ANSI_R)
    private let keyA = CGKeyCode(kVK_ANSI_A)

    private func event(_ time: Double, _ action: MacroEvent.Action) -> MacroEvent {
        MacroEvent(time: time, action: action, flags: 0)
    }

    @Test func removesStartAndStopShortcutArtifacts() {
        let point = CGPoint(x: 5, y: 5)
        let raw = [
            // Releasing ⌃⌥R that started the recording.
            event(0.1, .keyUp(keyR)), event(0.15, .keyUp(option)), event(0.2, .keyUp(control)),
            // The actual macro.
            event(2.0, .mouseDown(.left, point, clickCount: 1)), event(2.5, .mouseUp(.left, point, clickCount: 1)),
            event(3.0, .keyDown(keyA, isRepeat: false)), event(3.5, .keyUp(keyA)),
            // Pressing ⌃⌥R to stop it.
            event(5.0, .keyDown(control, isRepeat: false)), event(5.1, .keyDown(option, isRepeat: false)),
            event(5.2, .keyDown(keyR, isRepeat: false)),
        ]
        let cleaned = RecordingCleaner.clean(raw)
        #expect(cleaned.map(\.action) == [
            .mouseDown(.left, point, clickCount: 1), .mouseUp(.left, point, clickCount: 1),
            .keyDown(keyA, isRepeat: false), .keyUp(keyA),
        ])
        #expect(cleaned.map(\.time) == [0, 0.5, 1.0, 1.5], "rebased so the first event is at 0")
    }

    @Test func keepsHeldKeyThatIsNotAtTheEnd() {
        // Shift held across a click: not trailing, so it stays (the player releases it at the end).
        let raw = [
            event(1, .keyDown(CGKeyCode(kVK_Shift), isRepeat: false)),
            event(2, .mouseDown(.left, .zero, clickCount: 1)),
            event(3, .mouseUp(.left, .zero, clickCount: 1)),
        ]
        #expect(RecordingCleaner.clean(raw).count == 3)
    }

    @Test func dropsOrphanMouseUp() {
        let raw = [event(1, .mouseUp(.right, .zero, clickCount: 1)), event(2, .keyDown(keyA, isRepeat: false)), event(3, .keyUp(keyA))]
        #expect(RecordingCleaner.clean(raw).map(\.action) == [.keyDown(keyA, isRepeat: false), .keyUp(keyA)])
    }

    @Test func emptyAndStopOnlyRecordingsBecomeEmpty() {
        #expect(RecordingCleaner.clean([]).isEmpty)
        #expect(RecordingCleaner.clean([event(1, .keyDown(control, isRepeat: false)), event(1.1, .keyDown(keyR, isRepeat: false))]).isEmpty)
    }
}
