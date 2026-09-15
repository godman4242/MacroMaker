import AppKit
import ApplicationServices

/// Tracks the privacy permissions Macro Maker needs, and helps the user grant them.
@MainActor @Observable
final class PermissionService {
    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
        case automation = "Privacy_Automation"

        var url: URL {
            URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")!
        }
    }

    /// Needed to post clicks and key presses into other apps.
    private(set) var isAccessibilityTrusted = AXIsProcessTrusted()
    /// Needed to record keyboard input from other apps.
    private(set) var canMonitorInput = CGPreflightListenEventAccess()

    /// Called when a feature was blocked by a missing permission (e.g. started from a hotkey while
    /// the window is closed), so the app can bring its window forward.
    @ObservationIgnored var onPermissionMissing: (() -> Void)?
    @ObservationIgnored private var timer: Timer?

    init() {
        // macOS doesn't notify apps when permissions change, so poll (cheap).
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted != isAccessibilityTrusted { isAccessibilityTrusted = trusted }
        let listen = CGPreflightListenEventAccess()
        if listen != canMonitorInput { canMonitorInput = listen }
    }

    /// Returns `true` if Accessibility is granted; otherwise shows the system prompt and returns `false`.
    func ensureAccessibility() -> Bool {
        refresh()
        guard !isAccessibilityTrusted else { return true }
        requestAccessibility()
        NSSound.beep()
        onPermissionMissing?()
        return false
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        isAccessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }

    func requestInputMonitoring() {
        canMonitorInput = CGRequestListenEventAccess()
    }

    func open(_ pane: Pane) {
        NSWorkspace.shared.open(pane.url)
    }
}
