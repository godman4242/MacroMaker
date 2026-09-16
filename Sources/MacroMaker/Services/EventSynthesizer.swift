import CoreGraphics
import Foundation

/// Posts synthetic mouse and keyboard events (requires the Accessibility permission).
/// Thread-safe: called from worker threads.
enum EventSynthesizer {
    /// Stamped into every posted event so the recorder can ignore Macro Maker's own output.
    static let eventTag: Int64 = 0x4D_4143_524F

    static var cursorLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    // MARK: Mouse

    static func postMouse(_ type: CGEventType, button: MouseButton, at point: CGPoint,
                          clickCount: Int = 1, flags: CGEventFlags = []) {
        guard let event = CGEvent(mouseEventSource: makeSource(), mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button.cgButton) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        post(event, flags: flags)
    }

    /// A complete click. `point == nil` clicks wherever the cursor currently is.
    static func click(_ button: MouseButton, at point: CGPoint?, holdFor duration: TimeInterval) {
        click(button, at: point, holdFor: duration, clickCount: 1)
    }

    /// A complete click with a click state (2 = double-click, 3 = triple) like `NSEvent.clickCount`.
    static func click(_ button: MouseButton, at point: CGPoint?, holdFor duration: TimeInterval, clickCount: Int) {
        let location = point ?? cursorLocation
        postMouse(button.downEventType, button: button, at: location, clickCount: clickCount)
        if duration > 0 { Thread.sleep(forTimeInterval: duration) }
        postMouse(button.upEventType, button: button, at: location, clickCount: clickCount)
    }

    // MARK: Keyboard

    /// Posts one key transition. Modifier keys are posted as `flagsChanged`, like real hardware.
    static func postKey(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, isRepeat: Bool = false) {
        guard let event = CGEvent(keyboardEventSource: makeSource(), virtualKey: code, keyDown: down) else { return }
        if KeyCodes.modifierKey(for: code) != nil { event.type = .flagsChanged }
        if isRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        post(event, flags: flags.union(KeyCodes.intrinsicFlags(for: code)))
    }

    /// Presses a stroke's modifiers (in order), then its key.
    static func keyDown(_ stroke: KeyStroke, isRepeat: Bool = false) {
        switch stroke.key {
        case let .code(code):
            if !isRepeat { postModifiers(stroke.modifiers, down: true) }
            let ownFlag = KeyCodes.modifierKey(for: code)?.flag ?? []
            postKey(code, down: true, flags: stroke.modifiers.cgFlags.union(ownFlag), isRepeat: isRepeat)
        case let .text(text):
            postText(text, down: true)
        }
    }

    /// Releases a stroke's key, then its modifiers (in reverse order).
    static func keyUp(_ stroke: KeyStroke) {
        switch stroke.key {
        case let .code(code):
            postKey(code, down: false, flags: stroke.modifiers.cgFlags)
            postModifiers(stroke.modifiers, down: false)
        case let .text(text):
            postText(text, down: false)
        }
    }

    private static func postModifiers(_ modifiers: KeyModifiers, down: Bool) {
        let singles = [KeyModifiers.control, .option, .shift, .command].filter { modifiers.contains($0) }
        var held: KeyModifiers = down ? [] : modifiers
        for modifier in down ? singles : singles.reversed() {
            if down { held.insert(modifier) } else { held.remove(modifier) }
            postKey(modifier.keyCodes[0], down: down, flags: held.cgFlags)
        }
    }

    /// Types a character that isn't on the keyboard layout by attaching it as a Unicode string.
    static func postText(_ text: String, down: Bool, flags: CGEventFlags = []) {
        guard let event = CGEvent(keyboardEventSource: makeSource(), virtualKey: 0, keyDown: down) else { return }
        let utf16 = Array(text.utf16)
        event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        post(event, flags: flags)
    }

    // MARK: Posting

    private static func makeSource() -> CGEventSource? {
        let source = CGEventSource(stateID: .hidSystemState)
        // Don't freeze the user's real mouse/keyboard after each synthetic event (default 0.25 s).
        source?.localEventsSuppressionInterval = 0
        return source
    }

    private static func post(_ event: CGEvent, flags: CGEventFlags) {
        // Explicit flags: otherwise modifiers the user is physically holding (e.g. the ⌃⌥ of the
        // hotkey that started the clicker) leak in and turn a click into a Control-click.
        event.flags = flags.union(.maskNonCoalesced)
        event.setIntegerValueField(.eventSourceUserData, value: eventTag)
        event.post(tap: .cghidEventTap)
    }
}
