import AppKit

enum AppTab: Hashable {
    case autoClicker, keyPresser, webTarget, recorder
}

/// The app's single source of truth: owns every feature and routes hotkeys to them.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()
    private static let dockIconKey = "showDockIcon"
    private static let onboardingKey = "hasSeenOnboarding"

    let permissions = PermissionService()
    let hotkeys = HotkeyService()
    let keyCapture = KeyCapture()
    let autoClicker: AutoClicker
    let keyPresser: KeyPresser
    let webClicker = WebClicker()
    let recorder = MacroRecorder()
    let player: MacroPlayer
    let profiles = ProfileService()
    let library = MacroLibrary()

    /// Plays a library macro by id (per-macro hotkeys). No-op when the id isn't in the library.
    func playMacro(id: UUID) {
        guard let record = library.records.first(where: { $0.id == id }),
              let macro = library.load(record) else {
            NSSound.beep()
            return
        }
        guard !recorder.isRecording else {
            NSSound.beep()
            return
        }
        player.toggle(macro, trigger: .hotkey)
    }

    /// Loads a library record into the player (same as opening its file, without the panel dance).
    func loadFromLibrary(_ record: MacroRecord) {
        guard let loaded = library.load(record) else {
            NSSound.beep()
            return
        }
        loadedRecord = record
        load(loaded)
    }

    /// Whether a library record has its own hotkey; assigning one registers the dynamic action.
    func macroHotkeyAction(for record: MacroRecord) -> HotkeyAction? {
        let action = HotkeyAction.macro(record.id)
        return hotkeys.dynamicActions.contains(action) ? action : nil
    }

    /// Assigns or removes a macro's hotkey. Returns false when the cap (10) is already reached —
    /// the caller shows that as a status message.
    @discardableResult
    func setMacroHotkey(_ enabled: Bool, for record: MacroRecord) -> Bool {
        let action = HotkeyAction.macro(record.id)
        if enabled {
            return hotkeys.addDynamicAction(action)
        }
        hotkeys.removeDynamicAction(action)
        return true
    }

    // MARK: Profiles

    /// A profile of the app's current state, ready to save or export.
    func currentProfile(named name: String) -> Profile {
        var profile = Profile(name: ProfileRules.cleanedName(name))
        profile.autoClicker = autoClicker.settings
        profile.keyPresser = keyPresser.settings
        profile.webTarget = webClicker.settings
        profile.playback = player.settings
        profile.macro = macro
        return profile
    }

    /// Replaces every feature's settings with the profile's, stopping anything running first so
    /// half-applied settings never hit a live worker. Returns the profile applied.
    @discardableResult
    func applyProfile(_ entry: ProfileEntry) -> ProfileEntry {
        stopAll()
        autoClicker.settings = entry.autoClicker
        keyPresser.settings = entry.keyPresser
        webClicker.settings = entry.webTarget
        player.settings = entry.playback
        if let profileMacro = entry.macro { load(profileMacro) }
        return entry
    }

    /// The macro shown in the recorder tab (last recording or opened file).
    var macro: Macro?
    /// The library record `macro` was loaded from ("Edit…" in the Library section), if any.
    /// Step edits persist back to this record — otherwise an edited library macro lived only
    /// in the "Last Recording" autosave, and the Library kept the pre-edit file.
    var loadedRecord: MacroRecord?
    var fileError: String?
    var selectedTab: AppTab = .autoClicker

    /// Menu-bar-only by default; the Dock icon is optional.
    var showDockIcon = UserDefaults.standard.bool(forKey: AppModel.dockIconKey) {
        didSet {
            UserDefaults.standard.set(showDockIcon, forKey: Self.dockIconKey)
            applyActivationPolicy()
            // Changing policy deactivates the app; keep the Settings window in front.
            WindowCoordinator.shared.show(.settings)
        }
    }

    /// First-run sheet, shown until dismissed once.
    var showOnboarding = !UserDefaults.standard.bool(forKey: AppModel.onboardingKey)

    func dismissOnboarding() {
        showOnboarding = false
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
    }

    var isAnythingActive: Bool {
        autoClicker.session.phase.isActive || keyPresser.session.phase.isActive
            || webClicker.session.phase.isActive || player.session.phase.isActive || recorder.isRecording
    }

    // MARK: Scheduled start

    struct Schedule: Codable, Equatable, Sendable {
        var enabled = false
        /// Seconds since the start of today (per ScheduleRules.parseClock).
        var seconds = 18 * 3600.0
        /// Which feature starts when the time arrives.
        var feature = Feature.autoClicker
        enum Feature: String, Codable, CaseIterable, Sendable {
            case autoClicker, keyPresser, webTarget, playback
            var title: String {
                switch self {
                case .autoClicker: "Auto Clicker"
                case .keyPresser: "Key Presser"
                case .webTarget: "Web Target"
                case .playback: "Play Macro"
                }
            }
        }
    }

    private(set) var schedule = Persistence.load(Schedule.self, key: "schedule") ?? Schedule() {
        didSet { Persistence.save(schedule, key: "schedule") }
    }
    /// The wall-clock deadline the armed schedule is waiting for; nil when unarmed.
    private(set) var scheduleDeadline: Date?
    @ObservationIgnored private var scheduleTimer: Timer?

    /// Arms or disarms the scheduled start. Arms at the NEXT occurrence of the clock time
    /// (today if still ahead, otherwise tomorrow).
    func setSchedule(_ updated: Schedule) {
        schedule = updated
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        guard let deadline = ScheduleRules.nextOccurrence(of: updated, from: Date()) else {
            scheduleDeadline = nil
            return
        }
        scheduleDeadline = deadline
        // A repeating timer beats Task.sleep for a deadline that survives menu-bar sleeps well.
        let timer = Timer(timeInterval: max(1, deadline.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.fireSchedule() }
        }
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
    }

    private func fireSchedule() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        let deadline = scheduleDeadline
        scheduleDeadline = nil
        guard schedule.enabled else { return }
        // Auto-disarm after one firing, and re-arm at the same time tomorrow if the user re-enables.
        var disarmed = schedule
        disarmed.enabled = false
        schedule = disarmed
        // A non-repeating Timer does not fire while the machine is asleep; the run loop delivers
        // it the moment the Mac wakes. Starting then is a surprise, not a schedule — it is exactly
        // the surprise-fire the launch-time disarm exists to prevent, and worse, because the user
        // is sitting at the keyboard. Disarm and do nothing.
        guard ScheduleRules.isOnTime(deadline: deadline, now: Date()) else { return }
        // Start-only. Every toggle(_:) STOPS a session that is already active — and `isActive` is
        // true for countdown and paused too — so a "scheduled start" that arrived while the
        // feature was already running used to stop it, then disarm itself and never start it.
        switch schedule.feature {
        case .autoClicker:
            if !autoClicker.session.phase.isActive { autoClicker.toggle(.hotkey) }   // no countdown: deliberately triggered
        case .keyPresser:
            if !keyPresser.session.phase.isActive { keyPresser.toggle(.hotkey) }
        case .webTarget:
            if !webClicker.session.phase.isActive { webClicker.toggle(.hotkey) }
        case .playback:
            if macro != nil, !player.session.phase.isActive { togglePlayback(.hotkey) }
        }
    }

    private init() {
        autoClicker = AutoClicker(permissions: permissions, hotkeys: hotkeys)
        keyPresser = KeyPresser(permissions: permissions)
        player = MacroPlayer(permissions: permissions)
    }

    func launch() {
        applyActivationPolicy()
        TargetSnapshot.shared.start()
        // One-time validation (F14) of the private CGEventSetWindowLocation symbol: present AND
        // behaving as (event, point). A failure disables directApp targeting loudly via
        // `targetingSupported`/`directAppProblem` instead of posting mis-aimed events.
        BackgroundPoster.validateWindowTargeting()
        // Dangling links only: the index is the source of truth, and a hotkey for a macro that
        // was deleted from the library would find nothing at play time.
        let liveIDs = Set(library.records.map(\.id))
        for action in hotkeys.dynamicActions where !liveIDs.contains(action.macroID ?? UUID()) {
            hotkeys.removeDynamicAction(action)
        }
        if macro == nil { macro = MacroFiles.loadAutosave() }
        // A schedule armed when the app last quit keeps its arming if its time is still ahead
        // today; only a missed one is disarmed, so it can't surprise-fire tomorrow. Disarming
        // unconditionally meant the feature never survived a quit — the normal path for a
        // menu-bar login-item app.
        if schedule.enabled {
            if ScheduleRules.staysArmedOnLaunch(schedule, now: Date()) {
                setSchedule(schedule)
            } else {
                var disarmed = schedule
                disarmed.enabled = false
                setSchedule(disarmed)
            }
        }
        permissions.onPermissionMissing = { WindowCoordinator.shared.show(.main) }
        hotkeys.onTrigger = { [weak self] action in self?.perform(action, trigger: .hotkey) }
        // Reassigning the toggle shortcut mid-hold must end the hold-mode run first: the new
        // combo can never release a run it didn't start.
        hotkeys.onToggleReassignedWhileHolding = { [weak self] in
            self?.autoClicker.hotkeyReassigned(for: .toggleAutoClicker)
        }
        hotkeys.activate()
        // Any profile in the list whose macro types text gets the one-time typed-text warning.
        warnAboutTypedTextIfNeeded(in: profiles.entries)
    }

    func shutdown() {
        stopAll()
        // Nothing is on screen to show a warning at quit; MacroFiles logs the failure.
        MacroFiles.autosave(macro)
    }

    func perform(_ action: HotkeyAction, trigger: StartTrigger) {
        switch action {
        case let .builtin(builtin):
            perform(builtin, trigger: trigger)
        case let .macro(id):
            playMacro(id: id)
        }
    }

    func perform(_ action: BuiltinHotkeyAction, trigger: StartTrigger) {
        switch action {
        case .toggleAutoClicker: autoClicker.toggle(trigger)
        case .toggleKeyPresser: keyPresser.toggle(trigger)
        case .toggleWebTarget: webClicker.toggle(trigger)
        case .toggleRecording: toggleRecording()
        case .togglePlayback: togglePlayback(trigger)
        case .stopAll: stopAll()
        case .stopRun: stopActiveRuns()
        }
    }

    /// The stop-run shortcut (default F6): stops anything currently running, without the
    /// recorder-flip and beep dance of Stop Everything (F-11's "press a key to end the run").
    func stopActiveRuns() {
        autoClicker.session.stop()
        keyPresser.session.stop()
        webClicker.session.stop()
        player.session.stop()
    }

    func stopAll() {
        autoClicker.session.stop()
        keyPresser.session.stop()
        webClicker.session.stop()
        player.session.stop()
        if recorder.isRecording { toggleRecording() }
    }

    // MARK: Macros

    func toggleRecording() {
        if recorder.isRecording {
            let events = recorder.stop()
            // An empty recording (e.g. started and stopped by accident) keeps the previous macro.
            guard !events.isEmpty else { return }
            macro = Macro(name: "Recording \(Self.recordingNameFormatter.string(from: Date()))", events: events)
            loadedRecord = nil   // a fresh recording belongs to no library record
            if let warning = MacroFiles.autosave(macro) { fileError = warning }
        } else {
            guard !player.session.phase.isActive else {
                NSSound.beep()
                return
            }
            if !recorder.start() {
                selectedTab = .recorder
                WindowCoordinator.shared.show(.main)
            }
        }
    }

    func togglePlayback(_ trigger: StartTrigger) {
        guard !recorder.isRecording else {
            NSSound.beep()
            return
        }
        player.toggle(macro, trigger: trigger)
    }

    func saveMacro() {
        guard let macro else { return }
        do {
            if let url = try MacroFiles.saveWithPanel(macro) {
                self.macro?.name = url.deletingPathExtension().lastPathComponent
                fileError = nil
            }
        } catch {
            fileError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    func openMacroWithPanel() {
        do {
            if let opened = try MacroFiles.openWithPanel() { load(opened) }
        } catch {
            fileError = "Couldn't open that file: \(Self.describe(error))"
        }
    }

    func openMacro(at url: URL) {
        do {
            load(try MacroFiles.read(from: url))
        } catch {
            fileError = "Couldn't open “\(url.lastPathComponent)”: \(Self.describe(error))"
        }
        selectedTab = .recorder
        WindowCoordinator.shared.show(.main)
    }

    func clearMacro() {
        player.session.stop()
        macro = nil
        loadedRecord = nil
        MacroFiles.autosave(nil)
    }

    /// Writes the current macro to the "Last Recording" autosave (called after step edits too,
    /// so quitting mid-edit doesn't lose them) — and, when the macro was loaded from the
    /// library, back into its own record, so the Library never keeps a stale copy.
    func autosaveMacro() {
        if let warning = MacroFiles.autosave(macro) { fileError = warning }
        if let loadedRecord, let macro {
            if library.update(loadedRecord, with: macro) == nil, let problem = library.lastError {
                fileError = problem
            }
        }
    }

    private func load(_ opened: Macro) {
        player.session.stop()
        macro = opened
        loadedRecord = nil   // callers that load from the library set it right after
        fileError = nil
        if let warning = MacroFiles.autosave(opened) { fileError = warning }
    }

    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    /// No colons: the name becomes the default file name when saving.
    private static let recordingNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    private static func describe(_ error: Error) -> String {
        if case let DecodingError.dataCorrupted(context) = error { return context.debugDescription }
        if error is DecodingError { return "It isn't a valid Macro Maker file." }
        return error.localizedDescription
    }

    // MARK: Typed-text import notice

    private static let typedTextWarningKey = "typedTextWarningShown"

    /// One-time alert: a profile whose macro types real text does so at playback — a file from
    /// someone else could type anything. Shown once per app lifetime (launch + import), not per
    /// profile, so it informs without becoming a dialog tax.
    func warnAboutTypedTextIfNeeded(in entries: [ProfileEntry]) {
        guard !UserDefaults.standard.bool(forKey: Self.typedTextWarningKey) else { return }
        let typing = entries.filter { entry in
            entry.macro?.events.contains { $0.textOverride != nil } ?? false
        }
        guard !typing.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: Self.typedTextWarningKey)
        let names = typing.map(\.name).joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "A profile contains typed text"
        alert.informativeText = "“\(names)” carries recorded keystrokes or typed text — playing its macro types that text wherever the cursor is. Review the macro's steps before playing it."
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}
