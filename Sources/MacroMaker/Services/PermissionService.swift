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
    /// Whether the system's "grant Accessibility?" dialog was already shown this launch.
    /// It only fires once — after that the in-app banner is the only repeated UI.
    @ObservationIgnored private(set) var didPromptForAccessibility = false

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
        // The system prompt fires on the first call of this launch only — repeated calls
        // (feature blocked, banner, settings, menu bar) would otherwise re-show it.
        let options = ["AXTrustedCheckOptionPrompt": !didPromptForAccessibility] as CFDictionary
        didPromptForAccessibility = true
        isAccessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }

    func requestInputMonitoring() {
        canMonitorInput = CGRequestListenEventAccess()
    }

    func open(_ pane: Pane) {
        NSWorkspace.shared.open(pane.url)
    }
}
