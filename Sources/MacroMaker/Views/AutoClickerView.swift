import SwiftUI

struct AutoClickerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var clicker = model.autoClicker
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Mouse button", selection: $clicker.settings.button) {
                        ForEach(MouseButton.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    NumberField("Click every", value: $clicker.settings.intervalMs, unit: "ms", range: 0.1...3_600_000, step: 10)
                    Toggle("Add a random offset to each interval", isOn: $clicker.settings.randomizeInterval)
                    if clicker.settings.randomizeInterval {
                        NumberField("Offset up to ±", value: $clicker.settings.randomOffsetMs, unit: "ms", range: 0...60_000, step: 5)
                    }
                } header: {
                    Text("Clicking")
                } footer: {
                    Text(rateDescription(clicker.settings))
                }

                Section("Position") {
                    Picker("Click at", selection: $clicker.settings.target) {
                        Text("Wherever the cursor is").tag(AutoClickerSettings.Target.cursor)
                        Text("A fixed point on screen").tag(AutoClickerSettings.Target.fixedPoint)
                    }
                    .pickerStyle(.radioGroup)
                    if clicker.settings.target == .fixedPoint {
                        NumberField("X", value: $clicker.settings.x, unit: "pt", range: -20_000...20_000)
                        NumberField("Y", value: $clicker.settings.y, unit: "pt", range: -20_000...20_000)
                        HStack {
                            if let secondsLeft = clicker.pickCountdown {
                                StatusMessage(kind: .info, text: "Hover over the target… capturing in \(secondsLeft)")
                                Spacer()
                                Button("Cancel") { clicker.cancelPick() }
                            } else {
                                Text("Points from the top-left corner of the main display.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Pick with Cursor…") { clicker.pickFixedPoint() }
                            }
                        }
                    }
                }

                Section("Stop automatically") {
                    Toggle("After a number of clicks", isOn: $clicker.settings.stopAfterClicks)
                    if clicker.settings.stopAfterClicks {
                        NumberField("Clicks", value: $clicker.settings.maxClicks, unit: "", range: 1...10_000_000)
                    }
                    Toggle("After a time limit", isOn: $clicker.settings.stopAfterDuration)
                    if clicker.settings.stopAfterDuration {
                        NumberField("Time limit", value: $clicker.settings.maxDurationSeconds, unit: "sec", range: 0.1...86_400)
                    }
                }

                Section("Shortcut") {
                    LabeledContent("Start / stop clicking") {
                        HotkeyField(action: .toggleAutoClicker)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(clicker.session.phase.isActive)

            RunControls(session: clicker.session,
                        startTitle: "Start Clicking",
                        hotkey: .toggleAutoClicker,
                        detail: "\(clicker.clickCount.formatted()) clicks") {
                clicker.toggle(.button)
            }
        }
    }

    private func rateDescription(_ settings: AutoClickerSettings) -> String {
        let perSecond = 1000 / max(settings.intervalMs, 1)
        let rate = perSecond >= 1
            ? "About \(perSecond.formatted(.number.precision(.fractionLength(0...1)))) clicks per second"
            : "One click every \((settings.intervalMs / 1000).formatted(.number.precision(.fractionLength(0...1)))) seconds"
        return settings.randomizeInterval ? "\(rate), each interval varied by up to ±\(Int(settings.randomOffsetMs)) ms." : "\(rate)."
    }
}
