import SwiftUI

/// A labelled number field with a stepper and unit, clamped to a range.
struct NumberField: View {
    let title: String
    @Binding var value: Double
    var unit = ""
    var range: ClosedRange<Double>
    var step: Double = 1

    init(_ title: String, value: Binding<Double>, unit: String = "", range: ClosedRange<Double>, step: Double = 1) {
        self.title = title
        _value = value
        self.unit = unit
        self.range = range
        self.step = step
    }

    /// Convenience for integer settings such as a click count.
    init(_ title: String, value: Binding<Int>, unit: String = "", range: ClosedRange<Int>) {
        self.init(title,
                  value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }),
                  unit: unit,
                  range: Double(range.lowerBound)...Double(range.upperBound))
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: clamped, format: .number.precision(.fractionLength(0...2)))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 96)
                Stepper(title, value: clamped, in: range, step: step)
                    .labelsHidden()
                if !unit.isEmpty {
                    Text(unit)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 24, alignment: .leading)
                }
            }
        }
    }

    private var clamped: Binding<Double> {
        Binding(
            get: { value },
            set: { newValue in
                let bounded = min(max(newValue, range.lowerBound), range.upperBound)
                if bounded != value { value = bounded }
            }
        )
    }
}
