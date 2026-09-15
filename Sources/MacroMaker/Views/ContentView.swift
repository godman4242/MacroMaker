import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if !model.permissions.isAccessibilityTrusted {
                PermissionBanner()
            }
            TabView(selection: $model.selectedTab) {
                AutoClickerView()
                    .tabItem { Label("Auto Clicker", systemImage: "cursorarrow.click.2") }
                    .tag(AppTab.autoClicker)
                KeyPresserView()
                    .tabItem { Label("Key Presser", systemImage: "keyboard") }
                    .tag(AppTab.keyPresser)
                WebTargetView()
                    .tabItem { Label("Web Target", systemImage: "globe") }
                    .tag(AppTab.webTarget)
                RecorderView()
                    .tabItem { Label("Macro Recorder", systemImage: "record.circle") }
                    .tag(AppTab.recorder)
            }
            .padding(12)
        }
    }
}
