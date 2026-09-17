import SwiftUI

/// The main window: a NavigationSplitView whose sidebar groups the features
/// (Automate: clickers · Record: recorder and library) and whose detail shows the
/// selected feature below a status hero that always says what Macro Maker is doing.
struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $model.selectedTab) {
                Section("Automate") {
                    sidebarRow("Auto Clicker", icon: "cursorarrow.click.2",
                               phase: model.autoClicker.session.phase, tab: .autoClicker)
                    sidebarRow("Key Presser", icon: "keyboard",
                               phase: model.keyPresser.session.phase, tab: .keyPresser)
                    sidebarRow("Web Target", icon: "globe",
                               phase: model.webClicker.session.phase, tab: .webTarget)
                }
                Section("Record") {
                    sidebarRow("Macro Recorder", icon: "record.circle",
                               phase: model.recorder.isRecording ? .running : model.player.session.phase,
                               tab: .recorder)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            VStack(spacing: 0) {
                if !model.permissions.isAccessibilityTrusted {
                    PermissionBanner()
                }
                StatusHero()
                Divider()
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView()
        }
    }

    @ViewBuilder private var detailView: some View {
        // The form-based tabs are taller than any sane window; the ScrollView bounds the
        // layout to the window and keeps every section reachable. RecorderView manages its
        // own height internally and must NOT sit in a ScrollView.
        switch model.selectedTab {
        case .autoClicker: ScrollView { AutoClickerView() }
        case .keyPresser: ScrollView { KeyPresserView() }
        case .webTarget: ScrollView { WebTargetView() }
        case .recorder: RecorderView()
        }
    }

    private func sidebarRow(_ title: String, icon: String, phase: RunPhase, tab: AppTab) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if phase.isActive {
                    Circle()
                        .fill(phase.tint)
                        .frame(width: 8, height: 8)
                }
            }
        } icon: {
            Image(systemName: icon)
        }
        .tag(tab)
    }
}

/// One glance answers "is it doing anything?" — the strongest active phase wins,
/// and a paused run says why it paused.
private struct StatusHero: View {
    @Environment(AppModel.self) private var model

    /// Priority: an error-y paused run outranks a running one in another feature.
    private var worst: (title: String, phase: RunPhase)? {
        let candidates: [(String, RunPhase)] = [
            ("Auto Clicker", model.autoClicker.session.phase),
            ("Key Presser", model.keyPresser.session.phase),
            ("Web Target", model.webClicker.session.phase),
            ("Macro Player", model.player.session.phase),
        ]
        if let paused = candidates.first(where: { $0.1 == .paused }) { return paused }
        if let running = candidates.first(where: { $0.1 == .running }) { return running }
        if let counting = candidates.first(where: { if case .countdown = $0.1 { return true }; return false }) { return counting }
        if model.recorder.isRecording { return ("Macro Recorder", .running) }
        return nil
    }

    var body: some View {
        HStack(spacing: 10) {
            if let (title, phase) = worst {
                Circle()
                    .fill(phase.tint)
                    .frame(width: 10, height: 10)
                Text("\(title): \(phase.statusLabel)")
                    .font(.callout.weight(.medium))
            } else {
                Image(systemName: "moon.zzz")
                    .foregroundStyle(.secondary)
                Text("Idle — pick a feature on the left or press its shortcut")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if model.isAnythingActive {
                Button("Stop All") { model.stopAll() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
