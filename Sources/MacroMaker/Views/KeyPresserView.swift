import SwiftUI

struct KeyPresserView: View {
    @Environment(AppModel.self) private var model

    private static let captureID = "keyPresser.key"
    private static let specialKeys: [(title: String, token: String)] = [
        ("Space", "space"), ("Return", "enter"), ("Tab", "tab"), ("Esc", "esc"), ("Delete", "delete"),
        ("↑ Up", "up"), ("↓ Down", "down"), ("← Left", "left"), ("→ Right", "right"),
        ("Home", "home"), ("End", "end"), ("Page Up", "pageup"), ("Page Down", "pagedown"),
    ]

    var body: some View {
        @Bindable var presser = model.keyPresser
        let isCapturing = model.keyCapture.owner == Self.captureID
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Key") {
                        HStack(spacing: 6) {
                            TextField("Key", text: $presser.settings.keyText, prompt: Text("a, !, space, f5, cmd+v"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 200)
                            Menu("Special") {
                                ForEach(Self.specialKeys, id: \.token) { key in
                                    Button(key.title) { presser.settings.keyText = key.token }
                                }
                                Menu("Function keys") {
                                    ForEach(1...20, id: \.self) { number in
                                        Button("F\(number)") { presser.settings.keyText = "f\(number)" }
                                    }
                                }
                            }
                            .fixedSize()
                            Button(isCapturing ? "Press a key…" : "Record") {
                                isCapturing ? model.keyCapture.end() : captureKey()
                            }
                        }
                    }
                    switch presser.parsedKey {
                    case let .success(stroke):
                        if let problem = presser.problem {
                            StatusMessage(kind: .warning, text: problem)
                        } else {
                            StatusMessage(kind: .success, text: "Will press \(stroke.label)")
                        }
                    case let .failure(error):
                        StatusMessage(kind: .error, text: error.localizedDescription)
                    }
                } header: {
                    Text("Key")
                } footer: {
                    Text("Type one character (letters, digits, !@#$…) or a key name: space, enter, tab, esc, delete, up, down, left, right, home, end, pageup, pagedown, f1–f20. Combine with modifiers using +, e.g. cmd+shift+z.")
                }

                Section("Mode") {
                    Picker("Mode", selection: $presser.settings.mode) {
                        Text("Auto press").tag(KeyPresserSettings.Mode.autoPress)
                        Text("Hold down").tag(KeyPresserSettings.Mode.hold)
                    }
                    .pickerStyle(.segmented)
                    if presser.settings.mode == .autoPress {
                        NumberField("Press every", value: $presser.settings.intervalMs, unit: "ms", range: 1...3_600_000, step: 10)
                    } else {
                        Text("Keeps the key pressed until you stop — including auto-repeat, just like holding it with your finger.")
                            .foregroundStyle(.secondary)
                            .wrapsText()
                    }
                }

                if presser.settings.mode == .autoPress {
                    HumanizeSection(settings: $presser.settings.humanizer)
                }

                Section("Shortcut") {
                    LabeledContent("Start / stop") {
                        HotkeyField(action: .toggleKeyPresser)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(presser.session.phase.isActive)

            RunControls(session: presser.session,
                        startTitle: presser.settings.mode == .hold ? "Start Holding" : "Start Pressing",
                        hotkey: .toggleKeyPresser,
                        detail: presser.settings.mode == .hold ? "holding" : "\(presser.pressCount.formatted()) presses",
                        isStartDisabled: presser.problem != nil) {
                presser.toggle(.button)
            }
        }
    }

    private func captureKey() {
        let presser = model.keyPresser
        model.keyCapture.begin(owner: Self.captureID) { event in
            let modifiers = KeyModifiers(event.modifierFlags)
            guard let token = KeyStrokeParser.token(keyCode: CGKeyCode(event.keyCode), modifiers: modifiers,
                                                    layout: KeyboardLayout.current) else {
                NSSound.beep()
                return false
            }
            presser.settings.keyText = token
            return true
        }
    }
}
