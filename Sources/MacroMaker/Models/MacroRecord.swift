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
        let decodedFileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? "Macro.\(Macro.fileExtension)"
        guard MacroLibraryRules.isSafeFileName(decodedFileName) else {
            throw DecodingError.dataCorruptedError(forKey: .fileName, in: c,
                debugDescription: "The library index entry has an unsafe file name “\(decodedFileName)”.")
        }
        fileName = decodedFileName
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        eventCount = try c.decodeIfPresent(Int.self, forKey: .eventCount) ?? 0
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        isOrphan = try c.decodeIfPresent(Bool.self, forKey: .isOrphan) ?? false
    }
}

/// Library file-name and id rules, pure for tests.
enum MacroLibraryRules {
    /// Longest stored file name (the library folder is a private Application Support directory,
    /// but keeping names short also keeps the Finder display sane).
    static let maximumFileNameLength = 120

    /// The file name the library would store `proposed` under: the base with path characters
    /// stripped (`/` and `\` would reach outside the folder), the extension folded in, length
    /// capped at the base so the appended extension never overruns it, dots-only collapsed.
    static func safeFileName(for proposed: String) -> String {
        var base = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        base = base.replacingOccurrences(of: "/", with: ":")  // Finder shows ':' in its place
        base = base.replacingOccurrences(of: "\\", with: ":")
        base = base.unicodeScalars.filter { $0.value != 0 }.map(String.init).joined()
        // The extension is added by the library itself; proposing it doesn't change the name.
        let extensionSuffix = "." + Macro.fileExtension
        if base.lowercased().hasSuffix(extensionSuffix) { base = String(base.dropLast(extensionSuffix.count)) }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if base.isEmpty { base = "Macro" }
        if base.count > maximumFileNameLength { base = String(base.prefix(maximumFileNameLength)) }
        // Trimming before the cap is not enough: `prefix` can land on a dot or a space, and the
        // result is then not a fixed point of this function — which is exactly what
        // `isSafeFileName` tests, so the name was written to disk and then rejected on read.
        // One trim with the union of both sets is itself idempotent.
        base = base.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if base.isEmpty { base = "Macro" }
        return base + extensionSuffix
    }

    /// A name is safe to reach into the library folder with: it is exactly what safeFileName
    /// would produce — no separators, no '..', no NUL, no dots-only, inside the length cap —
    /// AND it carries the extension exactly once (a stored "X.macromaker.macromaker" is a
    /// corrupted name the fixed-point check alone would wave through).
    static func isSafeFileName(_ fileName: String) -> Bool {
        let extensionSuffix = "." + Macro.fileExtension
        guard fileName.hasSuffix(extensionSuffix) else { return false }
        let stem = String(fileName.dropLast(extensionSuffix.count))
        return fileName == safeFileName(for: fileName) && !stem.hasSuffix(extensionSuffix)
    }

    /// A unique file name (including the extension) inside the library folder, never colliding
    /// with anything on disk or in the index (case-insensitive, like the Finder — the file
    /// system can be either case).
    static func uniqueFileName(for name: String, taken: [String]) -> String {
        let full = safeFileName(for: name)
        let extensionSuffix = "." + Macro.fileExtension
        // The collision suffix goes INSIDE the extension, Finder-style: "login-2.macromaker",
        // never "login.macromaker-1" — the extension is what makes it a library file.
        let stem = full.hasSuffix(extensionSuffix) ? String(full.dropLast(extensionSuffix.count)) : full
        let taken = Set(taken.map { $0.lowercased() })
        func candidate(_ index: Int) -> String {
            guard index > 0 else { return full }
            // Budget the suffix INSIDE the cap. Appending "-N" after `safeFileName` had already
            // capped the stem pushed the name past `maximumFileNameLength`, so it was no longer
            // a `safeFileName` fixed point and `isSafeFileName` rejected it — the record saved
            // fine and then read back as "file missing", and on the next launch its throw took
            // the entire library index down with it.
            let suffix = "-\(index)"
            let budget = max(1, maximumFileNameLength - suffix.count)
            // Re-normalise through safeFileName so truncating the stem cannot leave a trailing
            // dot either. Distinct indices stay distinct, so the caller's loop still terminates.
            return safeFileName(for: String(stem.prefix(budget)) + suffix)
        }
        var index = 0
        while taken.contains(candidate(index).lowercased()) { index += 1 }
        return candidate(index)
    }

