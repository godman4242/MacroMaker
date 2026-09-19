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

    struct Plan: Sendable {
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

    nonisolated static func play(_ plan: Plan, worker: WorkerThread,
                                 report: @Sendable (Progress, Bool) -> Void) {
        var progress = Progress()
        var lastReport: UInt64 = 0
        var humanizer = Humanizer(plan.humanizer)
        // One reused event source for the whole run (CGEventSource is a real allocation —
        // one per posted event costs a round-trip at playback rates), and one timing buffer
        // for the humanised grid, refilled per pass instead of re-allocated (perf H5).
        let source = EventSynthesizer.EventSource()
        var jitteredTimes = [Double](repeating: 0, count: plan.events.count)

        var cancelled = false
        playback: while plan.repeats.map({ progress.iteration < $0 }) ?? true {
            var heldKeys = Set<CGKeyCode>()
            var heldButtons: [MouseButton: CGPoint] = [:]
            // Whatever ends this pass — completion or Stop — nothing is left pressed.
            defer { Self.release(keys: heldKeys, buttons: heldButtons, source: source) }

            let start = DispatchTime.now().uptimeNanoseconds
            // Humanised replay jitters each inter-event gap; the opening gap survives (the old
            // code initialised `previous` from the first event's time, zeroing it).
            if plan.humanizer.enabled {
                humanizer.jitteredTimes(for: plan.events, into: &jitteredTimes)
            }
            for (index, event) in plan.events.enumerated() {
                let eventTime = plan.humanizer.enabled ? jitteredTimes[index] : event.time
                let due = start + Self.dueOffsetNanos(seconds: eventTime, speed: plan.speed)
                guard worker.sleep(untilUptime: due) else {
                    cancelled = true
                    break playback
                }
                post(event, heldKeys: &heldKeys, heldButtons: &heldButtons, source: source)

                progress.eventIndex = index + 1
                let now = DispatchTime.now().uptimeNanoseconds
                if now - lastReport > 50_000_000 {
                    report(progress, false)
                    lastReport = now
                }
            }
            progress.iteration += 1
            // A brief breather between passes, so a zero-length macro can't spin the CPU.
            guard worker.sleep(seconds: 0.01) else {
                cancelled = true
                break
            }
        }
        // A cancelled run is not a finished one: Stop already ended the session, and claiming
        // natural completion is the same reporting lie AutoClicker had to patch (review finding 7).
        report(progress, !cancelled)
    }

    nonisolated private static func post(_ event: MacroEvent, heldKeys: inout Set<CGKeyCode>,
                                         heldButtons: inout [MouseButton: CGPoint],
                                         source: EventSynthesizer.EventSource) {
        // Caps Lock is a toggle, not a held key: replaying its flag would force uppercase.
        let flags = CGEventFlags(rawValue: event.flags).subtracting(.maskAlphaShift)
        switch event.action {
        case let .mouseDown(button, point, clickCount):
            EventSynthesizer.postMouse(.mouseMoved, button: .left, at: point, flags: flags, source: source)
            EventSynthesizer.postMouse(button.downEventType, button: button, at: point, clickCount: clickCount,
                                       flags: flags, source: source)
            heldButtons[button] = point
        case let .mouseUp(button, point, clickCount):
            // No fabricated drag transition (review finding 6): a recording carries only what
            // was recorded, and replay posts exactly that — a synthetic dragged event at the
            // release point reads to apps as a jump-click, not the drag the user made.
            EventSynthesizer.postMouse(button.upEventType, button: button, at: point, clickCount: clickCount,
                                       flags: flags, source: source)
            heldButtons[button] = nil
        case let .keyDown(code, isRepeat):
            if let text = event.textOverride {
                EventSynthesizer.postText(text, down: true, flags: flags, source: source)
            } else {
                EventSynthesizer.postKey(code, down: true, flags: flags, isRepeat: isRepeat, source: source)
                heldKeys.insert(code)
            }
        case let .keyUp(code):
            if let text = event.textOverride {
                EventSynthesizer.postText(text, down: false, flags: flags, source: source)
            } else {
                EventSynthesizer.postKey(code, down: false, flags: flags, source: source)
                heldKeys.remove(code)
            }
        }
    }

    /// The longest offset a single event may be scheduled at. A macro is a replay of something a
    /// person did, so a day is already absurd — it exists only to keep the conversion in range.
    nonisolated static let maximumEventOffsetSeconds: TimeInterval = 86_400

    /// The event's offset from the start of playback, in nanoseconds.
    ///
    /// `UInt64(Double)` traps on a negative, infinite or NaN value (measured: exit 133), and
    /// nothing upstream used to bound this — a hand-edited or corrupted file could carry
    /// `1e400`, and a zero speed divides into infinity. Clamping here is the braces; rejecting
    /// the value at decode time is the belt.
    nonisolated static func dueOffsetNanos(seconds: TimeInterval, speed: Double) -> UInt64 {
        let scaled = seconds / speed
        guard !scaled.isNaN else { return 0 }
        return UInt64(min(max(scaled, 0), maximumEventOffsetSeconds) * 1_000_000_000)
    }

    nonisolated private static func release(keys: Set<CGKeyCode>, buttons: [MouseButton: CGPoint],
                                            source: EventSynthesizer.EventSource) {
        for code in keys {
            EventSynthesizer.postKey(code, down: false, flags: [], source: source)
        }
        for (button, point) in buttons {
            EventSynthesizer.postMouse(button.upEventType, button: button, at: point, source: source)
        }
    }
}
