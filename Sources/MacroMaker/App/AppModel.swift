import AppKit

enum AppTab: Hashable {
    case autoClicker, keyPresser, webTarget, recorder
}

/// The app's single source of truth: owns every feature and routes hotkeys to them.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()
    private static let dockIconKey = "showDockIcon"

    let permissions = PermissionService()
    let hotkeys = HotkeyService()
    let keyCapture = KeyCapture()
    let autoClicker: AutoClicker
    let keyPresser: KeyPresser
    let webClicker = WebClicker()
    let recorder = MacroRecorder()
    let player: MacroPlayer

    /// The macro shown in the recorder tab (last recording or opened file).
    var macro: Macro?
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

    var isAnythingActive: Bool {
        autoClicker.session.phase.isActive || keyPresser.session.phase.isActive
            || webClicker.session.phase.isActive || player.session.phase.isActive || recorder.isRecording
    }

    private init() {
        autoClicker = AutoClicker(permissions: permissions, hotkeys: hotkeys)
        keyPresser = KeyPresser(permissions: permissions)
        player = MacroPlayer(permissions: permissions)
    }

    func launch() {
        applyActivationPolicy()
        if macro == nil { macro = MacroFiles.loadAutosave() }
        permissions.onPermissionMissing = { WindowCoordinator.shared.show(.main) }
        hotkeys.onTrigger = { [weak self] action in self?.perform(action, trigger: .hotkey) }
        hotkeys.activate()
    }

    func shutdown() {
        stopAll()
        MacroFiles.autosave(macro)
    }

    func perform(_ action: HotkeyAction, trigger: StartTrigger) {
        switch action {
        case let .builtin(builtin):
            perform(builtin, trigger: trigger)
        case let .macro(id):
            // Wired up when the macro library section exists; unknown ids are inert.
            _ = id
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
        }
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
            MacroFiles.autosave(macro)
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
        MacroFiles.autosave(nil)
    }

    private func load(_ opened: Macro) {
        player.session.stop()
        macro = opened
        fileError = nil
        MacroFiles.autosave(opened)
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
}
