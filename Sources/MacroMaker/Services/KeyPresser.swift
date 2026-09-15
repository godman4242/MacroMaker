import AppKit

@MainActor @Observable
final class KeyPresser {
    private static let storageKey = "keyPresser"

    var settings = Persistence.load(KeyPresserSettings.self, key: KeyPresser.storageKey) ?? KeyPresserSettings() {
        didSet { Persistence.save(settings, key: Self.storageKey) }
    }

    let session = RunSession()
    private(set) var pressCount = 0

    @ObservationIgnored private let permissions: PermissionService
    @ObservationIgnored private var runID = 0

    init(permissions: PermissionService) {
        self.permissions = permissions
    }

    /// The key field parsed against the current keyboard layout.
    var parsedKey: Result<KeyStroke, KeyStrokeParser.ParseError> {
        do {
            return .success(try KeyStrokeParser.parse(settings.keyText, layout: KeyboardLayout.current))
        } catch {
            return .failure(error)
        }
    }

    /// Why the current settings can't start, if they can't.
    var problem: String? {
        switch parsedKey {
        case let .failure(error):
            return error.localizedDescription
        case let .success(stroke):
            if settings.mode == .hold, !stroke.canHold {
                return "“\(stroke.label)” isn't on your keyboard layout, so it can be auto-pressed but not held."
            }
            return nil
        }
    }

    func toggle(_ trigger: StartTrigger) {
        if session.phase.isActive {
            session.stop()
            return
        }
        guard problem == nil, case let .success(stroke) = parsedKey else {
            NSSound.beep()
            return
        }
        guard permissions.ensureAccessibility() else { return }

        let mode = settings.mode
        let interval = max(TickSchedule.minimumDelay, settings.intervalMs / 1000)
        // Held keys repeat at the user's own System Settings ▸ Keyboard rates, like a real key.
        let repeatDelay = NSEvent.keyRepeatDelay
        let repeatInterval = NSEvent.keyRepeatInterval

        session.start(withCountdown: trigger == .button) { [weak self] token in
            guard let self else { return nil }
            runID += 1
            let run = runID
            pressCount = 0
            let report: @Sendable (Int, Bool) -> Void = { count, finished in
                performOnMain { [weak self] in
                    guard let self, self.runID == run else { return }
                    self.pressCount = count
                    if finished { self.session.finish(token) }
                }
            }
            let worker = WorkerThread.start(name: "KeyPresser") { worker in
                switch mode {
                case .autoPress:
                    Self.autoPressLoop(stroke, interval: interval, worker: worker, report: report)
                case .hold:
                    Self.holdLoop(stroke, repeatDelay: repeatDelay, repeatInterval: repeatInterval, worker: worker, report: report)
                }
            }
            return { worker.cancelAndWait() }
        }
    }

    nonisolated private static func autoPressLoop(_ stroke: KeyStroke, interval: TimeInterval, worker: WorkerThread,
                                                  report: @Sendable (Int, Bool) -> Void) {
        let hold = TickSchedule.pressDuration(interval: interval)
        let step = UInt64(interval * 1_000_000_000)
        var deadline = DispatchTime.now().uptimeNanoseconds
        var count = 0
        var lastReport: UInt64 = 0

        while !worker.isCancelled {
            EventSynthesizer.keyDown(stroke)
            Thread.sleep(forTimeInterval: hold)
            EventSynthesizer.keyUp(stroke)
            count += 1

            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastReport > 50_000_000 {
                report(count, false)
                lastReport = now
            }
            deadline = TickSchedule.nextDeadline(previous: deadline, delay: step, now: now)
            guard worker.sleep(untilUptime: deadline) else { break }
        }
        report(count, true)
    }

    /// Presses the key and keeps it down — with auto-repeat, exactly like a finger on the key —
    /// until stopped. The key is always released, whatever stops it.
    nonisolated private static func holdLoop(_ stroke: KeyStroke, repeatDelay: TimeInterval, repeatInterval: TimeInterval,
                                             worker: WorkerThread, report: @Sendable (Int, Bool) -> Void) {
        EventSynthesizer.keyDown(stroke)
        report(1, false)
        defer {
            EventSynthesizer.keyUp(stroke)
            report(1, true)
        }
        // Modifier keys (Shift, ⌘…) don't auto-repeat on real keyboards either.
        guard case let .code(code) = stroke.key, KeyCodes.modifierKey(for: code) == nil else {
            while worker.sleep(seconds: 3600) {}
            return
        }
        guard worker.sleep(seconds: repeatDelay) else { return }
        let step = UInt64(max(repeatInterval, 0.015) * 1_000_000_000)
        var deadline = DispatchTime.now().uptimeNanoseconds
        repeat {
            EventSynthesizer.keyDown(stroke, isRepeat: true)
            deadline = TickSchedule.nextDeadline(previous: deadline, delay: step, now: DispatchTime.now().uptimeNanoseconds)
        } while worker.sleep(untilUptime: deadline)
    }
}
