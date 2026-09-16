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
                PermissionRow(title: "Automation", detail: "Asked the first time Web Target controls Safari or Chrome.",
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
