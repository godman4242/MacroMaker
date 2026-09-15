import SwiftUI

/// Shown at the top of the main window until Accessibility access is granted.
struct PermissionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Macro Maker needs Accessibility access")
                    .font(.headline)
                Text("macOS only lets apps you approve click and type for you. Click Grant Access, then switch Macro Maker on in the list.")
                    .wrapsText()
                Text("Already switched on but still blocked? Select Macro Maker in the list, remove it with −, then add it again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .wrapsText()
            }
            Spacer(minLength: 0)
            Button("Grant Access…") {
                model.permissions.requestAccessibility()
                model.permissions.open(.accessibility)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding([.horizontal, .top], 12)
    }
}

extension View {
    /// Lets long text wrap inside Forms and HStacks instead of truncating.
    func wrapsText() -> some View {
        fixedSize(horizontal: false, vertical: true)
    }
}

/// A coloured icon + message, used for inline results and errors.
struct StatusMessage: View {
    enum Kind {
        case success, warning, error, info
    }

    let kind: Kind
    let text: String

    var body: some View {
        Label {
            Text(text).wrapsText()
        } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
        .font(.callout)
    }

    private var icon: String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .info: "info.circle.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .success: .green
        case .warning: .yellow
        case .error: .red
        case .info: .blue
        }
    }
}
