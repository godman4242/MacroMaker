import AppKit

/// Captures the next key press inside Macro Maker's window — used by the shortcut fields and
/// the Key Presser's "Record" button. Only one field can capture at a time.
@MainActor @Observable
final class KeyCapture {
    /// Which field is capturing, if any.
    private(set) var owner: String?

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var onEnd: (() -> Void)?

    /// `onKey` returns true once it has what it needs, which ends the capture.
    func begin(owner: String, onKey: @escaping @MainActor (NSEvent) -> Bool, onEnd: (() -> Void)? = nil) {
        end()
        self.owner = owner
        self.onEnd = onEnd
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                if onKey(event) { self?.end() }
            }
            return nil
        }
    }

    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        owner = nil
        let callback = onEnd
        onEnd = nil
        callback?()
    }
}
