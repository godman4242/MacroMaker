import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Show icon in the Dock", isOn: $model.showDockIcon)
            } header: {
                Text("General")
            } footer: {
                Text("Macro Maker always lives in the menu bar. Without a Dock icon it also stays out of ⌘-Tab.")
            }

            Section {
                ProfilesSection(model: model)
            } header: {
                Text("Profiles")
            } footer: {
                Text("A profile is every feature's settings plus the current macro. Export shares it as a file; applying one stops anything running first.")
            }

            Section {
                ScheduleRow(model: model)
            } header: {
                Text("Scheduled start")
            } footer: {
                Text("Starts the chosen feature at a clock time on the next day that time is still ahead. Disarms itself after firing once — re-enable it for the next day.")
            }

            Section {
                ForEach(BuiltinHotkeyAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        HotkeyField(action: .builtin(action))
                    }
                }
                HStack {
                    Spacer()
                    Button("Restore Defaults") { model.hotkeys.restoreDefaults() }
                }
            } header: {
                Text("Keyboard shortcuts")
            } footer: {
                Text("Shortcuts work in every app. Click one, then press the new keys — include ⌃, ⌥ or ⌘. Esc cancels, Delete removes it.")
            }

            Section {
                if let error = model.hotkeys.lastError {
                    StatusMessage(kind: .warning, text: error)
                }
            } header: {
                Text("Save status")
            } footer: {
                Text("Shown only when a change to your shortcuts couldn't be saved.")
            }

            Section {
                PermissionRow(title: "Accessibility", detail: "Required to click and press keys for you.",
                              isGranted: model.permissions.isAccessibilityTrusted) {
                    model.permissions.requestAccessibility()
                    model.permissions.open(.accessibility)
                }
                PermissionRow(title: "Input Monitoring", detail: "Required to record macros.",
                              isGranted: model.permissions.canMonitorInput) {
                    model.permissions.requestInputMonitoring()
                    model.permissions.open(.inputMonitoring)
                }
                PermissionRow(title: "Automation", detail: "Asked the first time Web Target controls Safari, Chrome or Brave.",
                              isGranted: nil) {
                    model.permissions.open(.automation)
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("After rebuilding the app, macOS may treat it as a different app: if a permission shows as granted but doesn't work, remove Macro Maker from that list with −, then add it again.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ScheduleRow: View {
    let model: AppModel
    @State private var clockText = ScheduleRules.clockString(seconds: 18 * 3600)
    @FocusState private var timeFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Start at a time", isOn: Binding(
                    get: { model.schedule.enabled },
                    set: { enabled in
                        var updated = model.schedule
                        updated.enabled = enabled
                        model.setSchedule(updated)
                    }
                ))
                Spacer()
                if let deadline = model.scheduleDeadline {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(ScheduleRules.describe(deadline: deadline, from: context.date))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if model.schedule.enabled {
                HStack(spacing: 12) {
                    TextField("Time", text: $clockText, prompt: Text("7:30"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(commitTime)
                        .onAppear { clockText = ScheduleRules.clockString(seconds: model.schedule.seconds) }
                        // Commit on focus loss as well as Return. The only other path used to be
                        // an `.onChange` looking for a trailing newline — dead code, because a
                        // SwiftUI TextField never puts one in its bound string. So clicking the
                        // Picker, or just closing the window, discarded the typed time, and
                        // `.onAppear` quietly restored the old value the next time it was shown.
                        .focused($timeFocused)
                        .onChange(of: timeFocused) { _, focused in
                            if !focused { commitTime() }
                        }
                    Picker("Starts", selection: Binding(
                        get: { model.schedule.feature },
                        set: { feature in
                            var updated = model.schedule
                            updated.feature = feature
                            model.setSchedule(updated)
                        }
                    )) {
                        ForEach(AppModel.Schedule.Feature.allCases, id: \.self) { feature in
                            Text(feature.title).tag(feature)
                        }
                    }
                    .fixedSize()
                }
            }
        }
    }

    private func commitTime() {
        guard let seconds = ScheduleRules.parseClock(clockText) else { return }
        var updated = model.schedule
        updated.seconds = seconds
        model.setSchedule(updated)
        clockText = ScheduleRules.clockString(seconds: seconds)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    /// nil when macOS gives no way to check in advance.
    let isGranted: Bool?
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(isGranted == true ? "Open Settings" : "Grant…", action: open)
        }
    }

    private var icon: String {
        switch isGranted {
        case true: "checkmark.circle.fill"
        case false: "xmark.circle.fill"
        case nil: "questionmark.circle"
        }
    }

    private var color: Color {
        switch isGranted {
        case true: .green
        case false: .red
        case nil: .secondary
        }
    }
}
