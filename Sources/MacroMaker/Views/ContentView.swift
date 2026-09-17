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
            // The detail column's root must be a ScrollView with no layout wrapper around it.
            // A ScrollView proposes a bounded height to the split, so the split can never be
            // taller than the window. Wrap it in anything that lays out — a VStack, or even a
            // .safeAreaInset on the ScrollView itself — and the split adopts the detail's full
            // intrinsic height instead (the tab Forms run to ~2742pt): it then draws taller than
            // the window with its top ABOVE the window's, and the sidebar rows render in
            // invisible space off the top of the screen. Identity-only modifiers (.id) are safe.
            // This only reproduces when the app is launched as a .app bundle — a `swift run`
            // binary never shows it — so measure any change here by launching the built bundle
            // and reading the live AX frames, never by running the debug binary.
            // Measured over bundle launches: this shape GOOD 6/6 · VStack root with the
            // ScrollView inside BAD 8/8 · ScrollView under .safeAreaInset BAD 8/8.
            ScrollView {
                // The banner and hero ride along as a pinned section header, so Stop All — the
                // only global emergency stop — stays on screen however far a tab is scrolled.
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        detailView
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    } header: {
                        VStack(spacing: 0) {
                            if !model.permissions.isAccessibilityTrusted {
                                PermissionBanner()
                            }
                            StatusHero()
                            Divider()
                        }
                        .background(.bar)   // opaque: content scrolls underneath the header
                    }
                }
            }
            // Fresh identity per tab, so each tab opens at the top. It has to sit on the
            // ScrollView, not on its content: the scroller's offset belongs to the ScrollView,
            // and rebuilding only the content leaves it where the previous tab was (measured —
            // the recorder opened halfway down its event table).
            .id(model.selectedTab)
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView()
        }
    }

    @ViewBuilder private var detailView: some View {
        // None of these views scrolls itself: the detail-root ScrollView above scrolls the
        // whole page. The recorder's event table is the one thing that still scrolls
        // internally, and it pins its own height there so the two never fight.
        switch model.selectedTab {
        case .autoClicker: AutoClickerView()
        case .keyPresser: KeyPresserView()
        case .webTarget: WebTargetView()
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
