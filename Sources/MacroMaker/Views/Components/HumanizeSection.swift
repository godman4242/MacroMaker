import SwiftUI

/// The humanisation controls, shared by the clicker, key presser and macro player:
/// bell-curve interval jitter, fatigue drift and rhythm breaks.
struct HumanizeSection: View {
    @Binding var settings: HumanizerSettings
    /// Extra footer sentence, e.g. "Applied to the gap before each replayed event."
    var note: String?

    var body: some View {
        Section {
            Toggle("Humanise the timing", isOn: $settings.enabled)
            if settings.enabled {
                Picker("Variation shape", selection: $settings.shape) {
                    ForEach(HumanizerSettings.Shape.allCases) { shape in
                        Text(shape.title).tag(shape)
                    }
                }
                .pickerStyle(.segmented)
                NumberField("Vary intervals by up to ±",
                            value: $settings.jitterSeconds, unit: "s", range: 0...60, step: 0.01)
                NumberField("Slow down by up to",
                            value: Binding(get: { settings.fatigueFraction * 100 },
                                           set: { settings.fatigueFraction = $0 / 100 }),
                            unit: "%", range: 0...100, step: 5)
                NumberField("over about", value: $settings.fatigueCycleTicks,
                            unit: "ticks", range: 10...100_000)
                NumberField("Take a longer break every", value: $settings.breakIntervalTicks,
                            unit: "ticks", range: 0...100_000)
                if settings.breakIntervalTicks > 0 {
                    NumberField("Break lasts", value: $settings.breakMinSeconds,
                                unit: "s", range: 0...600, step: 0.5)
                    NumberField("up to", value: $settings.breakMaxSeconds,
                                unit: "s", range: 0...3600, step: 0.5)
                }
            }
        } header: {
            Text("Humanise")
        } footer: {
            if settings.enabled {
                Text("Intervals vary around the value you set, gradually slow and recover like a person would, and pause for the occasional longer break.\(note.map { " \($0)" } ?? "")")
                    .font(.caption)
            }
        }
    }
}
