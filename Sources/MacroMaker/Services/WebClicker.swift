import AppKit

/// Clicks an element inside a browser tab by injecting JavaScript — the tab can be in the
/// background and the user can be working in another app.
@MainActor @Observable
final class WebClicker {
    enum Status: Equatable {
        case idle
        case success(String)
        case warning(String)
        case error(String)
    }

    nonisolated static let minimumIntervalMs: Double = 100
    /// The bound the interval field already enforces, hoisted so the run path enforces it too.
    /// Only the UI clamped it, so a value from an imported profile or a corrupted defaults blob
    /// reached `Duration.milliseconds(_:)` unchecked — above ~1.7e23 that call traps (measured:
    /// exit 133, "Overflow in multiplication"), killing the app.
    nonisolated static let maximumIntervalMs: Double = 3_600_000
    private static let storageKey = "webTarget"

    var settings = Persistence.load(WebTargetSettings.self, key: WebClicker.storageKey) ?? WebTargetSettings() {
        didSet { Persistence.save(settings, key: Self.storageKey) }
    }

    let session = RunSession()
    private(set) var clickCount = 0
    private(set) var status: Status = .idle
    private(set) var tabs: [BrowserTab] = []
    private(set) var tabsError: String?

    @ObservationIgnored private let scripting = BrowserScripting()
    @ObservationIgnored private var isTicking = false

    private struct Target {
        let browser: Browser
        let urlMatch: String
        let script: String
        let intervalMs: Double

        init(_ s: WebTargetSettings) {
            browser = s.browser
            urlMatch = s.urlMatch.trimmingCharacters(in: .whitespacesAndNewlines)
            script = WebClickScript.javaScript(for: s.locator)
            intervalMs = s.intervalMs.isFinite
                ? min(max(WebClicker.minimumIntervalMs, s.intervalMs), WebClicker.maximumIntervalMs)
                : WebClicker.minimumIntervalMs
        }
    }

    /// Why the current settings can't start, if they can't.
    var problem: String? {
        if settings.urlMatch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter the URL (or part of it) of the tab to click in."
        }
        switch settings.locatorKind {
        case .css where settings.cssSelector.trimmingCharacters(in: .whitespaces).isEmpty:
            return "Enter a CSS selector, e.g. #buy-button or button.primary."
        case .xpath where settings.xpath.trimmingCharacters(in: .whitespaces).isEmpty:
            return "Enter an XPath, e.g. //button[text()='Buy']."
        case .coordinates where !settings.x.isFinite || !settings.y.isFinite:
            return "Enter valid page coordinates."
        default:
            return nil
        }
    }

    func toggle(_ trigger: StartTrigger) {
        if session.phase.isActive {
            session.stop()
            return
        }
        if let problem {
            status = .error(problem)
            NSSound.beep()
            return
        }
        let target = Target(settings)
        // No countdown: injected clicks don't depend on the cursor or keyboard focus.
        session.start(withCountdown: false) { [weak self] token in
            guard let self else { return nil }
            clickCount = 0
            status = .idle
            let task = Task { [weak self] in
                let clock = ContinuousClock()
                var deadline = clock.now
                while !Task.isCancelled {
                    guard let self else { return }
                    guard tick(target) else {
                        session.finish(token)
                        return
                    }
                    deadline += .milliseconds(target.intervalMs)
                    if deadline < clock.now { deadline = clock.now }
                    try? await Task.sleep(until: deadline, clock: clock)
                }
            }
            return { task.cancel() }
        }
    }

    /// Clicks once without starting a run — for checking the selector.
    func testClick() {
        if let problem {
            status = .error(problem)
            return
        }
        tick(Target(settings))
    }

    func loadTabs() {
        do {
            tabs = try scripting.openTabs(in: settings.browser)
            tabsError = tabs.isEmpty ? "No open tabs in \(settings.browser.displayName)." : nil
        } catch {
            tabs = []
            tabsError = error.localizedDescription
        }
    }

    /// Runs one click. Returns whether a run should keep going.
    @discardableResult
    private func tick(_ target: Target) -> Bool {
        // AppleScript can spin the run loop while waiting; never overlap two clicks.
        guard !isTicking else { return true }
        isTicking = true
        defer { isTicking = false }

        do {
            let raw = try scripting.runJavaScript(target.script, inTabMatching: target.urlMatch, browser: target.browser)
            guard let result = WebClickScript.decodeResult(raw) else {
                status = .error("Unexpected response from the page: \(raw.prefix(80))")
                return false
            }
            if result.ok {
                clickCount += 1
                status = .success(result.description)
                return true
            }
            // A missing element may appear later (page still loading), so keep trying.
            status = result.isElementMissing ? .warning(result.description) : .error(result.description)
            return result.isElementMissing
        } catch {
            status = .error(error.localizedDescription)
            return false
        }
    }
}
