import Foundation
import Testing
@testable import MacroMaker

/// A small deterministic RNG (SplitMix64) so distribution tests are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct HumanizerMathTests {
    @Test func boxMullerIsStandardNormal() {
        var rng = SplitMix64(seed: 42)
        var samples: [Double] = []
        for _ in 0..<20_000 {
            let u1 = Double.random(in: 0...1, using: &rng)
            let u2 = Double.random(in: 0...1, using: &rng)
            samples.append(HumanizerMath.boxMuller(u1: max(u1, 1e-12), u2: u2))
        }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let variance = samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(samples.count)
        #expect(abs(mean) < 0.03)
        #expect(abs(variance - 1) < 0.06)
    }

    @Test func boxMullerHandlesEdgeUniforms() {
        // u1 = 0 would be -inf without the remap; it must stay finite.
        #expect(HumanizerMath.boxMuller(u1: 0, u2: 0).isFinite)
        #expect(HumanizerMath.boxMuller(u1: 1, u2: 0) == 0, "log(1) = 0")
        #expect(HumanizerMath.boxMuller(u1: 1, u2: 0.25) == 0)
    }

    @Test func gaussianOffsetNeverExceedsThreeSigma() {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<10_000 {
            let offset = HumanizerMath.gaussianOffset(u1: Double.random(in: 0...1, using: &rng),
                                                      u2: Double.random(in: 0...1, using: &rng),
                                                      sigma: 0.05)
            #expect(abs(offset) <= 0.15 + 1e-12)
        }
        #expect(HumanizerMath.gaussianOffset(u1: 0.5, u2: 0.75, sigma: -1) == 0, "negative sigma clamps to 0")
    }

    @Test func fatigueMultiplierOscillatesBetweenOneAndOnePlusFraction() {
        #expect(HumanizerMath.fatigueMultiplier(tick: 0, cycleTicks: 100, fraction: 0.3) == 1)
        #expect(HumanizerMath.fatigueMultiplier(tick: 50, cycleTicks: 100, fraction: 0.3) == 1.3)
        #expect(HumanizerMath.fatigueMultiplier(tick: 100, cycleTicks: 100, fraction: 0.3) == 1)
        // Disabled paths.
        #expect(HumanizerMath.fatigueMultiplier(tick: 50, cycleTicks: 0, fraction: 0.3) == 1)
        #expect(HumanizerMath.fatigueMultiplier(tick: 50, cycleTicks: 100, fraction: 0) == 1)
        // Wraps monotonically per cycle.
        #expect(HumanizerMath.fatigueMultiplier(tick: 150, cycleTicks: 100, fraction: 0.3) == 1.3)
    }

    @Test func rhythmBreaksHitTheJitteredPeriod() {
        // period = 100 × (0.75…1.25) = 75 … 125.
        #expect(HumanizerMath.isBreak(tick: 75, intervalTicks: 100, jitterU: 0))
        #expect(HumanizerMath.isBreak(tick: 125, intervalTicks: 100, jitterU: 1))
        #expect(!HumanizerMath.isBreak(tick: 76, intervalTicks: 100, jitterU: 0))
        #expect(!HumanizerMath.isBreak(tick: 0, intervalTicks: 100, jitterU: 0.5), "tick 0 never breaks")
        #expect(!HumanizerMath.isBreak(tick: 100, intervalTicks: 0, jitterU: 0.5), "disabled: interval 0")
    }

    @Test func delayIsFlooredAndFinite() {
        #expect(HumanizerMath.delay(interval: 0.1, offset: -0.2, fatigue: 1) == 0.001)
        #expect(HumanizerMath.delay(interval: 0.1, offset: .nan, fatigue: 1) == 0.001)
        #expect(HumanizerMath.delay(interval: 0.1, offset: 0, fatigue: 0) == 0.001)
        #expect(abs(HumanizerMath.delay(interval: 0.1, offset: 0.02, fatigue: 1.2) - 0.144) < 1e-12)
    }
}

@Suite struct HumanizerTests {
    private func makeSettings(shape: HumanizerSettings.Shape = .gaussian,
                              jitter: Double = 0.05) -> HumanizerSettings {
        var settings = HumanizerSettings()
        settings.enabled = true
        settings.shape = shape
        settings.jitterSeconds = jitter
        settings.fatigueFraction = 0
        settings.breakIntervalTicks = 0
        return settings
    }

