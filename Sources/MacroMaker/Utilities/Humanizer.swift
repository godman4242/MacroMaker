import Foundation

/// Settings for making automated input look less machine-perfect.
struct HumanizerSettings: Codable, Equatable, Sendable {
    enum Shape: String, Codable, CaseIterable, Identifiable, Sendable {
        case uniform
        case gaussian

        var id: Self { self }
        var title: String { switch self { case .uniform: "Uniform"; case .gaussian: "Bell curve" } }
    }

    var enabled = false
    /// ± seconds of interval jitter (applies on top of the clicker's own random offset).
    var jitterSeconds: Double = 0.05
    var shape: Shape = .gaussian
    /// Intervals drift up to this fraction longer (0.3 = +30 %) and back over a cycle.
    var fatigueFraction: Double = 0.2
    /// One full slow-down-and-recover cycle spans this many ticks.
    var fatigueCycleTicks = 100
    /// Every ~N ticks, take a longer break (0 = never).
    var breakIntervalTicks = 50
    /// The break lasts a uniformly random duration in this range (seconds).
    var breakMinSeconds: Double = 2
    var breakMaxSeconds: Double = 8

    init() {}

    /// Tolerant decoding: every field defaults when missing, so older settings blobs load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        jitterSeconds = try c.decodeIfPresent(Double.self, forKey: .jitterSeconds) ?? 0.05
        shape = try c.decodeIfPresent(Shape.self, forKey: .shape) ?? .gaussian
        fatigueFraction = try c.decodeIfPresent(Double.self, forKey: .fatigueFraction) ?? 0.2
        fatigueCycleTicks = try c.decodeIfPresent(Int.self, forKey: .fatigueCycleTicks) ?? 100
        breakIntervalTicks = try c.decodeIfPresent(Int.self, forKey: .breakIntervalTicks) ?? 50
        breakMinSeconds = try c.decodeIfPresent(Double.self, forKey: .breakMinSeconds) ?? 2
        breakMaxSeconds = try c.decodeIfPresent(Double.self, forKey: .breakMaxSeconds) ?? 8
    }
}

/// Pure timing transforms; no clocks, so every path is testable with an injected RNG.
enum HumanizerMath {
    /// Standard-normal sample via Box–Muller. `u1` ∈ (0,1] (0 is remapped), `u2` ∈ [0,1].
    static func boxMuller(u1: Double, u2: Double) -> Double {
        (-2 * log(max(u1, 1e-12))).squareRoot() * cos(2 * .pi * u2)
    }

    /// Bell-curve jitter clamped to ±3σ so an unlucky tail never inverts an interval.
    static func gaussianOffset(u1: Double, u2: Double, sigma: Double) -> Double {
        min(3, max(-3, boxMuller(u1: u1, u2: u2))) * max(0, sigma)
    }

    /// Fatigue multiplier for a tick: 1 + fraction · sin²(π · tick / cycle) — lengthens to
    /// (1 + fraction)× at the cycle's middle and returns to 1× at the ends.
    static func fatigueMultiplier(tick: Int, cycleTicks: Int, fraction: Double) -> Double {
        guard cycleTicks > 0, fraction > 0 else { return 1 }
        let phase = sin(.pi * Double(tick % max(1, cycleTicks)) / Double(max(1, cycleTicks)))
        return 1 + fraction * phase * phase
    }

    /// Whether a break happens at this tick. `jitterU` ∈ [0,1] jitters the period ±25 %.
    static func isBreak(tick: Int, intervalTicks: Int, jitterU: Double) -> Bool {
        guard intervalTicks > 0, tick > 0 else { return false }
        let period = max(1, Int((Double(intervalTicks) * (0.75 + 0.5 * min(1, max(0, jitterU)))).rounded()))
        return tick % period == 0
    }

    /// The final delay: never negative, never below the floor, always finite.
    static func delay(interval: Double, offset: Double, fatigue: Double, floor: Double = 0.001) -> Double {
        let delay = (interval + offset) * max(0, fatigue)
        guard delay.isFinite else { return floor }
        return max(floor, delay)
    }
}

