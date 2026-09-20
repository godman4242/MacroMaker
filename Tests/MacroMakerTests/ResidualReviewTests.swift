import Foundation
import Testing
@testable import MacroMaker

/// Wave 6 — residual review findings N4 and N7 (adversarial-waves-review.md, 2026-09-18).
/// N4: ClickRegion and the settings structs decoded strictly enough that ONE corrupt field
/// threw through `decodeIfPresent`, and `Persistence.load`'s `try?` turned that into a silent
/// reset of the WHOLE settings blob to defaults — the same permanent-loss shape as F1/F11.
/// N7: `maxClicks`, `burstSize` and playback `repeatCount` decoded as unbounded Ints, outside
/// the clamping discipline every decoded Double already follows.
@Suite("Settings blob tolerance (N4)")
struct SettingsBlobToleranceTests {

    /// A type mismatch in ONE region field must cost that field alone — its siblings inside
    /// the region, and every other setting around it, survive untouched.
    @Test func aCorruptRegionFieldCostsOnlyThatField() throws {
        let json = """
        {"intervalMs":250,"maxClicks":7,"target":"region",
         "region":{"x":"oops","y":300,"width":250,"height":100}}
        """
        let s = try JSONDecoder().decode(AutoClickerSettings.self, from: Data(json.utf8))
        #expect(s.intervalMs == 250, "the corrupt region must not reset sibling settings")
        #expect(s.maxClicks == 7)
        #expect(s.target == .region)
        #expect(s.region.x == 400, "the corrupt field alone falls back to its default")
        #expect(s.region.y == 300)
        #expect(s.region.width == 250)
        #expect(s.region.height == 100)
    }

    /// The region value itself being the wrong shape (a hand-edited plist entry) costs the
    /// region, not the blob.
    @Test func aRegionOfTheWrongTypeCostsTheRegionNotTheBlob() throws {
        let json = #"{"intervalMs":250,"region":"somewhere over there"}"#
        let s = try JSONDecoder().decode(AutoClickerSettings.self, from: Data(json.utf8))
        #expect(s.intervalMs == 250)
        #expect(s.region == ClickRegion(), "an unreadable region falls back to the default region")
    }

    /// Region doubles are bounded like the UI's NumberFields enforce (x/y ±20_000, size
    /// 1...20_000) and non-finite values fall back per field.
    @Test func regionDoublesClampToTheUIBounds() throws {
        let json = #"{"region":{"x":1e20,"y":-1e20,"width":-5,"height":1e20}}"#
        let s = try JSONDecoder().decode(AutoClickerSettings.self, from: Data(json.utf8))
        #expect(s.region.x == 20_000)
        #expect(s.region.y == -20_000)
        #expect(s.region.width == 1)
        #expect(s.region.height == 20_000)
    }

    /// Unknown enum values (a future build's case, a hand-edited blob) default per field.
    @Test func unknownEnumValuesCostOnlyTheirField() throws {
        let json = #"{"intervalMs":250,"button":7,"target":"spaceLaser","clickCountPerEvent":9}"#
        let s = try JSONDecoder().decode(AutoClickerSettings.self, from: Data(json.utf8))
        #expect(s.intervalMs == 250)
        #expect(s.button == .left)
        #expect(s.target == .cursor)
        #expect(s.clickCountPerEvent == .single)
    }

    /// A type-mismatched scalar (a Double field holding a string) defaults per field.
    @Test func aStringWhereADoubleBelongsCostsOnlyThatField() throws {
        let json = #"{"intervalMs":"fast","x":123}"#
        let s = try JSONDecoder().decode(AutoClickerSettings.self, from: Data(json.utf8))
        #expect(s.intervalMs == 100)
        #expect(s.x == 123)
    }

    /// WebTargetSettings' nested enum types (Browser, LocatorKind) get the same per-field
    /// tolerance the review named alongside ClickRegion.
    @Test func webTargetUnknownEnumsCostOnlyTheirField() throws {
        let json = ##"{"browser":"firefox","locatorKind":"coordinates","cssSelector":"#x","intervalMs":2000}"##
        let w = try JSONDecoder().decode(WebTargetSettings.self, from: Data(json.utf8))
        #expect(w.browser == .safari, "an unknown browser must not wipe the other settings")
        #expect(w.locatorKind == .coordinates)
        #expect(w.cssSelector == "#x")
        #expect(w.intervalMs == 2000)
    }

    /// Honest values round-trip exactly as before — tolerance must not perturb good blobs.
    @Test func honestSettingsRoundTripUnchanged() throws {
        var s = AutoClickerSettings()
        s.intervalMs = 250
        s.maxClicks = 7
        s.region = ClickRegion(x: -100, y: 200, width: 350, height: 80)
        let round = try JSONDecoder().decode(AutoClickerSettings.self,
                                             from: JSONEncoder().encode(s))
        #expect(round == s)
    }
}

