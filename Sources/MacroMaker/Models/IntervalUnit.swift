import Foundation

/// Display units for an interval; settings always store canonical milliseconds.
enum IntervalUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case milliseconds, seconds, minutes, hours

    var id: Self { self }

    var suffix: String {
        switch self {
        case .milliseconds: "ms"
        case .seconds: "s"
        case .minutes: "min"
        case .hours: "hr"
        }
    }

    private var millisecondsPerUnit: Double {
        switch self {
        case .milliseconds: 1
        case .seconds: 1_000
        case .minutes: 60_000
        case .hours: 3_600_000
        }
    }

    func toMilliseconds(_ value: Double) -> Double { value * millisecondsPerUnit }
    func fromMilliseconds(_ milliseconds: Double) -> Double { milliseconds / millisecondsPerUnit }

    /// The interval ceiling the whole app enforces, in canonical ms.
    static let maximumIntervalMs: Double = 3_600_000

    /// Sensible edit range in this unit, never exceeding the ceiling.
    var displayRange: ClosedRange<Double> {
        switch self {
        case .milliseconds: 1...Self.maximumIntervalMs
        case .seconds: 0.1...3_600
        case .minutes: 0.1...60
        case .hours: 0.1...1
        }
    }

    var step: Double {
        switch self {
        case .milliseconds: 10
        case .seconds: 0.5
        case .minutes: 0.5
        case .hours: 0.1
        }
    }
}

/// Human-readable click-rate descriptions ("every 2 min ≈ 0.0083 CPS").
enum ClickRate {
    /// e.g. "About 10 clicks per second." or "One click every 2 min ≈ 0.0083 CPS."
    static func describe(intervalMs: Double, burstSize: Int = 1) -> String {
        let interval = max(intervalMs, 1)
        let perSecond = Double(max(1, burstSize)) * 1_000 / interval
        if perSecond >= 0.1 {
            return "About \(perSecond.formatted(.number.precision(.fractionLength(0...1)))) clicks per second."
        }
        return "One click every \(describeInterval(interval)) ≈ \(perSecond.formatted(.number.precision(.fractionLength(2...4)))) CPS."
    }

    static func describeInterval(_ intervalMs: Double) -> String {
        switch max(intervalMs, 1) {
        case ..<1_000:
            "\(Int(intervalMs.rounded())) ms"
        case ..<60_000:
            "\((intervalMs / 1_000).formatted(.number.precision(.fractionLength(0...1)))) s"
        case ..<3_600_000:
            "\((intervalMs / 60_000).formatted(.number.precision(.fractionLength(0...1)))) min"
        default:
            "\((intervalMs / 3_600_000).formatted(.number.precision(.fractionLength(0...2)))) hr"
        }
    }
}
