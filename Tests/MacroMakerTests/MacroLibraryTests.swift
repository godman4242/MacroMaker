import Foundation
import Testing
@testable import MacroMaker

@Suite("MacroLibraryRules")
struct MacroLibraryRulesTests {
    private func event(_ time: Double) -> MacroEvent {
        MacroEvent(time: time, action: .keyDown(0, isRepeat: false), flags: 0)
    }

    // MARK: safeFileName / isSafeFileName

    @Test func safeFileNameKeepsCleanNameAndAddsExtension() {
        #expect(MacroLibraryRules.safeFileName(for: "Login") == "Login.macromaker")
        // Proposing the extension is a no-op — the library adds it itself.
        #expect(MacroLibraryRules.safeFileName(for: "Login.macromaker") == "Login.macromaker")
        #expect(MacroLibraryRules.safeFileName(for: "Login.MACROMAKER") == "Login.macromaker")
    }

    @Test func safeFileNameRejectsPathTraversalCharacters() {
        // '/' and '\' both become ':' (Finder style); ".." collapses since dots are trimmed.
        #expect(MacroLibraryRules.safeFileName(for: "a/b") == "a:b.macromaker")
        #expect(MacroLibraryRules.safeFileName(for: "a\\b") == "a:b.macromaker")
        #expect(!MacroLibraryRules.safeFileName(for: "../etc/passwd").contains("/"))
        #expect(!MacroLibraryRules.safeFileName(for: "../etc/passwd").contains(".."))
        #expect(!MacroLibraryRules.isSafeFileName("../etc/passwd.macromaker"))
    }

    @Test func safeFileNameStripsNULAndDotsOnly() {
        #expect(MacroLibraryRules.safeFileName(for: "a\0b") == "ab.macromaker")
        #expect(MacroLibraryRules.safeFileName(for: "...") == "Macro.macromaker")
        #expect(MacroLibraryRules.safeFileName(for: " .hidden. ") == "hidden.macromaker")
    }

    @Test func safeFileNameCapsLength() {
        let long = String(repeating: "a", count: 500)
        let safe = MacroLibraryRules.safeFileName(for: long)
        #expect(safe.count == MacroLibraryRules.maximumFileNameLength + ".macromaker".count)
        #expect(safe.hasSuffix(".macromaker"))
    }

    @Test func isSafeFileNameIsTheFixedPointCheck() {
        #expect(MacroLibraryRules.isSafeFileName("Login.macromaker"))
        #expect(!MacroLibraryRules.isSafeFileName("../evil.macromaker"))
        #expect(!MacroLibraryRules.isSafeFileName("a/b.macromaker"))
        #expect(!MacroLibraryRules.isSafeFileName("Login"))  // missing extension never round-trips
        #expect(!MacroLibraryRules.isSafeFileName("Login.macromaker.macromaker"))
    }

    // MARK: uniqueFileName

    @Test func uniqueFileNameKeepsCleanName() {
        // The full file name — including the extension — is what collides on disk.
        #expect(MacroLibraryRules.uniqueFileName(for: "Login", taken: []) == "Login.macromaker")
    }

    @Test func uniqueFileNameTrimsWhitespaceAndDefaults() {
        #expect(MacroLibraryRules.uniqueFileName(for: "   ", taken: []) == "Macro.macromaker")
        #expect(MacroLibraryRules.uniqueFileName(for: "  Login  ", taken: []) == "Login.macromaker")
    }

    @Test func uniqueFileNameSanitizesSlashes() {
        // A '/' would escape the library folder; the Finder shows ':' in its place.
        #expect(MacroLibraryRules.uniqueFileName(for: "a/b", taken: []) == "a:b.macromaker")
        #expect(MacroLibraryRules.uniqueFileName(for: "a/b/c", taken: []) == "a:b:c.macromaker")
    }

