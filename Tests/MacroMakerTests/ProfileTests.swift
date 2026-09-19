import Foundation
import Testing

@testable import MacroMaker

@Suite("Profile")
struct ProfileTests {
    @Test func roundTripThroughJSON() throws {
        var profile = Profile(name: "Farm")
        profile.autoClicker.intervalMs = 42
        profile.autoClicker.target = .fixedPoint
        profile.keyPresser.keyText = "f5"
        profile.webTarget.urlMatch = "example.com"
        profile.playback.repeatCount = 7
        profile.macro = Macro(name: "M", events: [])

        let data = try profile.jsonData()
        let decoded = try Profile.from(jsonData: data)
        #expect(decoded == profile)
        #expect(decoded.formatVersion == Profile.currentFormatVersion)
    }

    @Test func tolerateOlderFilesWithMissingFields() throws {
        // A v1-shaped blob: no formatVersion, no webTarget/playback, only one feature block.
        let json = Data(#"""
        {"name":"Old","autoClicker":{"button":"left","intervalMs":250,"x":1,"y":2,"target":"cursor"}}
        """#.utf8)
        let profile = try Profile.from(jsonData: json)
        #expect(profile.name == "Old")
        #expect(profile.formatVersion == 1)
        #expect(profile.autoClicker.intervalMs == 250)
        #expect(profile.keyPresser.keyText == "space")
        #expect(profile.webTarget.browser == .safari)
        #expect(profile.macro == nil)
    }

    @Test func newerFormatVersionFailsLoudly() throws {
        // Item 9: a file from a newer Macro Maker must not silently decode into wrong settings.
        let json = Data(#"{"name":"Future","formatVersion":3,"unknownField":true}"#.utf8)
        #expect(throws: DecodingError.self) {
            try Profile.from(jsonData: json)
        }
        // …and the failure names the version so the user knows why.
        do {
            _ = try Profile.from(jsonData: json)
            Issue.record("expected the v3 profile to throw")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("3"))
        }
    }

    @Test func currentFormatVersionStillDecodes() throws {
        let json = Data(#"{"name":"Now","formatVersion":2}"#.utf8)
        let profile = try Profile.from(jsonData: json)
        #expect(profile.name == "Now")
        #expect(profile.formatVersion == 2)
    }

    @Test func entryMirrorsTheProfileAndBack() {
        var profile = Profile(name: "Both")
        profile.id = UUID()
        profile.autoClicker.burstSize = 4
        let entry = ProfileEntry(profile: profile)
        #expect(entry.autoClicker.burstSize == 4)
        let rebuilt = entry.asProfile()
        #expect(rebuilt.id == profile.id)
        #expect(rebuilt.autoClicker == profile.autoClicker)
        #expect(rebuilt.name == "Both")
    }
}

@Suite("ProfileRules")
struct ProfileRulesTests {
    @Test func cleanedNameTrimsAndFallsBack() {
        #expect(ProfileRules.cleanedName("  Evening farm \n") == "Evening farm")
        #expect(ProfileRules.cleanedName("") == "Profile")
        #expect(ProfileRules.cleanedName("   ") == "Profile")
    }

    @Test func duplicateNamingFollowsFinder() {
        #expect(ProfileRules.uniqueName(forDuplicateOf: "Farm", taken: []) == "Farm copy")
        #expect(ProfileRules.uniqueName(forDuplicateOf: "Farm", taken: ["Farm copy"]) == "Farm copy 2")
        #expect(ProfileRules.uniqueName(forDuplicateOf: "Farm", taken: ["Farm copy", "Farm copy 2"]) == "Farm copy 3")
        // Case-insensitive like the Finder.
        #expect(ProfileRules.uniqueName(forDuplicateOf: "farm", taken: ["farm copy"]) == "farm copy 2")
    }

    @Test func uniqueDisplayNameSuffixesOnlyOnACaseInsensitiveClash() {
        #expect(ProfileRules.uniqueDisplayName(for: "Fresh", taken: []) == "Fresh")
        #expect(ProfileRules.uniqueDisplayName(for: "Login", taken: ["other"]) == "Login")
        #expect(ProfileRules.uniqueDisplayName(for: "My Profile", taken: ["my profile"]) == "My Profile 2")
        #expect(ProfileRules.uniqueDisplayName(for: "My Profile", taken: ["my profile", "MY PROFILE 2"]) == "My Profile 3")
    }
}

/// The profiles-list wipe and the silent case-variant replace (review models F1 + F12).
///
/// The list decoded as one array with `try?` + `?? []`, so a single unreadable entry made
/// the WHOLE list present as empty — and the next save/delete/rename persisted `[]` over
/// the blob, permanently. Meanwhile `save()` matched names case-insensitively, so saving
/// "My Profile" silently REPLACED the different profile "my profile".
@Suite("Profile list integrity")
struct ProfileListIntegrityTests {

    private func storedEntryJSON(named name: String) throws -> String {
        String(decoding: try JSONEncoder().encode(ProfileEntry(profile: Profile(name: name))), as: UTF8.self)
    }

    /// Blast radius: whatever made one entry unreadable — a type mismatch, an unknown enum
    /// value, a hand-edited defaults plist — it must cost one profile, not the list.
    @Test func oneUndecodableStoredEntryCostsOnlyThatEntry() throws {
        let first = try storedEntryJSON(named: "One")
        let third = try storedEntryJSON(named: "Three")
        let blob = Data("[\(first),{\"id\":123},\(third)]".utf8)
        #expect(ProfileService.entries(fromStored: blob).map(\.name) == ["One", "Three"],
                "the corrupt entry must be dropped, not the whole list")
    }

    @MainActor @Test func savingACaseVariantKeepsBothProfilesDistinct() {
        let service = ProfileService(load: false)
        defer { UserDefaults.standard.removeObject(forKey: ProfileService.storageKey) }
        service.save(Profile(name: "my profile"))
        service.save(Profile(name: "My Profile"))
        #expect(service.entries.count == 2, "the case variant must not silently replace the original")
        #expect(Set(service.entries.map { $0.name.lowercased() }).count == 2,
                "display names must stay distinct, comparing case-insensitively")
        #expect(service.lastError != nil, "the rename must be surfaced, not silent")
    }

    @MainActor @Test func reSavingTheExactSameNameStillUpdates() {
        let service = ProfileService(load: false)
        defer { UserDefaults.standard.removeObject(forKey: ProfileService.storageKey) }
        var first = Profile(name: "Gaming")
        first.autoClicker.intervalMs = 100
        var second = Profile(name: "Gaming")
        second.autoClicker.intervalMs = 250
        service.save(first)
        service.save(second)
        #expect(service.entries.count == 1, "the exact same name is the same profile: update, don't accumulate")
        #expect(service.entries.first?.autoClicker.intervalMs == 250)
        #expect(service.entries.first?.id == first.id)
    }

    @MainActor @Test func importDoesNotCreateADuplicateDisplayName() throws {
        let service = ProfileService(load: false)
        defer { UserDefaults.standard.removeObject(forKey: ProfileService.storageKey) }
        service.save(Profile(name: "login"))
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "mm-import-\(UUID().uuidString).macromakerprofile")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Profile(name: "Login").jsonData().write(to: fileURL)
        let imported = try #require(service.importFile(at: fileURL))
        #expect(imported.name.lowercased() != "login", "the import must not create a duplicate display name")
        #expect(Set(service.entries.map { $0.name.lowercased() }).count == service.entries.count)
        #expect(service.lastError != nil, "the rename must be surfaced, not silent")
    }

    @MainActor @Test func aFailedProfileWriteSurfacesAWarning() {
        let service = ProfileService(load: false)
        let originalWriter = Persistence.writer
        Persistence.writer = { _, _ in false }
        defer {
            Persistence.writer = originalWriter
            UserDefaults.standard.removeObject(forKey: ProfileService.storageKey)
        }
        service.save(Profile(name: "Unsaved"))
        #expect(service.entries.first?.name == "Unsaved", "the change is still visible in memory")
        #expect(service.lastError != nil, "a failed save must not be indistinguishable from success")
    }
}

/// The profile importer accepted ANY top-level JSON object: `Profile.init(from:)` defaults every
/// field, including `name`, so `ProfileService.importFile(at:)`'s "it isn't a valid Macro Maker
/// profile" error could never fire for well-formed JSON. `Macro` has guarded on its `format` key
/// since v2.0; profiles never did. Applying such an import resets every feature to defaults.
@Suite("Profile identity")
struct ProfileIdentityTests {

    @Test func arbitraryJsonIsNotAProfile() {
        #expect(throws: DecodingError.self) { try Profile.from(jsonData: Data("{}".utf8)) }
        #expect(throws: DecodingError.self) {
            try Profile.from(jsonData: Data(#"{"hello":"world"}"#.utf8))
        }
        // The shape that made this worst: it looks named, so it imports wearing a real title.
        #expect(throws: DecodingError.self) {
            try Profile.from(jsonData: Data(#"{"name":"Quarterly Report"}"#.utf8))
        }
    }

    @Test func aFileDeclaringADifferentFormatIsRejected() {
        #expect(throws: DecodingError.self) {
            try Profile.from(jsonData: Data(#"{"format":"macromaker","name":"A macro, not a profile"}"#.utf8))
        }
    }

    @Test func profilesThisBuildWritesDeclareTheirFormat() throws {
        let data = try Profile(name: "Round trip").jsonData()
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("macromakerprofile"), "a saved profile must identify itself")
        #expect(try Profile.from(jsonData: data).name == "Round trip")
    }

    /// The tolerance that must survive: a genuine older file has no `format` key, but every
    /// profile this app has ever written carries at least one settings section.
    @Test func aGenuineOlderProfileWithoutTheFormatKeyStillLoads() throws {
        let json = Data(#"{"name":"Old","autoClicker":{"button":"left","intervalMs":250}}"#.utf8)
        #expect(try Profile.from(jsonData: json).name == "Old")
    }
}
