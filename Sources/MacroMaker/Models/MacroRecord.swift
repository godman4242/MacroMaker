import Foundation

/// Every macro in the library: the record for the list plus the file path to the payload.
struct MacroRecord: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var createdAt: Date
    /// The `.macromaker` file in the library folder. Kept relative to the folder so the index
    /// survives a user move.
    var fileName: String
    var isFavorite = false
    var eventCount = 0
    var durationSeconds = 0.0

    /// True when the index entry points at a missing file (deletable, clearly marked in the UI).
    var isOrphan: Bool = false

    /// Everything the index needs to exist; the rest has defaults for forward compat.
    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), fileName: String) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.fileName = fileName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Macro"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? "Macro.\(Macro.fileExtension)"
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        eventCount = try c.decodeIfPresent(Int.self, forKey: .eventCount) ?? 0
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        isOrphan = try c.decodeIfPresent(Bool.self, forKey: .isOrphan) ?? false
    }
}

/// Library file-name and id rules, pure for tests.
enum MacroLibraryRules {
    /// A unique file name inside the library folder, never colliding with anything on disk or in
    /// the index (case-insensitive, like the Finder — the file system can be either case).
    static func uniqueFileName(for name: String, taken: [String]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Macro" : trimmed
        let slashed = base.replacingOccurrences(of: "/", with: ":")  // '/' is a directory separator
        let taken = Set(taken.map { $0.lowercased() })
        func candidate(_ index: Int) -> String {
            index == 0 ? slashed : "\(slashed) \(index)"
        }
        var index = 0
        while taken.contains(candidate(index).lowercased()) { index += 1 }
        return candidate(index)
    }

    /// Inserting a wait of `seconds` at `atIndex` shifts every later event back.
    static func shiftedForWait(events: [MacroEvent], atIndex: Int, seconds: Double) -> [MacroEvent] {
        guard seconds > 0, atIndex >= 0, atIndex < events.count else { return events }
        var out = events
        for index in atIndex..<out.count { out[index].time += seconds }
        return out
    }

    /// Types `text` as keyDown/keyUp pairs at `start`, returning the events created (each key
    /// transition a fixed gap later). Text becomes .text-styled KeyStroke pairs, posted as Unicode —
    /// exactly what KeyStrokeParser does for characters off the keyboard layout.
    static func typedTextEvents(_ text: String, start: TimeInterval, gap: TimeInterval = 0.02) -> [MacroEvent] {
        var events: [MacroEvent] = []
        var t = start
        for character in text {
            events.append(MacroEvent(time: t, action: .keyDown(0, isRepeat: false), flags: 0, textOverride: String(character)))
            t += gap
            events.append(MacroEvent(time: t, action: .keyUp(0), flags: 0, textOverride: nil))
            t += gap
        }
        return events
    }
}
