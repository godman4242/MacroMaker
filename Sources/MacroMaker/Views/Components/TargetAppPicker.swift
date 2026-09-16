import SwiftUI

/// A running-apps menu used wherever a feature can deliver events to a specific app.
struct TargetAppPicker: View {
    struct Row: View {
        let name: String
        let bundleID: String

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @Binding var bundleID: String
    /// The live app list, re-read every onAppear so menu opens always show the truth.
    @State private var apps: [BackgroundPoster.ListedApp] = []

    var body: some View {
        LabeledContent("App") {
            HStack(spacing: 6) {
                Menu {
                    if apps.isEmpty { Text("No other apps running") }
                    ForEach(apps) { app in
                        Button { bundleID = app.bundleID } label: {
                            Row(name: app.name, bundleID: app.bundleID)
                        }
                    }
                } label: {
                    Text(label)
                        .lineLimit(1)
                }
                .menuIndicator(.visible)
                .fixedSize()
                Button { apps = BackgroundPoster.targetableApps() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Re-read the list of running apps")
                if !bundleID.isEmpty {
                    Button { bundleID = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear the target app")
                }
            }
        }
        .onAppear { apps = BackgroundPoster.targetableApps() }
    }

    private var label: String {
        guard let app = apps.first(where: { $0.bundleID == bundleID }) else {
            return bundleID.isEmpty ? "Choose an app…" : "\(bundleID) (not running)"
        }
        return app.name
    }
}
