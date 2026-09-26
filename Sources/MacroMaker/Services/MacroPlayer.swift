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
    /// A one-line note about the last run (a chain step whose macro was deleted); nil = fine.
    /// Cleared on every launch and every stop, like AutoClicker's `runWarning`.
    private(set) var runWarning: String?
    /// Test seam: the library the plan-building snapshot reads (nil = AppModel.shared's).
    /// The real one is @MainActor and the player is too, but the SHARED instance outlives a
    /// test, so the seam lets a suite point it at its own records without touching the app's.
    @ObservationIgnored var chainLibrary: MacroLibrary?

    @ObservationIgnored private let permissions: PermissionService
    @ObservationIgnored private var runID = 0

    init(permissions: PermissionService) {
        self.permissions = permissions
        session.onStop = { [weak self] in
            self?.runWarning = nil
            self?.chainLibrary = nil
        }
    }

    struct Plan: Sendable {
        let events: [MacroEvent]
        /// nil = loop until stopped.
        let repeats: Int?
        let speed: Double
        let humanizer: HumanizerSettings
        /// How run-macro steps resolve at run time (nil = the plan has no run-macro steps
        /// and none of this machinery runs — the pre-chaining plans).
        let chain: ChainedMacros?
        /// "Follow the window" (F-14): anchored mouse steps translate by the window's move.
        let followWindow: Bool
        /// "Play into" (background playback): the app every step is posted into; nil = the
        /// real cursor (the normal replay).
        let playInto: String?

        init(events: [MacroEvent], repeats: Int?, speed: Double,
             humanizer: HumanizerSettings, chain: ChainedMacros? = nil,
             followWindow: Bool = true, playInto: String? = nil) {
            self.events = events
            self.repeats = repeats
            self.speed = speed
            self.humanizer = humanizer
            self.chain = chain
            self.followWindow = followWindow
            self.playInto = playInto
        }
    }

    /// The chain failure a run can end with: a run-macro step whose macro is gone (deleted)
    /// or whose chain nests past the cap. Surfaced as the run's failure message — never a
    /// silent skip.
    struct ChainFailure: Equatable, Sendable {
        /// The step that couldn't run, in the ROOT macro's event list.
        let stepIndex: Int
        /// The id the step tried to resolve.
        let macroID: UUID
        /// Why it failed: nil = the macro is gone; a number = the chain got that deep.
        let depth: Int?
        /// Non-nil when the failure is a window-binding miss (F-14): the app whose window
        /// couldn't be found at replay. A chain failure leaves it nil; the two share this
        /// one loud channel because both mean "the run couldn't do what it promised".
        var windowApp: String?

        init(stepIndex: Int, macroID: UUID, depth: Int?) {
            self.stepIndex = stepIndex
            self.macroID = macroID
            self.depth = depth
            self.windowApp = nil
        }

        init(windowGone app: String, at index: Int) {
            self.stepIndex = index
            self.macroID = UUID()
            self.depth = nil
            self.windowApp = app
        }
    }

    /// The pass count for a playback (F-11 "repeat until the stop shortcut"). Until-hotkey
    /// is a stop CONDITION, not a fourth bound: the stop-run hotkey ends the playback, so
    /// the repeat count and the loop toggle both come off — a 3-repeat bound on an
    /// until-hotkey playback would end it before the keypress ever mattered.
    nonisolated static func playbackRepeats(_ s: PlaybackSettings) -> Int? {
        s.stopOnHotkey ? nil : (s.loopForever ? nil : max(1, s.repeatCount))
    }

    /// The launch-time chain check: nil = safe to run. Loads every referenced macro ONCE
    /// (skipping unresolvable ids — a deleted macro is a run-time failure, loud at the step
    /// that references it, not a launch refusal), builds the parent→children map and asks
    /// `ChainingRules.validate`. The returned string is shown to the user, so it names the
    /// macro and the problem in plain words.
    nonisolated static func chainProblem(for root: Macro,
                                         depthLimit: Int = ChainingRules.defaultDepthLimit,
                                         resolve: ChainedMacros.Resolver) -> String? {
        // The root's id is a stand-in: Macro has no id of its own, and the walk only needs
        // one key that can't collide with a library id.
        let rootKey = UUID()
        var childrenByRoot: [UUID: [UUID]] = [rootKey: ChainingRules.children(of: root)]
        var names: [UUID: String] = [rootKey: root.name]
        var loaded: Set<UUID> = []
        // Depth-first over what the root reaches: each referenced macro loads at most once
        // (a diamond A→B, A→B walks B once).
        var queue = childrenByRoot[rootKey] ?? []
        while let id = queue.popLast() {
            guard let macro = resolve(id), !loaded.contains(id) else { continue }
            loaded.insert(id)
            names[id] = macro.name
            childrenByRoot[id] = ChainingRules.children(of: macro)
            queue.append(contentsOf: childrenByRoot[id] ?? [])
        }
        guard let verdict = ChainingRules.validate(root: rootKey, childrenByRoot: childrenByRoot,
                                                   depthLimit: depthLimit) else { return nil }
        switch verdict {
        case .cycle(let id):
            return "Can't play “\(root.name)”: it loops back into “\(names[id] ?? id.uuidString)” through its Run Macro steps. A chain must not repeat a macro."
        case .tooDeep(let id):
            return "Can't play “\(root.name)”: its chain nests more than \(depthLimit) deep (through “\(names[id] ?? id.uuidString)”)."
        }
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

        let chain = makeChain(for: macro)
        // Fail loud, don't launch: a cyclic or over-deep chain is a bad macro, not a run.
        // A macro with no chain machinery resolves nothing, which the check reads as "every
        // referenced macro was deleted" — a launch refusal for a plain macro would be wrong.
        let resolveNothing: ChainedMacros.Resolver = { _ in nil }
        if let problem = Self.chainProblem(for: macro, resolve: chain?.resolve ?? resolveNothing) {
            NSSound.beep()
            runWarning = problem
            return
        }

        let playInto = settings.playIntoBundleID
        if let problem = Self.playIntoProblem(bundleID: playInto,
                                              isRunning: BackgroundPoster.processID(forBundleID: playInto) != nil) {
            NSSound.beep()
            runWarning = problem
            return
        }
        // The worker resolves bundle ids from TargetSnapshot's cache, whose first lookup of an
        // id misses (it fills asynchronously on main) — without this, a run's first anchored
        // step read "app quit" and played at the old spot, and a play-into run would stop on
        // its first step. The Auto Clicker has always pre-warmed its target the same way.
        for bundleID in Self.bundleIDsToPrewarm(for: macro, playInto: playInto, resolve: chain?.resolve) {
            TargetSnapshot.shared.prewarm(bundleID: bundleID)
        }

        let plan = Plan(events: macro.events,
                        repeats: Self.playbackRepeats(settings),
                        speed: min(max(settings.speed, 0.1), 10),
                        humanizer: settings.humanizer,
                        chain: chain?.chain,
                        followWindow: settings.followWindow,
                        playInto: playInto.isEmpty ? nil : playInto)
        // No countdown when playing into an app: nothing depends on where the cursor is.
        session.start(withCountdown: trigger == .button && playInto.isEmpty) { [weak self] token in
            guard let self else { return nil }
            runID += 1
            let run = runID
            progress = Progress()
            runWarning = nil
            let worker = WorkerThread.start(name: "MacroPlayer") { worker in
                Self.play(plan, worker: worker) { progress, finished in
                    performOnMain { [weak self] in
                        guard let self, self.runID == run else { return }
                        self.progress = progress
                        if finished { self.session.finish(token) }
                    }
                } chainFailure: { [weak self] failure in
                    performOnMain { [weak self] in
                        guard let self, self.runID == run else { return }
                        self.runWarning = Self.describe(failure, resolve: chain?.resolve ?? resolveNothing)
                    }
                }
            }
            return worker.stopClosure(named: "Macro Player")
        }
    }

    /// Everything the plan needs to resolve run-macro steps at run time, when the macro has
    /// any: the library's `[UUID: file name]` snapshot (main actor, at launch) and the resolver
    /// that decodes from disk on the worker thread — a macro renamed or re-saved since launch
    /// still resolves, and one deleted since launch fails loud, not silently.
    private struct ChainKit {
        let resolve: ChainedMacros.Resolver
        let chain: ChainedMacros
    }

    private func makeChain(for macro: Macro) -> ChainKit? {
        guard macro.events.contains(where: { if case .runMacro = $0.action { return true }; return false }) else { return nil }
        let library = chainLibrary ?? AppModel.shared.library
        let snapshot = Dictionary(uniqueKeysWithValues: library.records.map { ($0.id, $0.fileName) })
        // The records' own folder, resolved once on the main actor; the resolver only
        // appends a safe file name to it on the worker thread.
        let folder = MacroLibrary.folder
        let resolve: ChainedMacros.Resolver = { id in
            guard let fileName = snapshot[id], let folder else { return nil }
            return try? Macro(jsonData: Data(contentsOf: folder.appending(path: fileName)))
        }
        return ChainKit(resolve: resolve, chain: ChainedMacros(resolve: resolve))
    }

    /// The user-facing line for a run-time chain failure: names the macro the step wanted
    /// and what happened to it, anchored at the ROOT step the user can see and edit.
    nonisolated private static func describe(_ failure: ChainFailure, resolve: ChainedMacros.Resolver) -> String {
        if let app = failure.windowApp {
            return "The run stopped at step \(failure.stepIndex + 1): “\(app)” quit, or has no window at that spot — nothing was clicked in its place."
        }
        let name = resolve(failure.macroID)?.name ?? failure.macroID.uuidString
        if let depth = failure.depth, depth > ChainingRules.defaultDepthLimit {
            return "The chain stopped: “\(name)” nests more than \(ChainingRules.defaultDepthLimit) deep."
        }
        return "The chain stopped: “\(name)” isn't in the library any more (step \(failure.stepIndex + 1))."
    }

    nonisolated static func play(_ plan: Plan, worker: WorkerThread,
                                 report: @Sendable (Progress, Bool) -> Void,
                                 chainFailure: @Sendable (ChainFailure) -> Void = { _ in }) {
        var progress = Progress()
        var lastReport: UInt64 = 0
        var humanizer = Humanizer(plan.humanizer)
        // One reused event source for the whole run (CGEventSource is a real allocation —
        // one per posted event costs a round-trip at playback rates), and one timing buffer
        // for the humanised grid, refilled per pass instead of re-allocated (perf H5).
        let source = EventSynthesizer.EventSource()
        var jitteredTimes = [Double](repeating: 0, count: plan.events.count)

        var cancelled = false
        var failure: ChainFailure?
        // The window-gone handshake: post() reports a missing window through this box (a
        // @Sendable closure can't capture the loop's vars), the loop reads it right after.
        let windowMiss = WindowMissBox()
        let missingWindow: @Sendable (String) -> Bool = { app in
            windowMiss.record(app)
            return true
        }
        let into = plan.playInto.map(PlayIntoApp.init(bundleID:))
        playback: while plan.repeats.map({ progress.iteration < $0 }) ?? true {
            var heldKeys = Set<CGKeyCode>()
            var heldButtons: [MouseButton: CGPoint] = [:]
            var shifts: [MouseButton: CGSize] = [:]
            // Whatever ends this pass — completion or Stop — nothing is left pressed.
            defer { Self.release(keys: heldKeys, buttons: heldButtons, source: source, into: into) }

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
                // A run-macro step expands the referenced macro inline, up to the chain's
                // depth cap; a missing macro (deleted since launch) ends the run LOUD.
                if case let .runMacro(id) = event.action, let chain = plan.chain {
                    // The child's own events schedule from THIS step's due time (its
                    // doc: "offsets from this step's due time") — the root start would
                    // fire a mid-macro chain step's past-due events in a compressed burst.
                    // The pass's held sets go straight through, so whatever the child
                    // presses is released at pass end HOWEVER the expansion ends — a Stop
                    // mid-chain used to drop the child's held keys and leave them down.
                    switch Self.expand(id, chain: chain, worker: worker, start: due,
                                      speed: plan.speed, followWindow: plan.followWindow,
                                      heldKeys: &heldKeys, heldButtons: &heldButtons,
                                      shifts: &shifts, source: source, into: into,
                                      windowMiss: windowMiss, depth: 1) {
                    case .failed(let stepFailure):
                        // Re-point the failure at the ROOT step the user can see and edit.
                        failure = ChainFailure(stepIndex: index, macroID: stepFailure.macroID,
                                              depth: stepFailure.depth)
                        cancelled = true
                        break playback
                    case .cancelled:
                        // Stop, not a failure: no "isn't in the library" warning after it.
                        cancelled = true
                        break playback
                    case .ran, .windowGone:
                        break
                    }
                    // A chained step that lost its window (or play-into app) fails the run
                    // loud at the ROOT step, like a root step does.
                    if let app = windowMiss.take() {
                        failure = ChainFailure(windowGone: app, at: index)
                        cancelled = true
                        break playback
                    }
                    progress.eventIndex = index + 1
                    continue
                }
                post(event, heldKeys: &heldKeys, heldButtons: &heldButtons, shifts: &shifts,
                     source: source, followWindow: plan.followWindow, into: into,
                     missingWindow: missingWindow)
                if let app = windowMiss.take() {
                    failure = ChainFailure(windowGone: app, at: index)
                    cancelled = true
                    break playback
                }

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
        // A chain failure is cancelled AND named — the run did not complete, and the reason
        // reaches the user instead of a silent skip.
        if let failure { chainFailure(failure) }
        report(progress, !cancelled)
    }

    /// One level of chain expansion. Returns `.ran` when the child's events all played, or
    /// `.failed` with the run-macro step that couldn't.
    private nonisolated enum ExpansionResult {
        case ran
        case failed(ChainFailure)
        /// Stop was pressed mid-expansion.
        case cancelled
        /// A step's window (or play-into app) is gone; the miss is in the run's WindowMissBox.
        case windowGone
    }

    /// The window-gone report from the worker to the loop: a locked one-slot box, because a
    /// @Sendable closure can't capture the loop's mutable state under strict concurrency.
    private final class WindowMissBox: @unchecked Sendable {
        private let lock = NSLock()
        private var app: String?

        func record(_ bundleID: String) {
            lock.lock(); defer { lock.unlock() }
            app = bundleID
        }

        func take() -> String? {
            lock.lock(); defer { lock.unlock() }
            let taken = app
            app = nil
            return taken
        }

        /// A miss is waiting (read without taking it — the root loop takes it).
        var isPending: Bool {
            lock.lock(); defer { lock.unlock() }
            return app != nil
        }
    }

    /// Plays the macro `id` resolves to, inline: the child's events post at their recorded
    /// offsets from this step's due time, its own run-macro steps recurse (up to the cap),
    /// and anything it holds down joins the parent's held sets so Stop releases it all.
    private nonisolated static func expand(_ id: UUID, chain: ChainedMacros, worker: WorkerThread,
                                           start: UInt64, speed: Double, followWindow: Bool,
                                           heldKeys: inout Set<CGKeyCode>,
                                           heldButtons: inout [MouseButton: CGPoint],
                                           shifts: inout [MouseButton: CGSize],
                                           source: EventSynthesizer.EventSource,
                                           into: PlayIntoApp?,
                                           windowMiss: WindowMissBox,
                                           depth: Int) -> ExpansionResult {
        guard depth <= chain.depthLimit else { return .failed(ChainFailure(stepIndex: 0, macroID: id, depth: depth)) }
        // Resolved AT RUN TIME: a macro deleted since launch is a loud failure, and one
        // renamed or re-saved keeps working.
        guard let child = chain.resolve(id) else {
            return .failed(ChainFailure(stepIndex: 0, macroID: id, depth: nil))
        }
        let missingWindow: @Sendable (String) -> Bool = { app in
            windowMiss.record(app)
            return true
        }
        for event in child.events {
            let due = start + Self.dueOffsetNanos(seconds: event.time, speed: speed)
            guard worker.sleep(untilUptime: due) else { return .cancelled }
            if case let .runMacro(grandchild) = event.action {
                switch expand(grandchild, chain: chain, worker: worker, start: due, speed: speed,
                              followWindow: followWindow, heldKeys: &heldKeys,
                              heldButtons: &heldButtons, shifts: &shifts,
                              source: source, into: into, windowMiss: windowMiss,
                              depth: depth + 1) {
                case .ran: continue
                case let other: return other
                }
            }
            post(event, heldKeys: &heldKeys, heldButtons: &heldButtons, shifts: &shifts,
                 source: source, followWindow: followWindow, into: into, missingWindow: missingWindow)
            // Stop at the miss: the child's later steps must not type on into the front app.
            if windowMiss.isPending { return .windowGone }
        }
        return .ran
    }

    nonisolated private static func post(_ event: MacroEvent, heldKeys: inout Set<CGKeyCode>,
                                         heldButtons: inout [MouseButton: CGPoint],
                                         shifts: inout [MouseButton: CGSize],
                                         source: EventSynthesizer.EventSource,
                                         followWindow: Bool,
                                         into: PlayIntoApp? = nil,
                                         missingWindow: (@Sendable (String) -> Bool)? = nil) {
        // Caps Lock is a toggle, not a held key: replaying its flag would force uppercase.
        let flags = CGEventFlags(rawValue: event.flags).subtracting(.maskAlphaShift)
        // Playing into an app, a step follows only THAT app's window: a click recorded in
        // another app must not shift by the other app's window move.
        let followWindow = followWindow && (into == nil || event.windowAnchor?.bundleID == into?.bundleID)
        switch event.action {
        case let .mouseDown(button, point, clickCount):
            guard let at = Self.bound(point, of: event, followWindow: followWindow,
                                      missingWindow: missingWindow) else { return }
            if let into {
                guard into.mouse(button, down: true, at: at, clickCount: clickCount, flags: flags) else {
                    _ = missingWindow?(into.bundleID)
                    return
                }
            } else {
                EventSynthesizer.postMouse(.mouseMoved, button: .left, at: at, flags: flags, source: source)
                EventSynthesizer.postMouse(button.downEventType, button: button, at: at, clickCount: clickCount,
                                           flags: flags, source: source)
            }
            heldButtons[button] = at
            shifts[button] = CGSize(width: at.x - point.x, height: at.y - point.y)
        case let .mouseUp(button, point, clickCount):
            // No fabricated drag transition (review finding 6): a recording carries only what
            // was recorded, and replay posts exactly that — a synthetic dragged event at the
            // release point reads to apps as a jump-click, not the drag the user made.
            // The up moves by the SAME shift its down got: the recorder anchors only downs, so
            // an up translated on its own played verbatim and split a moved-window click into
            // a drag from the new spot back to the old one (2026-09-26).
            let at: CGPoint
            if let shift = shifts.removeValue(forKey: button) {
                at = CGPoint(x: point.x + shift.width, y: point.y + shift.height)
            } else {
                guard let bound = Self.bound(point, of: event, followWindow: followWindow,
                                             missingWindow: missingWindow) else { return }
                at = bound
            }
            heldButtons[button] = nil
            if let into {
                if !into.mouse(button, down: false, at: at, clickCount: clickCount, flags: flags) {
                    _ = missingWindow?(into.bundleID)
                }
                return
            }
            EventSynthesizer.postMouse(button.upEventType, button: button, at: at, clickCount: clickCount,
                                       flags: flags, source: source)
        case let .keyDown(code, isRepeat):
            if let into {
                guard into.key(code, text: event.textOverride, down: true, flags: flags, isRepeat: isRepeat) else {
                    _ = missingWindow?(into.bundleID)
                    return
                }
                if event.textOverride == nil { heldKeys.insert(code) }
            } else if let text = event.textOverride {
                EventSynthesizer.postText(text, down: true, flags: flags, source: source)
            } else {
                EventSynthesizer.postKey(code, down: true, flags: flags, isRepeat: isRepeat, source: source)
                heldKeys.insert(code)
            }
        case let .keyUp(code):
            if let into {
                // A text step rides virtual key 0 (the "a" key) — it must not erase a held a.
                if event.textOverride == nil { heldKeys.remove(code) }
                if !into.key(code, text: event.textOverride, down: false, flags: flags, isRepeat: false) {
                    _ = missingWindow?(into.bundleID)
                }
            } else if let text = event.textOverride {
                EventSynthesizer.postText(text, down: false, flags: flags, source: source)
            } else {
                EventSynthesizer.postKey(code, down: false, flags: flags, source: source)
                heldKeys.remove(code)
            }
        case let .scroll(point, dx, dy):
            // Playing into an app, the cursor stays with the user: a scroll or a move has no
            // app-aimed route (not measured), so it is skipped — never sent through the real
            // cursor into whatever the user is doing. The UI says so next to the picker.
            guard into == nil else { return }
            EventSynthesizer.postScroll(dx: dx, dy: dy, at: point, flags: flags, source: source)
        case let .move(point):
            guard into == nil else { return }
            EventSynthesizer.postMouse(.mouseMoved, button: .left, at: point, flags: flags, source: source)
        case let .runMacro(id):
            // Handled by the play loop's expansion; posting here would double-run the child.
            // Kept as a no-op so the switch stays exhaustive for hand-built event lists.
            _ = id
        }
    }

    /// The point to post for a mouse step under "Follow the window" (F-14): an anchored
    /// step translates by the window's move since recording — the window's CURRENT origin
    /// is resolved live, so a window moved between passes follows too. The window gone
    /// at replay fails LOUD through `missingWindow` — never a click into whatever now
    /// sits at the recorded coordinates.
    ///
    /// Returns nil when the step should play verbatim: unanchored, the toggle off, or the
    /// app no longer running (an app that quit can't have moved — its clicks play where
    /// they were recorded, which for a quit app is moot anyway).
    nonisolated private static func boundPoint(_ point: CGPoint, of event: MacroEvent,
                                               followWindow: Bool,
                                               missingWindow: (@Sendable (String) -> Bool)?) -> CGPoint? {
        guard followWindow, let anchor = event.windowAnchor else { return point }
        // The app quit: nothing to follow, the recorded point stands.
        guard let pid = BackgroundPoster.pidResolver(anchor.bundleID) else { return point }
        let windows = BackgroundPoster.resolveWindowsLive(ofPID: pid)
        // A window still at the recorded origin means nothing moved: the point stands.
        // Measuring against the app's FRONT window instead shifted every click in a
        // multi-window app by the gap between two unrelated windows (2026-09-26).
        if windows.contains(where: { $0.bounds.origin == anchor.origin }) { return point }
        guard let window = windows.first else {
            // The app runs but no window resolves: LOUD, the run can't promise this click.
            if let missingWindow, missingWindow(anchor.bundleID) { return nil }
            return point
        }
        return WindowBinding.translated(point, recordedOrigin: anchor.origin,
                                        currentOrigin: window.bounds.origin)
    }

    /// The posted point for a mouse step: translated when the binding resolves one, the
    /// recorded point otherwise. Nil = the caller cancelled the run (window gone).
    nonisolated private static func bound(_ point: CGPoint, of event: MacroEvent,
                                         followWindow: Bool,
                                         missingWindow: (@Sendable (String) -> Bool)?) -> CGPoint? {
        boundPoint(point, of: event, followWindow: followWindow, missingWindow: missingWindow)
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
                                            source: EventSynthesizer.EventSource, into: PlayIntoApp?) {
        if let into {
            // Released where they were pressed — in the app, never through the real cursor.
            for code in keys { _ = into.key(code, text: nil, down: false, flags: [], isRepeat: false) }
            for (button, point) in buttons { _ = into.mouse(button, down: false, at: point, clickCount: 1, flags: []) }
            return
        }
        for code in keys {
            EventSynthesizer.postKey(code, down: false, flags: [], source: source)
        }
        for (button, point) in buttons {
            EventSynthesizer.postMouse(button.upEventType, button: button, at: point, source: source)
        }
    }
}

