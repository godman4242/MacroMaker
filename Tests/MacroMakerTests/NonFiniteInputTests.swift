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
}