    @Test func uniqueFileNameAvoidsCollisionsCaseInsensitive() {
        let taken = ["Login.macromaker", "login-1.macromaker"]
        // "login.macromaker" collides with "Login.macromaker" (case-insensitive, like the Finder);
        // the comparison folds the extension in, so a bare extensionless entry in `taken` can't
        // force a needless suffix either.
        #expect(MacroLibraryRules.uniqueFileName(for: "login", taken: taken) == "login-2.macromaker")
        #expect(MacroLibraryRules.uniqueFileName(for: "LOGIN", taken: taken) == "LOGIN-2.macromaker")
        #expect(MacroLibraryRules.uniqueFileName(for: "Login", taken: taken) == "Login-2.macromaker")
        #expect(MacroLibraryRules.uniqueFileName(for: "Fresh", taken: taken) == "Fresh.macromaker")
    }

    // MARK: shiftedForWait

    @Test func shiftedForWaitShiftsFromInsertionPointOn() {
        let events = [event(0), event(0.5), event(1.0), event(2.0)]
        let shifted = MacroLibraryRules.shiftedForWait(events: events, atIndex: 1, seconds: 0.25)
        #expect(shifted.map(\.time) == [0, 0.75, 1.25, 2.25])
    }

    @Test func shiftedForWaitAtIndex0ShiftsEverything() {
        let events = [event(0), event(0.5)]
        let shifted = MacroLibraryRules.shiftedForWait(events: events, atIndex: 0, seconds: 3)
        #expect(shifted.map(\.time) == [3, 3.5])
    }

    @Test func shiftedForWaitIgnoresBadArguments() {
        let events = [event(0), event(1)]
        #expect(MacroLibraryRules.shiftedForWait(events: events, atIndex: -1, seconds: 1) == events)
        #expect(MacroLibraryRules.shiftedForWait(events: events, atIndex: 2, seconds: 1) == events)
        #expect(MacroLibraryRules.shiftedForWait(events: events, atIndex: 1, seconds: 0) == events)
        #expect(MacroLibraryRules.shiftedForWait(events: events, atIndex: 1, seconds: -1) == events)
    }

    // MARK: sortedByTime (step editor re-sort, item 17)

    @Test func sortedByTimeReordersOutOfOrderEvents() {
        let events = [event(2.0), event(0.5), event(1.0)]
        #expect(MacroLibraryRules.sortedByTime(events: events).map(\.time) == [0.5, 1.0, 2.0])
    }

    @Test func sortedByTimeKeepsSameTimePairsInOriginalOrder() {
        // A keyDown/keyUp at the same instant must not swap — playback depends on down-then-up.
        let down = MacroEvent(time: 1, action: .keyDown(30, isRepeat: false), flags: 0)
        let up = MacroEvent(time: 1, action: .keyUp(30), flags: 0)
        let sorted = MacroLibraryRules.sortedByTime(events: [down, up])
        #expect(sorted == [down, up])
    }

    // MARK: insertTypedText (item 18)

    @Test func insertTypedTextShiftsLaterEventsByTypedDuration() {
        // Events at 0, 1, 2; insert "ab" after the first. "ab" types as 4 transitions × 0.02 s,
        // so its duration (first to one gap past its last) is 4 × 0.02 = 0.08.
        let events = [event(0), event(1.0), event(2.0)]
        let inserted = MacroLibraryRules.insertTypedText(events: events, atIndex: 0, text: "ab")
        #expect(inserted.count == 3 + 4)
        #expect(inserted[0].time == 0)
        // The typed steps start one gap after the preceding event.
        #expect(inserted[1].time == 0.02)
        #expect(inserted[4].textOverride == "b")
        // Later events moved back by the typed duration: 1.0 → 1.08, 2.0 → 2.08.
        #expect(inserted[5].time == 1.08)
        #expect(inserted[6].time == 2.08)
        // Nothing overlaps: times are strictly increasing across the seam.
        let times = inserted.map(\.time)
        #expect(times == times.sorted())
    }

    @Test func insertTypedTextIgnoresBadArguments() {
        let events = [event(0), event(1)]
        #expect(MacroLibraryRules.insertTypedText(events: events, atIndex: -1, text: "a") == events)
        #expect(MacroLibraryRules.insertTypedText(events: events, atIndex: 2, text: "a") == events)
        #expect(MacroLibraryRules.insertTypedText(events: events, atIndex: 0, text: "") == events)
    }

    // MARK: typedTextEvents