extension MacroPlayer {
    /// Apps measured to throw away input that arrives while they aren't the front app:
    /// Roblox (2026-09-20, macOS 26.5.2 — a backgrounded Roblox was pixel-identical before and
    /// after posted clicks while every post reported success). A game in this set is refused
    /// at launch with that reason, instead of a run that silently does nothing.
    nonisolated static let ignoresBackgroundInput: [String: String] = [
        "com.roblox.RobloxPlayer": "Roblox",
    ]

    /// Every app a run will look up by bundle id: the play-into target and each window anchor.
    nonisolated static func bundleIDsToPrewarm(for macro: Macro, playInto: String,
                                               resolve: ChainedMacros.Resolver?) -> Set<String> {
        var ids = Set(macro.events.compactMap(\.windowAnchor?.bundleID) + [playInto])
        // Chained macros' anchors too (the launch check already refused cycles; `seen` keeps
        // a diamond from loading one macro twice).
        if let resolve {
            var queue = ChainingRules.children(of: macro)
            var seen = Set<UUID>()
            while let id = queue.popLast() {
                guard seen.insert(id).inserted, let child = resolve(id) else { continue }
                ids.formUnion(child.events.compactMap(\.windowAnchor?.bundleID))
                queue.append(contentsOf: ChainingRules.children(of: child))
            }
        }
        return ids.filter { !$0.isEmpty }
    }

