import AppKit

/// Replays a macro with its original timing (optionally faster/slower, repeated or looped).
@MainActor @Observable
final class MacroPlayer {
    struct Progress: Equatable, Sendable {
        var iteration = 0
        var eventIndex = 0
    }

    private static let storageKey = "playback"

    var settings = Persistence.load(PlaybackSettings.self, key: MacroPlayer.storageKey) ?? PlaybackSettings() {
        didSet { Persistence.save(settings, key: Self.storageKey) }
    }

    let session = RunSession()
    private(set) var progress = Progress()

    @ObservationIgnored private let permissions: PermissionService
    @ObservationIgnored private var runID = 0

    init(permissions: PermissionService) {
        self.permissions = permissions
    }

    private struct Plan: Sendable {
        let events: [MacroEvent]
        /// nil = loop until stopped.
        let repeats: Int?
        let speed: Double
        let humanizer: HumanizerSettings
    }

    func toggle(_ macro: Macro?, trigger: StartTrigger) {
        if session.phase.isActive {
            session.stop()
            return
        }
        guard let macro, !macro.events.isEmpty else {
            NSSound.beep()
            return
        }
        guard permissions.ensureAccessibility() else { return }

        let plan = Plan(events: macro.events,
                        repeats: settings.loopForever ? nil : max(1, settings.repeatCount),
                        speed: min(max(settings.speed, 0.1), 10),
                        humanizer: settings.humanizer)
        session.start(withCountdown: trigger == .button) { [weak self] token in
            guard let self else { return nil }
            runID += 1
            let run = runID
            progress = Progress()
            let worker = WorkerThread.start(name: "MacroPlayer") { worker in
                Self.play(plan, worker: worker) { progress, finished in
                    performOnMain { [weak self] in
                        guard let self, self.runID == run else { return }
                        self.progress = progress
                        if finished { self.session.finish(token) }
                    }
                }
            }
            return { worker.cancelAndWait() }
        }
    }

    nonisolated private static func play(_ plan: Plan, worker: WorkerThread,
                                         report: @Sendable (Progress, Bool) -> Void) {
        var progress = Progress()
        var lastReport: UInt64 = 0
        var humanizer = Humanizer(plan.humanizer)

        playback: while plan.repeats.map({ progress.iteration < $0 }) ?? true {
            var heldKeys = Set<CGKeyCode>()
            var heldButtons: [MouseButton: CGPoint] = [:]
            // Whatever ends this pass — completion or Stop — nothing is left pressed.
            defer { release(keys: heldKeys, buttons: heldButtons) }

            let start = DispatchTime.now().uptimeNanoseconds
            // Humanised replay jitters each inter-event gap; precompute so the grid stays stable.
            var jitteredTimes: [Double] = []
            if plan.humanizer.enabled {
                var jitteredStart = 0.0
                var previous = plan.events.first?.time ?? 0
                for event in plan.events {
                    jitteredStart += humanizer.jittered(gap: event.time - previous)
                    previous = event.time
                    jitteredTimes.append(jitteredStart)
                }
            }
            for (index, event) in plan.events.enumerated() {
                let eventTime = plan.humanizer.enabled ? jitteredTimes[index] : event.time
                let due = start + UInt64(eventTime / plan.speed * 1_000_000_000)
                guard worker.sleep(untilUptime: due) else { break playback }
                post(event, heldKeys: &heldKeys, heldButtons: &heldButtons)

                progress.eventIndex = index + 1
                let now = DispatchTime.now().uptimeNanoseconds
                if now - lastReport > 50_000_000 {
                    report(progress, false)
                    lastReport = now
                }
            }
            progress.iteration += 1
            // A brief breather between passes, so a zero-length macro can't spin the CPU.
            guard worker.sleep(seconds: 0.01) else { break }
        }
        report(progress, true)
    }

    nonisolated private static func post(_ event: MacroEvent, heldKeys: inout Set<CGKeyCode>,
                                         heldButtons: inout [MouseButton: CGPoint]) {
        // Caps Lock is a toggle, not a held key: replaying its flag would force uppercase.
        let flags = CGEventFlags(rawValue: event.flags).subtracting(.maskAlphaShift)
        switch event.action {
        case let .mouseDown(button, point, clickCount):
            EventSynthesizer.postMouse(.mouseMoved, button: .left, at: point, flags: flags)
            EventSynthesizer.postMouse(button.downEventType, button: button, at: point, clickCount: clickCount, flags: flags)
            heldButtons[button] = point
        case let .mouseUp(button, point, clickCount):
            if let downPoint = heldButtons[button], downPoint != point {
                // The button moved while down: a drag. Tell apps before releasing.
                EventSynthesizer.postMouse(button.dragEventType, button: button, at: point, flags: flags)
            }
            EventSynthesizer.postMouse(button.upEventType, button: button, at: point, clickCount: clickCount, flags: flags)
            heldButtons[button] = nil
        case let .keyDown(code, isRepeat):
            EventSynthesizer.postKey(code, down: true, flags: flags, isRepeat: isRepeat)
            heldKeys.insert(code)
        case let .keyUp(code):
            EventSynthesizer.postKey(code, down: false, flags: flags)
            heldKeys.remove(code)
        }
    }

    nonisolated private static func release(keys: Set<CGKeyCode>, buttons: [MouseButton: CGPoint]) {
        for code in keys {
            EventSynthesizer.postKey(code, down: false, flags: [])
        }
        for (button, point) in buttons {
            EventSynthesizer.postMouse(button.upEventType, button: button, at: point)
        }
    }
}
