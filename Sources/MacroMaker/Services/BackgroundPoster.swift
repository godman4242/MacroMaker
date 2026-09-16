import AppKit
import CoreGraphics
import Foundation

/// Posts mouse and keyboard events straight into a chosen app's process (`CGEventPostToPid`),
/// so the target window can sit behind other apps or on another Space — and the cursor never moves.
///
/// The click events follow the documented recipe for background delivery: a screen-space CGEvent
/// whose private window-target fields (91/92) name the window under the point, subtype 3, and —
/// when the app isn't active — the NX_COMMAND bit set so AppKit doesn't drop the click.
/// The window-local point is applied through the private `CGEventSetWindowLocation` symbol,
/// looked up at runtime and optional-chained: if it can't be resolved the UI says so loudly.
enum BackgroundPoster {

    /// One of an app's on-screen windows, as plain data (the testable seam over the window server).
    struct Window: Equatable, Sendable {
        let id: CGWindowID
        let bounds: CGRect
    }

    /// A running app the user can target.
    struct ListedApp: Identifiable, Equatable, Sendable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    // MARK: Window lookup

    /// Field numbers from the research summary that a background-post event must not overwrite.
    static let protectedFields: [UInt32] = [0, 1, 2, 41, 43, 44, 50, 51, 55, 59, 102, 108]

    /// kCGMouseEventWindowUnderMousePointer — names the window the click is aimed at.
    private static let windowField = CGEventField(rawValue: 91)!
    /// kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent.
    private static let handlerWindowField = CGEventField(rawValue: 92)!