    /// The launch check for "Play into": nil = fine to start. The string is shown to the user.
    nonisolated static func playIntoProblem(bundleID: String, isRunning: Bool) -> String? {
        guard !bundleID.isEmpty else { return nil }
        if let game = ignoresBackgroundInput[bundleID] {
            return "\(game) ignores clicks and keys while it isn't the front app (tested on this Mac) — macOS gives input to one app at a time, and games only take it while they're in front. Set “Play into” back to “Where the cursor is” and play with \(game) in front."
        }
        guard isRunning else { return "The app to play into isn't running. Open it, then press Play." }
        guard BackgroundPoster.targetingSupported else {
            return BackgroundPoster.windowTargetingProblem ?? "This macOS build doesn't support playing into an app in the background."
        }
        return nil
    }

    /// "Play into" delivery for one run: steps go straight into the app's process, aimed at
    /// its window — the Auto Clicker's measured "Send to app" route (window-aimed events, the
    /// primer lead-in, and the activation Chromium-class apps need, sent before the first
    /// click into each window; it tells the user's front app it lost focus). Keys alone never
    /// activate. Worker-thread only: one run's loop is its sole caller.
    final class PlayIntoApp: @unchecked Sendable {
        let bundleID: String
        private let activator = BackgroundPoster.Activator()
        /// Each held button's window and gesture id, so its release aims where it pressed.
        private var pressed: [MouseButton: (window: BackgroundPoster.Window, group: Int64)] = [:]

