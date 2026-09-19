import AppKit

/// Records mouse clicks and key presses system-wide with a listen-only event tap.
@MainActor @Observable
final class MacroRecorder {
    private(set) var isRecording = false
    /// Run-state mirror for the UI: RunControls drives off a shared RunSession shape, so recording
    /// keeps one in sync with `isRecording` (start → running, stop → idle).
    let session = RunSession()
    private(set) var liveEvents: [MacroEvent] = []
    private(set) var errorMessage: String?

    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var startUptime: UInt64 = 0
    /// Buttons pressed on Macro Maker's own windows; their releases are ignored too.
    @ObservationIgnored private var ignoredButtons = Set<MouseButton>()

    /// Builds the listen-only tap. The real one needs an Input Monitoring grant the test
    /// runner doesn't have, so tests swap in an inert mach port and drive `handle(_:)` directly.
    nonisolated(unsafe) static var tapBuilder: (CGEventMask, UnsafeMutableRawPointer?) -> CFMachPort? = { mask, userInfo in
        CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                          eventsOfInterest: mask, callback: recorderTapCallback, userInfo: userInfo)
    }

    /// Starts recording. Returns false (and sets `errorMessage`) if macOS refuses the event tap.
    @discardableResult
    func start() -> Bool {
        guard !isRecording else { return true }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }

        guard let tap = Self.tapBuilder(mask, Unmanaged.passUnretained(self).toOpaque())
        else {
            CGRequestListenEventAccess()
            errorMessage = "macOS blocked recording. Allow Macro Maker in System Settings ▸ Privacy & Security ▸ Input Monitoring, then try again."
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        runLoopSource = source
        startUptime = DispatchTime.now().uptimeNanoseconds
        ignoredButtons.removeAll()
        liveEvents = []
        errorMessage = nil
        isRecording = true
        session.start(withCountdown: false) { _ in return {} }
        return true
    }

    /// Stops recording and returns the cleaned-up events.
    func stop() -> [MacroEvent] {
        guard isRecording else { return [] }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isRecording = false
        session.stop()
        let events = RecordingCleaner.clean(liveEvents)
        liveEvents = []
        return events
    }

    func handle(_ event: TapEvent) {
        if event.type == .tapDisabledByTimeout || event.type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard isRecording, !event.isOwnEvent else { return }

        let action: MacroEvent.Action
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard let button = MouseButton(buttonNumber: event.buttonNumber) else { return }
            if isOverOwnWindow(event.location) {
                ignoredButtons.insert(button)
                return
            }
            action = .mouseDown(button, event.location, clickCount: event.clickCount)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard let button = MouseButton(buttonNumber: event.buttonNumber) else { return }
            if ignoredButtons.remove(button) != nil { return }
            action = .mouseUp(button, event.location, clickCount: event.clickCount)
        case .keyDown, .keyUp:
            // Typing into Macro Maker itself (e.g. the stop shortcut) is not part of the macro.
            guard !NSApp.isActive else { return }
            action = event.type == .keyDown ? .keyDown(event.keyCode, isRepeat: event.isAutorepeat) : .keyUp(event.keyCode)
        case .flagsChanged:
            guard !NSApp.isActive, KeyCodes.modifierKey(for: event.keyCode) != nil else { return }
            action = KeyCodes.isModifierDown(code: event.keyCode, flags: event.flags)
                ? .keyDown(event.keyCode, isRepeat: false)
                : .keyUp(event.keyCode)
        default:
            return
        }
        // The window server stamps the event when the input actually happened; this callback runs
        // on the main run loop, which is periodically busy repainting the live-event table, so
        // arrival time silently inflates fast sequences (review finding 1). An unstamped event
        // (timestamp 0) falls back to arrival; a stamp older than the start clamps to 0.
        let stamp = event.timestampNanos
        let time = stamp > 0
            ? Double(stamp - min(stamp, startUptime)) / 1_000_000_000
            : Double(DispatchTime.now().uptimeNanoseconds - startUptime) / 1_000_000_000
        liveEvents.append(MacroEvent(time: time, action: action, flags: event.flags))
    }

    /// Clicks on Macro Maker's own windows (Record/Stop buttons, menu bar icon) aren't recorded.
    private func isOverOwnWindow(_ point: CGPoint) -> Bool {
        guard let primaryScreen = NSScreen.screens.first else { return false }
        // Event taps use a top-left origin; AppKit uses bottom-left.
        let cocoaPoint = NSPoint(x: point.x, y: primaryScreen.frame.maxY - point.y)
        let windowNumber = NSWindow.windowNumber(at: cocoaPoint, belowWindowWithWindowNumber: 0)
        return NSApp.windows.contains { $0.windowNumber == windowNumber }
    }
}

/// The parts of a CGEvent the recorder needs, extracted on the tap's thread.
struct TapEvent: Sendable {
    let type: CGEventType
    let location: CGPoint
    let keyCode: CGKeyCode
    let flags: UInt64
    let clickCount: Int
    let buttonNumber: Int64
    let isAutorepeat: Bool
    let isOwnEvent: Bool
    /// The window server's own clock for the input, in nanoseconds since startup (zero when
    /// unstamped) — the accurate moment the event happened, not when main got around to it.
    let timestampNanos: UInt64

    init(type: CGEventType, event: CGEvent) {
        self.type = type
        location = event.location
        keyCode = CGKeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        flags = event.flags.rawValue
        clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
        buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        isOwnEvent = event.getIntegerValueField(.eventSourceUserData) == EventSynthesizer.eventTag
        timestampNanos = event.timestamp
    }
}

/// The tap's run loop source is on the main run loop, so this runs on the main thread.
private func recorderTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let tapEvent = TapEvent(type: type, event: event)
        let recorder = Unmanaged<MacroRecorder>.fromOpaque(userInfo).takeUnretainedValue()
        MainActor.assumeIsolated { recorder.handle(tapEvent) }
    }
    return Unmanaged.passUnretained(event)
}
