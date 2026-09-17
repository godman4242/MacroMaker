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
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("2. You're ready")
                            .font(.headline)
                        // There used to be a "Test Click" button here that posted a real click at
                        // the cursor. The only way to press it is to click it, so the cursor was
                        // necessarily over the button: the synthetic click landed back on the
                        // button and ran the action again, each pass posting another click.
                        // It also proved nothing — this whole section only renders once macOS has
                        // already granted access. Each feature has its own aimed Test button.
                        Text("macOS has granted access, so Macro Maker can click and type for you. Each tab has its own Test button that clicks where you aim it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .wrapsText()
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