    @Test func typedTextEventsEmitsKeyDownKeyUpPairs() {
        let events = MacroLibraryRules.typedTextEvents("ab", start: 1.0)
        #expect(events.count == 4)
        // Key-down with the character, then its key-up, then the next pair 0.02 s after.
        #expect(events[0].time == 1.0)
        #expect(events[1].time == 1.02)
        #expect(events[2].time == 1.04)
        #expect(events[3].time == 1.06)
    }

    @Test func typedTextEventsCarriesTextOnBothHalves() {
        // Item 10: the keyUp must carry the text too, or it posts a raw key-code-0 "A" release.
        let events = MacroLibraryRules.typedTextEvents("ab", start: 0)
        #expect(events[0].textOverride == "a")
        #expect(events[1].textOverride == "a")
        #expect(events[2].textOverride == "b")
        #expect(events[3].textOverride == "b")
        if case .keyDown(0, isRepeat: false) = events[0].action {} else { Issue.record("expected keyDown(0)") }
        if case .keyUp(0) = events[1].action {} else { Issue.record("expected keyUp(0)") }
    }

    @Test func typedTextEventsHandlesEmptyAndEmoji() {
        #expect(MacroLibraryRules.typedTextEvents("", start: 0).isEmpty)
        let emoji = MacroLibraryRules.typedTextEvents("é🚀", start: 0)
        #expect(emoji.count == 4)
        #expect(emoji[0].textOverride == "é")
        #expect(emoji[2].textOverride == "🚀")
    }
}

@Suite("MacroRecord")
struct MacroRecordTests {
    @Test func indexRoundTrip() throws {
        var record = MacroRecord(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!,
                                 name: "Login", createdAt: Date(timeIntervalSince1970: 1_000_000),
                                 fileName: "Login.macromaker")
        record.isFavorite = true
        record.eventCount = 42
        record.durationSeconds = 7.5
        let data = try JSONEncoder().encode([record])
        let decoded = try JSONDecoder().decode([MacroRecord].self, from: data)
        #expect(decoded == [record])
    }

    @Test func indexToleratesMissingDefaults() throws {
        // A v1-shaped blob without the newer fields still loads.
        let json = """
        [{"id":"00000000-0000-0000-0000-00000000000A","name":"Old","createdAt":0,"fileName":"Old.macromaker"}]
        """
        let decoded = try JSONDecoder().decode([MacroRecord].self, from: Data(json.utf8))
        #expect(decoded.count == 1)
        #expect(decoded[0].isFavorite == false)
        #expect(decoded[0].eventCount == 0)
        #expect(decoded[0].isOrphan == false)
    }

    @Test func indexRejectsUnsafeFileName() throws {
        // Item 21: an index entry that could escape the library folder never reaches disk code.
        let json = """
        [{"id":"00000000-0000-0000-0000-00000000000A","name":"Evil","createdAt":0,"fileName":"../escape.macromaker"}]
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([MacroRecord].self, from: Data(json.utf8))
        }
    }

    @Test func textOverrideRoundTripsAndV1IgnoresIt() throws {
        // The step editor's typed-text field rides along in the same envelope; v1 readers
        // (which ignore unknown keys and never see it on recordings) keep loading the file.
        let with = MacroEvent(time: 1, action: .keyDown(0, isRepeat: false), flags: 0, textOverride: "é")
        let without = MacroEvent(time: 1.02, action: .keyUp(0), flags: 0)
        let data = try JSONEncoder().encode([with, without])
        let decoded = try JSONDecoder().decode([MacroEvent].self, from: data)
        #expect(decoded == [with, without])
        // Encoding omits the key entirely when there's no text — v1 files stay byte-shaped.
        let plain = String(decoding: try JSONEncoder().encode(without), as: UTF8.self)
        #expect(!plain.contains("\"text\""))
    }

    @MainActor @Test func summaryShowsTypedText() {
        let down = MacroEvent(time: 0, action: .keyDown(0, isRepeat: false), flags: 0, textOverride: "é")
        let up = MacroEvent(time: 0.02, action: .keyUp(0), flags: 0, textOverride: "é")
        #expect(down.summary == "Type “é”")
        #expect(up.summary == "(end character)")
    }
}
