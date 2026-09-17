import SwiftUI

/// Clamping shared by every numeric settings field.
///
/// `.number`'s parse strategy accepts "nan"/"NaN"/"NAN" and yields `Double.nan` (measured), and
/// a NaN passes straight through `min(max(v, lo), hi)` because Swift's min/max propagate it —
/// while `bounded != value` is true for NaN, so the write went ahead. Downstream that is fatal:
/// the integer field bridges through `Int(_:rounded())`, which traps on NaN (measured, exit 133),
/// and a NaN interval turns into the 1ms floor via `max(minimumDelay, nan)` — a click storm —
/// in a settings blob `JSONEncoder` then refuses, so every later save is silently dropped.
enum FieldValue {
    /// The value to store, or nil when it must be ignored rather than written.
    static func stored(_ newValue: Double, in range: ClosedRange<Double>) -> Double? {
        guard newValue.isFinite else { return nil }
        return min(max(newValue, range.lowerBound), range.upperBound)
    }
}

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
                TextField(title, value: clamped, format: .number.precision(.fractionLength(0...3)))
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
                guard let bounded = FieldValue.stored(newValue, in: range) else { return }
                if bounded != value { value = bounded }
            }
        )
    }
}
