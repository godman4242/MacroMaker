import CoreGraphics
import Foundation

/// Posts synthetic mouse and keyboard events (requires the Accessibility permission).
/// Thread-safe: called from worker threads.
enum EventSynthesizer {
    /// Stamped into every posted event so the recorder can ignore Macro Maker's own output.
    /// Per-launch and random (never zero) so another tool's synthetic events can't mimic the tag
    /// with a hardcoded constant.
    static let eventTag: Int64 = {
        var rng = SystemRandomNumberGenerator()
        let tag = Int64.random(in: 1...Int64.max, using: &rng)
        return tag == 0 ? 1 : tag
    }()

    /// Where the cursor position is read from. The default reads the live hardware cursor;
    /// tests pin it, so restore-cursor behavior is deterministic — the shipped restore test
    /// read the REAL cursor and went red whenever the machine's mouse moved during the suite.
    nonisolated(unsafe) static var cursorLocationReader: @Sendable () -> CGPoint = {
        CGEvent(source: nil)?.location ?? .zero
    }

    static var cursorLocation: CGPoint {
        cursorLocationReader()
    }

    /// Where synthesized events go. The default posts to the HID tap (the real cursor, the
    /// frontmost app); tests capture instead, so playback never touches the user's machine.
    nonisolated(unsafe) static var eventPoster: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }

    /// CGEvent creation seam: `CGEvent(mouseEventSource:...)` is documented to be able to
    /// return nil, and that failure is invisible to tests against the real constructor.
    /// Tests swap this to make creation fail, so the click paths' "event couldn't be built"
    /// branches are reachable (the same shape as `BackgroundPoster.nsMouseEventBuilder`).
    nonisolated(unsafe) static var mouseBuilder:
        @Sendable (_ source: CGEventSource?, _ type: CGEventType, _ point: CGPoint,
                   _ button: CGMouseButton) -> CGEvent? = { source, type, point, button in
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
    }

    /// One event source reused for a whole run: `CGEventSource(stateID:)` is a real allocation,
    /// and making one per posted event costs a round-trip at click rates. The suppression
    /// interval is written on it at checkout, keeping `localEventsSuppressionInterval = 0`
    /// behavior identical to the per-event source.
    final class EventSource: @unchecked Sendable {
        /// The raw CGEventSource, for the one call that wants it directly (scroll events).
        let source = CGEventSource(stateID: .hidSystemState)
        var underlying: CGEventSource? { source }

        init() {
            // Don't freeze the user's real mouse/keyboard after each synthetic event (default 0.25 s).
            source?.localEventsSuppressionInterval = 0
        }

        func mouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) -> CGEvent? {
            EventSynthesizer.mouseBuilder(source, type, point, button)
        }

        func key(_ code: CGKeyCode, down: Bool) -> CGEvent? {
            CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        }
    }

    // MARK: Mouse

    /// Posts one mouse transition. False when the event couldn't be built — the caller then
    /// knows nothing was posted (a half-delivered down/up pair is worth reporting, not hiding).
    @discardableResult
    static func postMouse(_ type: CGEventType, button: MouseButton, at point: CGPoint,
                          clickCount: Int = 1, flags: CGEventFlags = [],
                          source: EventSource = EventSource()) -> Bool {
        guard let event = source.mouse(type, at: point, button: button.cgButton) else { return false }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        post(event, flags: flags)
        return true
    }

    /// A complete click. `point == nil` clicks wherever the cursor currently is.
    @discardableResult
    static func click(_ button: MouseButton, at point: CGPoint?, holdFor duration: TimeInterval) -> Bool {
        click(button, at: point, holdFor: duration, clickCount: 1)
    }

    /// A complete click with a click state (2 = double-click, 3 = triple) like `NSEvent.clickCount`.
    /// False when either half couldn't be built — the caller must not count that click as
    /// delivered. (A failed down leaves nothing held; a failed up can leave a synthetic
    /// button-down dangling in HID state — the next down/up pair or a real click clears it.)
    @discardableResult
    static func click(_ button: MouseButton, at point: CGPoint?, holdFor duration: TimeInterval,
                      clickCount: Int, source: EventSource = EventSource()) -> Bool {
        let location = point ?? cursorLocation
        guard postMouse(button.downEventType, button: button, at: location, clickCount: clickCount,
                        source: source) else { return false }
        if duration > 0 { Thread.sleep(forTimeInterval: duration) }
        return postMouse(button.upEventType, button: button, at: location, clickCount: clickCount,
                         source: source)
    }

    /// Posts one scroll-wheel notch with pixel deltas (negative `dy` = the natural down
    /// direction, matching what the recorder read off the same fields).
    static func postScroll(dx: Int, dy: Int, at point: CGPoint,
                           flags: CGEventFlags = [], source: EventSource = EventSource()) {
        // 0 deltas post nothing: an all-zero scroll event is a wheel wiggle with no content.
        guard dx != 0 || dy != 0,
              let event = CGEvent(scrollWheelEvent2Source: source.underlying,
                                  units: .pixel, wheelCount: 2,
                                  wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)
        else { return }
        event.location = point
        // The PointDelta fields carry integer pixels; the FixedPt fields (16.16 fixed-point)
        // are what fractional-scroll consumers (NSScrollWheel delta*, Chromium) read. Stamp
        // both: a recorded -1 px replay scrolls -1 in every reader, not just integer ones.
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1,
                                   value: Int64(dy) << 16)
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2,
                                   value: Int64(dx) << 16)
        post(event, flags: flags)
    }

    // MARK: Keyboard

    /// Posts one key transition. Modifier keys are posted as `flagsChanged`, like real hardware.
    static func postKey(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, isRepeat: Bool = false) {
        postKey(code, down: down, flags: flags, isRepeat: isRepeat, source: EventSource())
    }

    static func postKey(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, isRepeat: Bool = false,
                        source: EventSource) {
        guard let event = source.key(code, down: down) else { return }
        if KeyCodes.modifierKey(for: code) != nil { event.type = .flagsChanged }
        if isRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        post(event, flags: flags.union(KeyCodes.intrinsicFlags(for: code)))
    }

    /// Presses a stroke's modifiers (in order), then its key.
    static func keyDown(_ stroke: KeyStroke, isRepeat: Bool = false) {
        keyDown(stroke, isRepeat: isRepeat, source: EventSource())
    }

    static func keyDown(_ stroke: KeyStroke, isRepeat: Bool, source: EventSource) {
        switch stroke.key {
        case let .code(code):
            if !isRepeat { postModifiers(stroke.modifiers, down: true, source: source) }
            let ownFlag = KeyCodes.modifierKey(for: code)?.flag ?? []
            postKey(code, down: true, flags: stroke.modifiers.cgFlags.union(ownFlag), isRepeat: isRepeat, source: source)
        case let .text(text):
            postText(text, down: true, source: source)
        }
    }

    /// Releases a stroke's key, then its modifiers (in reverse order).
    static func keyUp(_ stroke: KeyStroke) {
        keyUp(stroke, source: EventSource())
    }

    static func keyUp(_ stroke: KeyStroke, source: EventSource) {
        switch stroke.key {
        case let .code(code):
            postKey(code, down: false, flags: stroke.modifiers.cgFlags, source: source)
            postModifiers(stroke.modifiers, down: false, source: source)
        case let .text(text):
            postText(text, down: false, source: source)
        }
    }

    private static func postModifiers(_ modifiers: KeyModifiers, down: Bool, source: EventSource) {
        let singles = [KeyModifiers.control, .option, .shift, .command].filter { modifiers.contains($0) }
        var held: KeyModifiers = down ? [] : modifiers
        for modifier in down ? singles : singles.reversed() {
            if down { held.insert(modifier) } else { held.remove(modifier) }
            postKey(modifier.keyCodes[0], down: down, flags: held.cgFlags, source: source)
        }
    }

    /// Types a character that isn't on the keyboard layout by attaching it as a Unicode string.
    static func postText(_ text: String, down: Bool, flags: CGEventFlags = []) {
        postText(text, down: down, flags: flags, source: EventSource())
    }

    static func postText(_ text: String, down: Bool, flags: CGEventFlags = [], source: EventSource) {
        guard let event = source.key(0, down: down) else { return }
        let utf16 = Array(text.utf16)
        event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        post(event, flags: flags)
    }

    // MARK: Posting

    private static func post(_ event: CGEvent, flags: CGEventFlags) {
        // Explicit flags: otherwise modifiers the user is physically holding (e.g. the ⌃⌥ of the
        // hotkey that started the clicker) leak in and turn a click into a Control-click.
        event.flags = flags.union(.maskNonCoalesced)
        event.setIntegerValueField(.eventSourceUserData, value: eventTag)
        eventPoster(event)
    }
}