        init(bundleID: String) { self.bundleID = bundleID }

        /// False = the app is gone, no window of it contains the point, or the event couldn't be
        /// aimed. The window is looked up LIVE per press (a macro's clicks move between windows;
        /// the Auto Clicker's 300 ms cache aimed a quick second click at the first window), and
        /// a point outside every window is refused — never aimed at the front window instead.
        func mouse(_ button: MouseButton, down: Bool, at point: CGPoint, clickCount: Int,
                   flags: CGEventFlags) -> Bool {
            guard let pid = BackgroundPoster.pidResolver(bundleID) else { return false }
            if !down, let held = pressed.removeValue(forKey: button) {
                return BackgroundPoster.press(button, down: false, screenPoint: point, clickCount: clickCount,
                                              window: held.window, pid: pid, group: held.group, flags: flags)
            }
            guard let window = BackgroundPoster.resolveWindowLive(ofPID: pid, containing: point),
                  window.bounds.contains(point) else { return false }
            activator.activateIfNeeded(pid: pid, windowID: window.id)
            let group = BackgroundPoster.newClickGroup()
            guard BackgroundPoster.press(button, down: down, screenPoint: point, clickCount: clickCount,
                                         window: window, pid: pid, group: group, flags: flags) else { return false }
            if down { pressed[button] = (window, group) }
            return true
        }

        /// One key transition (or typed text) into the app. Modifier keys go as flagsChanged
        /// with their own flag, exactly like the real-cursor replay posts them.
        func key(_ code: CGKeyCode, text: String?, down: Bool, flags: CGEventFlags, isRepeat: Bool) -> Bool {
            guard let pid = BackgroundPoster.pidResolver(bundleID) else { return false }
            if let text {
                BackgroundPoster.textEvent(text, down: down, pid: pid)
                return true
            }
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return false }
            if KeyCodes.modifierKey(for: code) != nil { event.type = .flagsChanged }
            if isRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            BackgroundPoster.postKey(event, flags: flags.union(KeyCodes.intrinsicFlags(for: code)), pid: pid)
            return true
        }
    }
}