    /// Pure filter over one raw CGWindowInfo dictionary: the app's layer-0 windows only.
    static func window(fromInfo info: [String: Any], ownerPID: pid_t) -> Window? {
        guard let owner = info[kCGWindowOwnerPID as String] as? Int, owner == ownerPID,
              let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
              let number = info[kCGWindowNumber as String] as? Int, number > 0,
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any] as CFDictionary?,
              let bounds = CGRect(dictionaryRepresentation: boundsDict),
              bounds.width > 0, bounds.height > 0
        else { return nil }
        return Window(id: CGWindowID(number), bounds: bounds)
    }

    /// The app's front-most usable window (the window server lists windows front to back).
    /// Re-queried before every click so a moved or resized window is followed.
    static func primaryWindow(ofPID pid: pid_t) -> Window? {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return list.lazy.compactMap { window(fromInfo: $0, ownerPID: pid) }.first
    }

    // MARK: Apps

    /// The target's pid and active state in one synchronous main-thread sample, callable from a
    /// worker thread (AutoClicker.samples the frontmost app the same way).
    nonisolated static func targetState(forBundleID bundleID: String) -> (pid: pid_t?, isActive: Bool) {
        DispatchQueue.main.sync {
            let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first?.processIdentifier
            let isActive = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
            return (pid, isActive)
        }
    }

    @MainActor static func processID(forBundleID bundleID: String) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
    }

    /// Regular apps the user could plausibly click in, without Macro Maker itself.
    @MainActor static func targetableApps() -> [ListedApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in
                app.bundleIdentifier.map { ListedApp(bundleID: $0, name: app.localizedName ?? $0) }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Which app is active right now (the ⌘-flag rule depends on it).
    @MainActor static func isActive(bundleID: String) -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    // MARK: Window-location seam

    /// Runtime seam for the private `CGEventSetWindowLocation` symbol — swapped for a fake in tests.
    protocol WindowLocationResolver {
        var isAvailable: Bool { get }
        /// Applies a window-local point to the event. Returns false when the symbol is missing.
        @discardableResult func setWindowLocation(of event: CGEvent, to point: CGPoint) -> Bool
    }

    struct SystemWindowLocationResolver: WindowLocationResolver {
        private typealias CFunction = @convention(c) (CGEvent, CGPoint) -> Void
        private let function: CFunction? = {
            // RTLD_DEFAULT is ((void *) -2) in dlfcn.h; the macro doesn't import into Swift.
            let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
            guard let symbol = dlsym(rtldDefault, "CGEventSetWindowLocation") else { return nil }
            return unsafeBitCast(symbol, to: CFunction.self)
        }()

        var isAvailable: Bool { function != nil }

        @discardableResult func setWindowLocation(of event: CGEvent, to point: CGPoint) -> Bool {
            guard let function else { return false }
            function(event, point)
            return true
        }
    }

    nonisolated(unsafe) static var windowLocationResolver: any WindowLocationResolver = SystemWindowLocationResolver()

    /// False triggers the loud UI failure: background clicks can't be aimed without the symbol.
    static var targetingSupported: Bool { windowLocationResolver.isAvailable }

    // MARK: Coordinates & flags

    /// Screen point → window-local point (translate by the negative window origin).
    static func windowPoint(fromScreenPoint point: CGPoint, window: Window) -> CGPoint {
        CGPoint(x: point.x - window.bounds.origin.x, y: point.y - window.bounds.origin.y)
    }

    /// 0x00100000 is the NX_COMMAND device-independent bit. Background-posted clicks are dropped
    /// by AppKit unless the event pretends ⌘ is held when the target app isn't the active one.
    static let backgroundClickFlag = CGEventFlags(rawValue: 0x0010_0000)

    static func clickFlags(appIsActive: Bool) -> CGEventFlags {
        appIsActive ? [] : backgroundClickFlag
    }

    // MARK: Posting

    /// One mouse transition aimed at the window, ready to post to the owning process.
    static func mouseEvent(_ type: CGEventType, button: MouseButton, clickCount: Int,
                           screenPoint: CGPoint, window: Window) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: screenPoint, mouseButton: button.cgButton) else { return nil }
        // Only the recipe's fields are set; the protected field numbers stay untouched.
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.cgButton.rawValue))
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event.setIntegerValueField(.mouseEventSubtype, value: 3)
        event.setIntegerValueField(windowField, value: Int64(window.id))
        event.setIntegerValueField(handlerWindowField, value: Int64(window.id))
        windowLocationResolver.setWindowLocation(of: event, to: windowPoint(fromScreenPoint: screenPoint, window: window))
        return event
    }

    /// A complete click delivered to the process: down, hold, up.
    static func click(_ button: MouseButton, screenPoint: CGPoint, holdFor duration: TimeInterval,
                      clickCount: Int, window: Window, pid: pid_t, appIsActive: Bool) {
        post(mouseEvent(button.downEventType, button: button, clickCount: clickCount,
                        screenPoint: screenPoint, window: window),
             appIsActive: appIsActive, pid: pid)
        if duration > 0 { Thread.sleep(forTimeInterval: duration) }
        post(mouseEvent(button.upEventType, button: button, clickCount: clickCount,
                        screenPoint: screenPoint, window: window),
             appIsActive: appIsActive, pid: pid)
    }

    private static func post(_ event: CGEvent?, appIsActive: Bool, pid: pid_t) {
        guard let event else { return }
        // Same contract as the HID path: explicit flags (never the user's held keys) and the
        // self-tag so the recorder ignores Macro Maker's own output.
        event.flags = clickFlags(appIsActive: appIsActive).union(.maskNonCoalesced)
        event.setIntegerValueField(.eventSourceUserData, value: EventSynthesizer.eventTag)
        event.postToPid(pid)
    }

    // MARK: Keyboard

    /// One key transition delivered to the process (no windows involved — keys go to whatever has
    /// focus *inside* the app, so the app should be brought forward first for reliable typing).
    static func keyEvent(_ code: CGKeyCode, down: Bool, flags: CGEventFlags,
                         isRepeat: Bool = false, pid: pid_t) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return }
        if isRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        postKey(event, flags: flags, pid: pid)
    }

    /// Types a character that isn't a physical key by attaching it as a Unicode string.
    static func textEvent(_ text: String, down: Bool, pid: pid_t) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { return }
        let utf16 = Array(text.utf16)
        event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        postKey(event, flags: [], pid: pid)
    }

    private static func postKey(_ event: CGEvent, flags: CGEventFlags, pid: pid_t) {
        event.flags = flags.union(.maskNonCoalesced)
        event.setIntegerValueField(.eventSourceUserData, value: EventSynthesizer.eventTag)
        event.postToPid(pid)
    }
}
