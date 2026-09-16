import Foundation

/// A saved snapshot of every feature's settings plus the current macro, shareable as a file.
///
/// The envelope has a version so future shapes can decode tolerantly: unknown versions are
/// rejected by the reader, but any *fields* a build doesn't know are simply ignored.
struct Profile: Codable, Equatable, Sendable, Identifiable {
    static let currentFormatVersion = 2
    static let fileExtension = "macromakerprofile"

    var id: UUID
    var name: String
    var formatVersion = currentFormatVersion
    var autoClicker = AutoClickerSettings()
    var keyPresser = KeyPresserSettings()
    var webTarget = WebTargetSettings()
    var playback = PlaybackSettings()
    /// nil = the profile carries no macro; the macro is optional because most profiles won't have one.
    var macro: Macro?

    init(name: String) {
        self.id = UUID()
        self.name = name
    }

    /// Tolerant decode: the envelope defaults every field, so older or partial files still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Profile"
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        autoClicker = try c.decodeIfPresent(AutoClickerSettings.self, forKey: .autoClicker) ?? AutoClickerSettings()
        keyPresser = try c.decodeIfPresent(KeyPresserSettings.self, forKey: .keyPresser) ?? KeyPresserSettings()
        webTarget = try c.decodeIfPresent(WebTargetSettings.self, forKey: .webTarget) ?? WebTargetSettings()
        playback = try c.decodeIfPresent(PlaybackSettings.self, forKey: .playback) ?? PlaybackSettings()
        macro = try c.decodeIfPresent(Macro.self, forKey: .macro)
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func from(jsonData: Data) throws -> Profile {
        try JSONDecoder().decode(Profile.self, from: jsonData)
    }
}

/// The list of profiles in UserDefaults: small (settings only) so the JSON blob stays small.
struct ProfileEntry: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var autoClicker: AutoClickerSettings
    var keyPresser: KeyPresserSettings
    var webTarget: WebTargetSettings
    var playback: PlaybackSettings
    var macro: Macro?
    var isFavorite = false

    init(profile: Profile) {
        id = profile.id
        name = profile.name
        autoClicker = profile.autoClicker
        keyPresser = profile.keyPresser
        webTarget = profile.webTarget
        playback = profile.playback
        macro = profile.macro
    }

    func asProfile() -> Profile {
        var profile = Profile(name: name)
        profile.id = id
        profile.autoClicker = autoClicker
        profile.keyPresser = keyPresser
        profile.webTarget = webTarget
        profile.playback = playback
        profile.macro = macro
        return profile
    }
}

/// Profile naming/collision rules, pure for tests.
enum ProfileRules {
    /// A display name trimmed and never empty.
    static func cleanedName(_ proposed: String) -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Profile" : trimmed
    }

    /// An unused-duplicate name: "X" → "X copy" → "X copy 2"…, like Finder.
    static func uniqueName(forDuplicateOf name: String, taken: [String]) -> String {
        let taken = Set(taken.map { $0.lowercased() })
        let base = "\(name) copy"
        if !taken.contains(base.lowercased()) { return base }
        var index = 2
        while taken.contains("\(base) \(index)".lowercased()) { index += 1 }
        return "\(base) \(index)"
    }
}