    /// Moves the step at `index` by `offset` places (±1 from the editor's Move Up/Down).
    /// Refused — the array unchanged — when the move would leave the array, or when it would
    /// separate a keyDown/keyUp or mouseDown/mouseUp pair across the swap: a stranded half
    /// is exactly what the recording cleaner drops on playback, so the edit the user asked
    /// for would silently delete a step. Swapping keeps each step's own time (reordering is
    /// a sequence change; the timeline stays what it was).
    static func moved(_ events: [MacroEvent], at index: Int, offset: Int) -> [MacroEvent] {
        let target = index + offset
        guard abs(offset) == 1, index >= 0, index < events.count,
              target >= 0, target < events.count else { return events }
        guard !wouldStrand(events[index], events[target]) else { return events }
        var out = events
        out.swapAt(index, target)
        return out
    }

    /// Whether swapping `a` with `b` would strand a held input: a down separated from its own
    /// up (either direction) puts the up before the down — the recording cleaner drops the
    /// orphaned up on playback, so the edit the user asked for would silently delete a step.
    /// Only matched pairs count; two unrelated mouse steps swap freely.
    private static func wouldStrand(_ a: MacroEvent, _ b: MacroEvent) -> Bool {
        if case let .keyDown(code, _) = a.action, case .keyUp(let other) = b.action { return code == other }
        if case let .keyUp(code) = a.action, case .keyDown(let other, _) = b.action { return code == other }
        if case let .mouseDown(button, _, _) = a.action, case .mouseUp(let other, _, _) = b.action { return button == other }
        if case let .mouseUp(button, _, _) = a.action, case .mouseDown(let other, _, _) = b.action { return button == other }
        return false
    }

    /// Rewrites a mouse step's point, leaving time, clickCount and deltas alone. Non-mouse
    /// steps come back untouched; scrolls keep their recorded point (their pixel deltas were
    /// measured there).
    static func withPoint(_ event: MacroEvent, x: Double, y: Double) -> MacroEvent {
        var out = event
        switch event.action {
        case let .mouseDown(button, _, clickCount):
            out.action = .mouseDown(button, CGPoint(x: x, y: y), clickCount: clickCount)
        case let .mouseUp(button, _, clickCount):
            out.action = .mouseUp(button, CGPoint(x: x, y: y), clickCount: clickCount)
        case let .move(_):
            out.action = .move(CGPoint(x: x, y: y))
        default:
            break
        }
        return out
    }

    /// Inserting a wait of `seconds` at `atIndex` shifts every later event back.
    static func shiftedForWait(events: [MacroEvent], atIndex: Int, seconds: Double) -> [MacroEvent] {
        guard seconds > 0, atIndex >= 0, atIndex < events.count else { return events }
        var out = events
        for index in atIndex..<out.count { out[index].time += seconds }
        return out
    }

    /// Inserting a typed-text step places the new pair at `index + 1` and shifts every later
    /// event by the step's full duration plus a small gap, so the new steps overlap nothing on
    /// the timeline — exactly what “Insert Wait” does, sized to what was typed.
    static func insertTypedText(events: [MacroEvent], atIndex: Int, text: String,
                                start: TimeInterval? = nil) -> [MacroEvent] {
        guard atIndex >= 0, atIndex < events.count, !text.isEmpty else { return events }
        let typed = typedTextEvents(text, start: start ?? (events[atIndex].time + 0.02))
        let duration = (typed.last?.time ?? 0) + 0.02 - typed[0].time
        var shifted = shiftedForWait(events: events, atIndex: atIndex + 1, seconds: duration)
        shifted.insert(contentsOf: typed, at: atIndex + 1)
        return shifted
    }

    /// Re-sorts events by time, stable so same-time pairs (keyDown then keyUp) keep their order.
    static func sortedByTime(events: [MacroEvent]) -> [MacroEvent] {
        events.enumerated()
            .sorted { $0.element.time != $1.element.time ? $0.element.time < $1.element.time : $0.offset < $1.offset }
            .map(\.element)
    }

    /// Types `text` as keyDown/keyUp pairs at `start`, returning the events created (each key
    /// transition a fixed gap later). Text becomes .text-styled KeyStroke pairs, posted as Unicode —
    /// exactly what KeyStrokeParser does for characters off the keyboard layout. Both halves of
    /// the pair carry the character so the keyUp posts the matching Unicode release instead of a
    /// spurious key-code-0 "A" key-up, and the table reads “(end character)”, never “Key up A”.
    static func typedTextEvents(_ text: String, start: TimeInterval, gap: TimeInterval = 0.02) -> [MacroEvent] {
        var events: [MacroEvent] = []
        var t = start
        for character in text {
            let marker = String(character)
            events.append(MacroEvent(time: t, action: .keyDown(0, isRepeat: false), flags: 0, textOverride: marker))
            t += gap
            events.append(MacroEvent(time: t, action: .keyUp(0), flags: 0, textOverride: marker))
            t += gap
        }
        return events
    }
}
