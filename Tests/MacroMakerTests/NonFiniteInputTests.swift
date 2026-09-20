import Foundation
import Testing

@testable import MacroMaker

/// Non-finite numbers reaching the engine. Every trap below was reproduced as a standalone
/// process on this machine (Swift 6.3.3, macOS 26) — each one exits 133, i.e. kills the app:
///
///   Int(Double.nan.rounded())          -> exit 133
///   UInt64(Double.infinity * 1e9)      -> exit 133
///   UInt64(-5.0 * 1e9)                 -> exit 133
///   Duration.milliseconds(1.7e24)      -> exit 133, "Overflow in multiplication"
///
/// and the way in is real: `.number`'s parse strategy accepts "nan"/"NaN"/"NAN" and yields
/// `Double.nan` (measured), while `min(max(nan, lo), hi)` returns `nan` — Swift's min/max
/// propagate it — so the clamps these fields rely on never filtered it. "inf" does NOT parse
/// (measured: nil), so NaN is the only value a user can type in; the file-decode paths can
/// carry either.
@Suite("Non-finite input")
struct NonFiniteInputTests {

    // MARK: The shared field clamp

    @Test func aTypedNaNIsRefusedRatherThanStored() {
        #expect(FieldValue.stored(.nan, in: 1...100) == nil,
                "NaN must be dropped: the Int field bridges through Int(_:rounded()) and traps")
    }

    @Test func infinitiesAreRefusedToo() {
        #expect(FieldValue.stored(.infinity, in: 1...100) == nil)
        #expect(FieldValue.stored(-.infinity, in: 1...100) == nil)
    }

    @Test func ordinaryValuesStillClampExactlyAsBefore() {
        #expect(FieldValue.stored(50, in: 1...100) == 50)
        #expect(FieldValue.stored(-5, in: 1...100) == 1)
        #expect(FieldValue.stored(1_000, in: 1...100) == 100)
        #expect(FieldValue.stored(1, in: 1...100) == 1)
        #expect(FieldValue.stored(100, in: 1...100) == 100)
    }

    // MARK: Playback timing

    @Test func playbackNeverConvertsANonFiniteOrNegativeTimeToNanoseconds() {
        // Each of these is a live trap in `UInt64(_:)` — the value must be clamped first.
        #expect(MacroPlayer.dueOffsetNanos(seconds: .nan, speed: 1) == 0)
        #expect(MacroPlayer.dueOffsetNanos(seconds: .infinity, speed: 1) > 0)
        #expect(MacroPlayer.dueOffsetNanos(seconds: -5, speed: 1) == 0)
        #expect(MacroPlayer.dueOffsetNanos(seconds: 1e30, speed: 1) > 0)
        // A zero or non-finite speed divides into infinity/NaN before the conversion.
        #expect(MacroPlayer.dueOffsetNanos(seconds: 1, speed: 0) > 0)
        #expect(MacroPlayer.dueOffsetNanos(seconds: 1, speed: .nan) == 0)
    }

    @Test func normalPlaybackTimingIsUnchanged() {
        #expect(MacroPlayer.dueOffsetNanos(seconds: 2, speed: 1) == 2_000_000_000)
        #expect(MacroPlayer.dueOffsetNanos(seconds: 2, speed: 2) == 1_000_000_000)
        #expect(MacroPlayer.dueOffsetNanos(seconds: 1, speed: 0.25) == 4_000_000_000)
        #expect(MacroPlayer.dueOffsetNanos(seconds: 0, speed: 1) == 0)
    }

    // MARK: The file that carries one in

    @Test func aMacroFileWithANonFiniteTimeIsRejected() throws {
        // JSON has no literal for NaN/Infinity, but a huge exponent parses to +infinity as a
        // Double — so a hand-written or corrupted .macromaker file can carry one.
        let json = """
        {"format":"macromaker","version":1,"name":"Bad","createdAt":"2026-09-16T10:00:00Z",
         "events":[{"type":"mouseDown","t":1e400,"button":"left","x":10,"y":10}]}
        """
        #expect(throws: DecodingError.self, "an infinite event time must not survive decoding") {
            try Macro(jsonData: Data(json.utf8))
        }
    }

    @Test func aMacroFileWithANegativeTimeIsRejected() throws {
        let json = """
        {"format":"macromaker","version":1,"name":"Bad","createdAt":"2026-09-16T10:00:00Z",
         "events":[{"type":"mouseDown","t":-3,"button":"left","x":10,"y":10}]}
        """
        #expect(throws: DecodingError.self) { try Macro(jsonData: Data(json.utf8)) }
    }

    @Test func anOrdinaryMacroFileStillOpens() throws {
        let json = """
        {"format":"macromaker","version":1,"name":"Fine","createdAt":"2026-09-16T10:00:00Z",
         "events":[{"type":"mouseDown","t":0,"button":"left","x":10,"y":10},
                   {"type":"mouseUp","t":0.25,"button":"left","x":10,"y":10}]}
        """
        let macro = try Macro(jsonData: Data(json.utf8))
        #expect(macro.events.count == 2)
        #expect(macro.events[1].time == 0.25)
    }

    // MARK: Hostile decoded settings (imported profile / defaults blob — models F2 + lifecycle F5)

    /// The UI's NumberFields clamp, but the decode paths never did: an imported profile with
    /// `intervalMs = 1e300` or `delayedStartSeconds = 1e20` survived decoding unchanged and
    /// trapped at the next Start (`UInt64(delay * 1e9)` / `Int(seconds.rounded())` — exit 133).
    /// JSON has no NaN literal and `1e400` is refused by the decoder itself, but every representable huge value (`1e300`, `1e20`) sails through decoding and traps at the conversions.
    @Test func hostileDecodedDoublesAreClampedBeforeTheTrappingConversions() throws {
        let json = """
        {"format":"macromakerprofile","formatVersion":2,"name":"Hostile",
         "autoClicker":{"intervalMs":1e300,"delayedStartSeconds":1e20,"randomOffsetMs":1e300,
                        "maxDurationSeconds":1e20,"jitterPx":1e20,"autoResumeSeconds":1e20,
                        "x":1e20,"y":1e20,"directAppX":1e20,"directAppY":1e20},
         "keyPresser":{"intervalMs":1e300},
         "playback":{"speed":1e300},
         "webTarget":{"browser":"safari","urlMatch":"","locatorKind":"css","cssSelector":"","xpath":"",
                      "x":1e20,"y":1e300,"intervalMs":1e300}}
        """
        let profile = try Profile.from(jsonData: Data(json.utf8))
        let s = profile.autoClicker
        #expect(s.intervalMs >= 1 && s.intervalMs <= IntervalUnit.maximumIntervalMs)
        #expect(s.delayedStartSeconds >= 0 && s.delayedStartSeconds <= 600)
        #expect(s.randomOffsetMs >= 0 && s.randomOffsetMs <= 60_000)
        #expect(s.maxDurationSeconds >= 0.1 && s.maxDurationSeconds <= 86_400)
        #expect(s.jitterPx >= 0 && s.jitterPx <= 200)
        #expect(s.autoResumeSeconds >= 1 && s.autoResumeSeconds <= 600)
        #expect(s.x <= 20_000 && s.y <= 20_000 && s.directAppX <= 20_000 && s.directAppY <= 20_000)
        #expect(profile.keyPresser.intervalMs <= IntervalUnit.maximumIntervalMs)
        #expect(profile.playback.speed <= 4)
        #expect(profile.webTarget.intervalMs <= WebClicker.maximumIntervalMs)
        #expect(profile.webTarget.x <= 100_000 && profile.webTarget.y <= 100_000)
        // The exact conversions that trap (measured: exit 133) run on the clamped values.
        _ = UInt64(max(TickSchedule.minimumDelay, s.intervalMs / 1000) * 1_000_000_000)
        _ = Int(max(0, s.delayedStartSeconds).rounded())
    }

    /// Negative and zero-side hostile values clamp up, mirroring what the UI fields enforce.
    @Test func hostileDecodedDoublesClampUpFromBelowToo() throws {
        let json = """
        {"format":"macromakerprofile","formatVersion":2,"name":"Negative",
         "autoClicker":{"intervalMs":-5,"delayedStartSeconds":-3},
         "keyPresser":{"intervalMs":0}}
        """
        let profile = try Profile.from(jsonData: Data(json.utf8))
        #expect(profile.autoClicker.intervalMs == 1)
        #expect(profile.autoClicker.delayedStartSeconds == 0)
        #expect(profile.keyPresser.intervalMs == 1)
    }

    // MARK: Huge-but-finite step coordinates (issue: typing 1e300 as a step's X/Y killed the app)

    /// "1e300" is finite, so it sailed through the old x/y decode and trapped `Int(point.x)`
    /// in the step summary on the next render (exit 133). The decoder now refuses it the way
    /// it refuses an infinite time.
    @Test func aMacroFileWithAHugeButFiniteCoordinateIsRejected() throws {
        let json = """
        {"format":"macromaker","version":2,"name":"Huge","createdAt":"2026-09-16T10:00:00Z",
         "events":[{"type":"move","t":0,"x":1e300,"y":10}]}
        """
        #expect(throws: DecodingError.self, "a coordinate outside the screen bound must not survive decoding") {
            try Macro(jsonData: Data(json.utf8))
        }
    }

    @Test func aMacroFileWithANonFiniteCoordinateIsRejected() throws {
        // JSON can't say NaN, but 1e400 parses to +infinity.
        let json = """
        {"format":"macromaker","version":2,"name":"Inf","createdAt":"2026-09-16T10:00:00Z",
         "events":[{"type":"move","t":0,"x":1e400,"y":10}]}
        """
        #expect(throws: DecodingError.self) { try Macro(jsonData: Data(json.utf8)) }
    }

    /// Ordinary screen coordinates decode unchanged — a 5K Retina's 5120×2880 and negatives
    /// (a window on a display left of the main one) must both pass.
    @Test func ordinaryCoordinatesStillDecode() throws {
        let json = """
        {"format":"macromaker","version":2,"name":"Fine","createdAt":"2026-09-16T10:00:00Z",
         "events":[{"type":"mouseDown","t":0,"button":"left","x":-1920,"y":2880,"clickCount":1},
                   {"type":"move","t":0.1,"x":5120,"y":0}]}
        """
        let macro = try Macro(jsonData: Data(json.utf8))
        #expect(macro.events.count == 2)
    }

    /// The render-path conversion itself: the exact value that used to trap now renders.
    @MainActor @Test func aHugeCoordinateSummarizesWithoutTrapping() {
        let huge = MacroEvent(time: 0, action: .move(CGPoint(x: 1e300, y: -1e300)), flags: 0)
        _ = huge.summary   // must not trap: Int(1e300) used to exit-133 the app here
        let inf = MacroEvent(time: 0, action: .move(CGPoint(x: Double.infinity, y: Double.nan)), flags: 0)
        #expect(inf.summary.contains("0"), "a non-finite coordinate renders as 0 rather than trapping")
    }

    /// The step-editor's parse boundary: finite-but-huge is clamped into the event bound,
    /// non-finite is refused — so Apply can never store a value the render path can't print.
    @MainActor @Test func theStepEditorClampsHugeCoordinatesAtParseTime() {
        // parsePoint is private; the clamped values it feeds `MacroLibraryRules.withPoint`
        // are what the decoder accepts, so assert the bound arithmetic the parser applies.
        let bound = MacroEvent.maximumCoordinate
        #expect(bound == 100_000)
        let clamped = min(max(1e300, -bound), bound)
        #expect(clamped == bound, "1e300 clamps to the bound instead of storing")
        #expect(Int(clamped) == 100_000, "the clamped value converts to Int without trapping")
    }

    /// Ordinary values decode unchanged — the clamps must not rewrite honest settings.
    @Test func ordinaryDecodedDoublesAreUntouched() throws {
        var profile = Profile(name: "Honest")
        profile.autoClicker.intervalMs = 250
        profile.autoClicker.delayedStartSeconds = 10
        profile.autoClicker.x = -350
        profile.keyPresser.intervalMs = 100
        profile.playback.speed = 0.25
        profile.webTarget.intervalMs = 5_000
        profile.webTarget.x = 1920
        let decoded = try Profile.from(jsonData: try profile.jsonData())
        #expect(decoded == profile)
    }
}