/// A stateful humanizer for one run. Inject a seeded `RandomNumberGenerator` for tests.
/// Non-Sendable by design: `RandomNumberGenerator` has no Sendable requirement, and a
/// Humanizer instance lives on exactly one worker for its run.
struct Humanizer {
    let settings: HumanizerSettings
    private(set) var tick = 0
    var rng: any RandomNumberGenerator

    init(_ settings: HumanizerSettings, rng: any RandomNumberGenerator = SystemRandomNumberGenerator()) {
        var clamped = settings
        clamped.jitterSeconds = max(0, min(600, settings.jitterSeconds))
        clamped.fatigueFraction = max(0, min(1, settings.fatigueFraction))
        clamped.fatigueCycleTicks = max(1, min(1_000_000, settings.fatigueCycleTicks))
        clamped.breakIntervalTicks = max(0, min(1_000_000, settings.breakIntervalTicks))
        clamped.breakMinSeconds = max(0, settings.breakMinSeconds)
        clamped.breakMaxSeconds = max(clamped.breakMinSeconds, settings.breakMaxSeconds)
        self.settings = clamped
        self.rng = rng
    }
}

extension Humanizer {
    /// The delay before the next tick, given the base interval. Advances internal state.
    /// Returns the base interval unchanged (still ≥ its own floor) when disabled.
    mutating func nextDelay(interval: Double) -> Double {
        guard settings.enabled else { return max(0.001, interval) }
        defer { tick += 1 }
        // A rhythm break replaces this tick's interval with the longer pause.
        if HumanizerMath.isBreak(tick: tick + 1, intervalTicks: settings.breakIntervalTicks,
                                 jitterU: Double.random(in: 0...1, using: &rng)) {
            let pause = Double.random(in: settings.breakMinSeconds...settings.breakMaxSeconds, using: &rng)
            return max(0.001, pause)
        }
        let offset: Double
        switch settings.shape {
        case .uniform:
            offset = Double.random(in: -1...1, using: &rng) * settings.jitterSeconds
        case .gaussian:
            offset = HumanizerMath.gaussianOffset(u1: Double.random(in: 0...1, using: &rng),
                                                  u2: Double.random(in: 0...1, using: &rng),
                                                  sigma: settings.jitterSeconds / 3)
        }
        let fatigue = HumanizerMath.fatigueMultiplier(tick: tick, cycleTicks: settings.fatigueCycleTicks,
                                                      fraction: settings.fatigueFraction)
        return HumanizerMath.delay(interval: interval, offset: offset, fatigue: fatigue)
    }

    /// A timing-jittered event gap for macro replay (multiplies the recorded gap).
    mutating func jittered(gap: TimeInterval) -> TimeInterval {
        guard settings.enabled, gap > 0 else { return gap }
        let offset: Double
        switch settings.shape {
        case .uniform:
            offset = Double.random(in: -1...1, using: &rng) * settings.jitterSeconds
        case .gaussian:
            offset = HumanizerMath.gaussianOffset(u1: Double.random(in: 0...1, using: &rng),
                                                  u2: Double.random(in: 0...1, using: &rng),
                                                  sigma: settings.jitterSeconds / 3)
        }
        return max(0, gap + offset)
    }

    /// The humanised replay grid for one pass of a macro: every *recorded* gap survives —
    /// jittered, not zeroed — including the opening gap before the first event. Filling the
    /// caller's buffer (allocated once per run even when the macro loops) keeps an
    /// infinite-loop playback from allocating an array per pass. The buffer must already hold
    /// at least `events.count` slots; extras are left untouched.
    mutating func jitteredTimes(for events: [MacroEvent], into buffer: inout [TimeInterval]) {
        var elapsed = 0.0
        var previous = 0.0
        for (index, event) in events.enumerated() {
            elapsed += jittered(gap: event.time - previous)
            previous = event.time
            buffer[index] = elapsed
        }
    }
}
