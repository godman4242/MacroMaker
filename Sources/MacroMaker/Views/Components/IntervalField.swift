import SwiftUI

/// A number field bound to canonical milliseconds, with a ms / s / min / hr unit picker
/// (the "2-minute clicks without mental math" field).
struct IntervalField: View {
    let title: String
    @Binding var milliseconds: Double
    @Binding var unit: IntervalUnit

    init(title: String = "Click every", milliseconds: Binding<Double>, unit: Binding<IntervalUnit>) {
        self.title = title
        _milliseconds = milliseconds
        _unit = unit
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: displayed, format: .number.precision(.fractionLength(0...3)))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 96)
                Stepper(title, value: displayed, in: unit.displayRange, step: unit.step)
                    .labelsHidden()
                Picker(title, selection: $unit) {
                    ForEach(IntervalUnit.allCases) { unit in
                        Text(unit.suffix).tag(unit)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var displayed: Binding<Double> {
        Binding(
            get: { unit.fromMilliseconds(milliseconds) },
            set: { newValue in
                let bounded = min(max(newValue, unit.displayRange.lowerBound), unit.displayRange.upperBound)
                let ms = unit.toMilliseconds(bounded)
                let clampedMs = min(max(ms, 1), IntervalUnit.maximumIntervalMs)
                if clampedMs != milliseconds { milliseconds = clampedMs }
            }
        )
    }
}
