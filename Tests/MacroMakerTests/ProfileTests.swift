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
}
