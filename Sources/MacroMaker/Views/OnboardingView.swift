import SwiftUI

/// First-run sheet: grants Accessibility (the one permission everything needs), offers a safe
/// test click, and is dismissed forever with a "Skip" or after granting. Shown once; a
/// UserDefaults flag (`hasSeenOnboarding`) remembers.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Macro Maker")
                .font(.title2.weight(.semibold))
            Text("It clicks and types for you, exactly where you tell it. macOS asks for your permission first — that approval is what keeps other apps honest, and Macro Maker can't do anything without it.")
                .wrapsText()

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.permissions.isAccessibilityTrusted ? "checkmark.circle.fill" : "hand.raised.fill")
                    .font(.title2)
                    .foregroundStyle(model.permissions.isAccessibilityTrusted ? .green : .orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.permissions.isAccessibilityTrusted ? "Accessibility access granted" : "1. Grant Accessibility access")
                        .font(.headline)
                    if !model.permissions.isAccessibilityTrusted {
                        Text("Click Grant, then switch Macro Maker on in the list that opens.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .wrapsText()
                        Button("Grant Access…") {
                            model.permissions.requestAccessibility()
                            model.permissions.open(.accessibility)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            if model.permissions.isAccessibilityTrusted {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "cursorarrow.click.2")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("2. Try it")
                            .font(.headline)
                        Text("Click once right where the cursor is — nothing moves, nothing types.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .wrapsText()
                        Button("Test Click") {
                            EventSynthesizer.click(.left, at: nil, holdFor: 0)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button(model.permissions.isAccessibilityTrusted ? "Get Started" : "Skip for Now") {
                    model.dismissOnboarding()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