    @Test func disabledPassesIntervalsThrough() {
        var humanizer = Humanizer(HumanizerSettings(), rng: SplitMix64(seed: 1))
        #expect(humanizer.nextDelay(interval: 0.123) == 0.123)
        #expect(humanizer.nextDelay(interval: 0.00001) == 0.001, "still floored")
    }

    @Test func uniformJitterStaysInsideTheBand() {
        var humanizer = Humanizer(makeSettings(shape: .uniform, jitter: 0.05), rng: SplitMix64(seed: 2))
        for _ in 0..<1_000 {
            let delay = humanizer.nextDelay(interval: 0.1)
            #expect(delay >= 0.05 - 1e-12)
            #expect(delay <= 0.15 + 1e-12)
        }
    }

    @Test func gaussianJitterIsCentredOnTheInterval() {
        var humanizer = Humanizer(makeSettings(jitter: 0.06), rng: SplitMix64(seed: 3))
        var samples: [Double] = []
        for _ in 0..<2_000 { samples.append(humanizer.nextDelay(interval: 0.2)) }
        let mean = samples.reduce(0, +) / Double(samples.count)
        #expect(abs(mean - 0.2) < 0.005, "clamped gaussian stays centred")
        #expect(samples.allSatisfy { $0 > 0 }, "never negative")
        #expect(samples.allSatisfy { $0 <= 0.2 + 0.06 + 1e-12 }, "never beyond +3σ")
    }

    @Test func fatigueLengthensMidCycleTicks() {
        var settings = makeSettings(jitter: 0)
        settings.fatigueFraction = 0.5
        settings.fatigueCycleTicks = 10
        var humanizer = Humanizer(settings, rng: SplitMix64(seed: 4))
        var delays: [Double] = []
        for _ in 0..<10 { delays.append(humanizer.nextDelay(interval: 0.1)) }
        #expect(delays[5] > delays[0], "middle of the cycle is the slowest")
        #expect(delays[5] <= 0.15 + 1e-12, "never slower than (1 + fraction)×")
        #expect(delays.allSatisfy { $0 >= 0.1 - 1e-12 }, "with zero jitter, fatigue never shortens")
    }

    @Test func rhythmBreaksInsertLongerPauses() {
        var settings = makeSettings(jitter: 0)
        settings.breakIntervalTicks = 5
        settings.breakMinSeconds = 2
        settings.breakMaxSeconds = 3
        var humanizer = Humanizer(settings, rng: SplitMix64(seed: 5))
        var pauses = 0
        for _ in 0..<100 {
            let delay = humanizer.nextDelay(interval: 0.1)
            if delay > 1 {
                pauses += 1
                #expect(delay >= 2 && delay <= 3)
            }
        }
        #expect(pauses >= 10 && pauses <= 40, "~20 breaks in 100 ticks at period 3.75–6.25")
    }

    @Test func settingsAreClampedAtInit() {
        var settings = HumanizerSettings()
        settings.enabled = true
        settings.jitterSeconds = -5
        settings.fatigueFraction = 9
        settings.fatigueCycleTicks = 0
        settings.breakMaxSeconds = 1
        settings.breakMinSeconds = 4
        let humanizer = Humanizer(settings, rng: SplitMix64(seed: 6))
        #expect(humanizer.settings.jitterSeconds == 0)
        #expect(humanizer.settings.fatigueFraction == 1)
        #expect(humanizer.settings.fatigueCycleTicks == 1)
        #expect(humanizer.settings.breakMaxSeconds >= humanizer.settings.breakMinSeconds)
    }

    @Test func replayGapJitterNeverGoesNegative() {
        var humanizer = Humanizer(makeSettings(shape: .gaussian, jitter: 0.2), rng: SplitMix64(seed: 8))
        for _ in 0..<1_000 {
            #expect(humanizer.jittered(gap: 0.05) >= 0)
        }
        var off = Humanizer(HumanizerSettings(), rng: SplitMix64(seed: 9))
        #expect(off.jittered(gap: 1.5) == 1.5, "disabled replay returns the recorded gap")
    }

    @Test func settingsDecodeTolerantly() throws {
        // An older blob with only the fields that existed then.
        let decoded = try JSONDecoder().decode(HumanizerSettings.self, from: Data("{}".utf8))
        #expect(decoded == HumanizerSettings())
        var stored = HumanizerSettings()
        stored.enabled = true
        stored.shape = .uniform
        stored.breakIntervalTicks = 77
        let roundTripped = try JSONDecoder().decode(HumanizerSettings.self,
                                                    from: JSONEncoder().encode(stored))
        #expect(roundTripped == stored)
    }
}
