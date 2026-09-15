import SwiftUI

@main
struct MacroMakerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(AppModel.shared)
        } label: {
            MenuBarIcon(model: AppModel.shared)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { WindowCoordinator.shared.show(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

private struct MenuBarIcon: View {
    let model: AppModel

    var body: some View {
        Image(systemName: model.isAnythingActive ? "cursorarrow.rays" : "cursorarrow.click.2")
            .accessibilityLabel(model.isAnythingActive ? "Macro Maker (running)" : "Macro Maker")
    }
}
