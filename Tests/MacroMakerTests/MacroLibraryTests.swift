import Foundation
import Testing
@testable import MacroMaker

@Suite("MacroLibraryRules")
struct MacroLibraryRulesTests {
    private func event(_ time: Double) -> MacroEvent {
        MacroEvent(time: time, action: .keyDown(0, isRepeat: false), flags: 0)
    }

    // MARK: uniqueFileName

    @Test func uniqueFileNameKeepsCleanName() {
        #expect(MacroLibraryRules.uniqueFileName(for: "Login", taken: []) == "Login")
    }

    @Test func uniqueFileNameTrimsWhitespaceAndDefaults() {
        #expect(MacroLibraryRules.uniqueFileName(for: "   ", taken: []) == "Macro")
        #expect(MacroLibraryRules.uniqueFileName(for: "  Login  ", taken: []) == "Login")
    }

    @Test func uniqueFileNameSanitizesSlashes() {
        // A '/' would escape the library folder; the Finder shows ':' in its place.
        #expect(MacroLibraryRules.uniqueFileName(for: "a/b", taken: []) == "a:b")
        #expect(MacroLibraryRules.uniqueFileName(for: "a/b/c", taken: []) == "a:b:c")
    }

    @Test func uniqueFileNameAvoidsCollisionsCaseInsensitive() {
        let taken = ["Login", "login 1"]
        // "login" collides with "Login"
        #expect(MacroLibraryRules.uniqueFileName(for: "login", taken: taken) == "login 2")
        #expect(MacroLibraryRules.uniqueFileName(for: "LOGIN", taken: taken) == "LOGIN 2")
        // Extension is not part of the comparison — the caller appends the real one.
        #expect(MacroLibraryRules.uniqueFileName(for: "Login", taken: taken) == "Login 2")
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

    @Test func typedTextEventsCarriesTextOnKeyDownOnly() {
        let events = MacroLibraryRules.typedTextEvents("ab", start: 0)
        #expect(events[0].textOverride == "a")
        #expect(events[1].textOverride == nil)
        #expect(events[2].textOverride == "b")
        #expect(events[3].textOverride == nil)
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