@Suite("Decoded Int bounds (N7)")
struct DecodedIntBoundsTests {

    /// The three unbounded Ints clamp at decode to the ranges the UI fields enforce.
    @Test func maxClicksBurstSizeAndRepeatCountClampAtDecode() throws {
        let s = try JSONDecoder().decode(AutoClickerSettings.self,
                                         from: Data(#"{"maxClicks":5000000000,"burstSize":999}"#.utf8))
        #expect(s.maxClicks == 10_000_000, "the UI NumberField caps at 10,000,000")
        #expect(s.burstSize == 10, "the UI NumberField caps at 10")
        let p = try JSONDecoder().decode(PlaybackSettings.self, from: Data(#"{"repeatCount":123456}"#.utf8))
        #expect(p.repeatCount == 10_000, "the UI Stepper caps at 10,000")
    }

    /// Below the range clamps up, exactly like the Doubles' `clamped()` does from below.
    @Test func theIntClampsComeUpFromBelowToo() throws {
        let s = try JSONDecoder().decode(AutoClickerSettings.self,
                                         from: Data(#"{"maxClicks":0,"burstSize":-3}"#.utf8))
        #expect(s.maxClicks == 1)
        #expect(s.burstSize == 1)
        let p = try JSONDecoder().decode(PlaybackSettings.self, from: Data(#"{"repeatCount":0}"#.utf8))
        #expect(p.repeatCount == 1)
    }

    /// A value beyond Int64 (which `decode(Int.self)` itself throws on) costs the field its
    /// default, not the blob.
    @Test func anIntBeyondRepresentationCostsOnlyItsField() throws {
        let s = try JSONDecoder().decode(AutoClickerSettings.self,
                                         from: Data(#"{"maxClicks":1e20,"intervalMs":250}"#.utf8))
        #expect(s.maxClicks == 100)
        #expect(s.intervalMs == 250)
    }
}

@Suite("Fail-loud stragglers (N5)")
struct FailLoudStragglerTests {

    /// HotkeyService.save discarded Persistence.save's Bool — a failed hotkey write was
    /// invisible to the user. It must surface through the same channel other services use.
    @MainActor @Test func aFailedHotkeySaveSurfacesAWarning() {
        let service = HotkeyService()
        let originalWriter = Persistence.writer
        Persistence.writer = { _, _ in false }
        defer {
            Persistence.writer = originalWriter
            UserDefaults.standard.removeObject(forKey: "hotkeys")
        }
        service.setCombo(KeyCombo(keyCode: 97, modifiers: []), for: .toggleRecording)
        #expect(service.lastError != nil, "a failed hotkey save must not be indistinguishable from success")
    }

    /// And a successful save clears the warning again — nothing goes stale.
    @MainActor @Test func aSuccessfulHotkeySaveClearsTheWarning() {
        let service = HotkeyService()
        let originalWriter = Persistence.writer
        Persistence.writer = { _, _ in false }
        service.setCombo(KeyCombo(keyCode: 97, modifiers: []), for: .toggleRecording)
        Persistence.writer = { _, _ in true }
        defer {
            Persistence.writer = originalWriter
            UserDefaults.standard.removeObject(forKey: "hotkeys")
        }
        service.setCombo(KeyCombo(keyCode: 98, modifiers: []), for: .toggleRecording)
        #expect(service.lastError == nil, "a later successful save must clear the stale warning")
    }

    /// MacroLibrary.delete's removeItem was a silent `try?` — an undeletable file is surfaced,
    /// not swallowed.
    @MainActor @Test func anUndeletableLibraryFileWarnsInsteadOfStayingSilent() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "mm-lib-\(UUID().uuidString)", directoryHint: .isDirectory)
        MacroLibrary.folderOverride = folder
        defer {
            MacroLibrary.folderOverride = nil
            UserDefaults.standard.removeObject(forKey: MacroLibrary.indexKey)
            try? FileManager.default.removeItem(at: folder)
        }
        let library = MacroLibrary(load: false)
        let macro = Macro(name: "Stuck", createdAt: Date(timeIntervalSince1970: 1_000), events: [
            MacroEvent(time: 0, action: .keyDown(0, isRepeat: false), flags: 0)])
        let record = try #require(library.add(macro, named: "Stuck"))
        // Make the file undeletable the way it actually happens on disk: a directory with
        // that name in the way. removeItem on a non-empty directory we don't own… is not the
        // case here — instead make the parent read-only, which makes removeItem throw.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = folder.appending(path: record.fileName)
        try "x".write(to: fileURL, atomically: true, encoding: .utf8)
        // Strip write permission from the folder: removeItem then fails (and is restorable).
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        library.delete(record)
        #expect(library.records.isEmpty)
        #expect(library.lastError != nil, "an undeletable file must not vanish silently")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// ProfileService.persist() set lastError on failure but never cleared it on a later
    /// success — a stale "Couldn't save your profiles" outlived the recovery.
    @MainActor @Test func aSuccessfulProfileSaveClearsTheStaleWarning() {
        let service = ProfileService(load: false)
        let originalWriter = Persistence.writer
        Persistence.writer = { _, _ in false }
        service.save(Profile(name: "Unsaved"))
        #expect(service.lastError != nil)
        Persistence.writer = { _, _ in true }
        defer {
            Persistence.writer = originalWriter
            UserDefaults.standard.removeObject(forKey: ProfileService.storageKey)
        }
        service.rename(service.entries[0], to: "Renamed")
        #expect(service.lastError == nil, "a successful later save must clear the stale warning")
    }

    /// The import path's clash warning must survive the clear-on-success: persist() clearing
    /// lastError unconditionally would swallow the rename notice on a LANDED import.
    @MainActor @Test func anImportedClashWarningSurvivesTheClearOnSuccess() throws {
        let service = ProfileService(load: false)
        defer { UserDefaults.standard.removeObject(forKey: ProfileService.storageKey) }
        service.save(Profile(name: "login"))
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "mm-import-\(UUID().uuidString).macromakerprofile")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Profile(name: "Login").jsonData().write(to: fileURL)
        let imported = try #require(service.importFile(at: fileURL))
        #expect(imported.name.lowercased() != "login")
        #expect(service.lastError != nil, "the clash warning must still be reported after a landed import")
    }
}

@Suite("Tolerant hotkey stream (N6)")
struct TolerantHotkeyStreamTests {

    /// A value slot holding a plain string desyncs the pair-wise read: the OLD decoder's
    /// `try?` swallowed the failure and the next iteration read "oops" as a NAME — a healthy
    /// entry after the tear got misread as garbage. The honest limit (review N6): decoding
    /// stops AT the tear — the healthy prefix survives, and nothing after the tear is
    /// misread or invented.
    @Test func aStringInAValueSlotStopsAtTheTear() {
        let json = #"["stopAll", null, "toggleRecording", "oops", "togglePlayback", {"keyCode":101,"modifiers":0}]"#
        let combos = HotkeyAction.storedCombos(from: Data(json.utf8))
        #expect(combos[.stopAll] != nil, "the healthy prefix before the tear survives")
        #expect(combos[.toggleRecording] == nil,
                "a name with no value slot behind it must not decode into anything")
        #expect(combos[.togglePlayback] == nil,
                "the entry after the tear is not misread into the neighbour's fields")
    }

    /// A torn tail (an odd number of elements — the write was cut in half) stops at the tear
    /// and never invents a healthy entry out of the remainder.
    @Test func aTornTailStopsAtTheTear() {
        let json = #"["stopAll", null, "toggleRecording"]"#
        let combos = HotkeyAction.storedCombos(from: Data(json.utf8))
        #expect(combos[.stopAll] != nil)
        #expect(combos[.toggleRecording] == nil,
                "a name with no value slot behind it must not decode into anything")
    }

    /// Shape B corruption: an object in the NAME slot reads as a combo, which re-syncs the
    /// stream shifted by one. Entry-level guarding stops at the tear: the healthy prefix
    /// survives, and no entry is invented from the desync.
    @Test func anObjectInANameSlotStopsAtTheTear() {
        let json = #"["stopAll", null, {"keyCode":50,"modifiers":0}, {"keyCode":97,"modifiers":0}, "toggleRecording", null]"#
        let combos = HotkeyAction.storedCombos(from: Data(json.utf8))
        #expect(combos[.stopAll] != nil, "the entry before the tear survives")
        #expect(combos[.toggleAutoClicker] == nil, "no entry may be invented from the desync")
        #expect(combos[.toggleRecording] == nil, "the desynced tail is not misread into entries")
    }

    /// An unknown action NAME (the originally-handled corruption) still costs only itself —
    /// the stream is well-formed, the entry decodes and is skipped by name.
    @Test func anUnknownActionNameStillCostsOnlyThatEntry() {
        let json = #"["stopAll", null, "notAnAction", null, "toggleRecording", {"keyCode":101,"modifiers":0}]"#
        let combos = HotkeyAction.storedCombos(from: Data(json.utf8))
        #expect(combos[.stopAll] != nil)
        #expect(combos[.toggleRecording].flatMap { $0 }?.keyCode == 101,
                "a well-formed unknown entry must not stop the stream for its neighbours")
    }
}