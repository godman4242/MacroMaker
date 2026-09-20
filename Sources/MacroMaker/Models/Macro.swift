import CoreGraphics
import Foundation

/// A recorded sequence of mouse clicks, key presses, scrolls and cursor moves, saved as a
/// `.macromaker` JSON file.
///
/// File format (version 2 — version 1 files keep opening; v2 adds the `scroll` and `move`
/// step kinds and nothing else):
/// ```json
/// { "format": "macromaker", "version": 2, "name": "Login", "createdAt": "2026-09-16T10:00:00Z",
///   "events": [
///     { "t": 0,    "type": "mouseDown", "button": "left", "x": 512, "y": 384, "clickCount": 1, "flags": 256 },
///     { "t": 0.08, "type": "mouseUp",   "button": "left", "x": 512, "y": 384, "clickCount": 1, "flags": 256 },
///     { "t": 1.5,  "type": "keyDown",   "keyCode": 0, "repeat": false, "flags": 256 },
///     { "t": 1.6,  "type": "keyUp",     "keyCode": 0, "flags": 256 },
///     { "t": 2.0,  "type": "scroll",    "x": 512, "y": 384, "dx": 0, "dy": -24, "flags": 256 },
///     { "t": 2.1,  "type": "move",      "x": 600, "y": 400, "flags": 256 } ] }
/// ```
/// `t` is seconds from the first event, `x`/`y` are global screen points (origin top-left of the
/// main display), `keyCode` is a macOS virtual key code and `flags` the raw CGEventFlags.
/// `scroll` carries the pixel deltas of one scroll-wheel notch in `dx` (horizontal) and
/// `dy` (vertical, negative = towards the content's end); `move` is one throttled cursor move.
struct Macro: Codable, Equatable, Sendable {
    static let fileExtension = "macromaker"
    static let formatName = "macromaker"
    static let formatVersion = 2

    var name: String
    var createdAt: Date
    var events: [MacroEvent]

    var duration: TimeInterval { events.last?.time ?? 0 }

    private enum CodingKeys: String, CodingKey {
        case format, version, name, createdAt, events
    }

    init(name: String, createdAt: Date = Date(), events: [MacroEvent]) {
        self.name = name
        self.createdAt = createdAt
        self.events = events
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let format = try container.decode(String.self, forKey: .format)
        guard format == Self.formatName else {
            throw DecodingError.dataCorruptedError(forKey: .format, in: container, debugDescription: "Not a Macro Maker file.")
        }
        let version = try container.decode(Int.self, forKey: .version)
        guard (1...Self.formatVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: version > Self.formatVersion ? "This macro was saved by a newer version of Macro Maker." : "This macro's format version is not recognised.")
        }
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        events = try container.decode([MacroEvent].self, forKey: .events)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.formatName, forKey: .format)
        try container.encode(Self.formatVersion, forKey: .version)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(events, forKey: .events)
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    init(jsonData: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self = try decoder.decode(Macro.self, from: jsonData)
    }
}

struct MacroEvent: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case mouseDown(MouseButton, CGPoint, clickCount: Int)
        case mouseUp(MouseButton, CGPoint, clickCount: Int)
        /// `isRepeat` marks the auto-repeat presses macOS generates while a key is held.
        case keyDown(CGKeyCode, isRepeat: Bool)
        case keyUp(CGKeyCode)
        /// One scroll-wheel notch at `point`: pixel deltas `dx` (horizontal) and `dy`
        /// (vertical, negative = the wheel's natural down direction).
        case scroll(CGPoint, dx: Int, dy: Int)
        /// One cursor move at `point` (the recorder throttles these to ~10 a second).
        case move(CGPoint)
        /// Run another macro by its LIBRARY id — resolved at run time, so a renamed or
        /// re-saved macro keeps working and a deleted one fails loud (not a silent skip).
        case runMacro(UUID)
    }

    /// Seconds since the start of the macro.
    var time: TimeInterval
    var action: Action
    /// Raw `CGEventFlags` at the moment of the event (which modifiers were held).
    var flags: UInt64
    /// Step-editor insertions can attach a Unicode character to a placeholder key transition;
    /// playback posts it as a Unicode string (like `KeyStroke.text`) instead of key code 0.
    /// Always nil on real recordings; part of the envelope but not of v1 `.macromaker` files.
    var textOverride: String?

    init(time: TimeInterval, action: Action, flags: UInt64, textOverride: String? = nil) {
        self.time = time
        self.action = action
        self.flags = flags
        self.textOverride = textOverride
    }

    @MainActor var summary: String {
        switch action {
        case let .mouseDown(button, point, clickCount):
            return "\(button.title) mouse down at \(Int(point.x)), \(Int(point.y))" + (clickCount > 1 ? " (×\(clickCount))" : "")
        case let .mouseUp(button, point, _):
            return "\(button.title) mouse up at \(Int(point.x)), \(Int(point.y))"
        case let .keyDown(keyCode, isRepeat):
            if let textOverride { return "Type “\(textOverride)”" }
            return "Key down \(KeyboardLayout.displayName(for: keyCode))" + (isRepeat ? " (repeat)" : "")
        case let .keyUp(keyCode):
            if textOverride != nil { return "(end character)" }
            return "Key up \(KeyboardLayout.displayName(for: keyCode))"
        case let .scroll(_, dx, dy):
            let amount = (abs(dy) >= abs(dx) ? dy : dx)
            let direction = (abs(dy) >= abs(dx) ? (dy < 0 ? "down" : "up") : (dx < 0 ? "left" : "right"))
            return "Scroll \(direction) \(abs(amount)) px"
        case let .move(point):
            return "Move to \(Int(point.x)), \(Int(point.y))"
        case .runMacro:
            return "Run macro"
        }
    }
}

extension MacroEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case time = "t", type, button, x, y, clickCount, keyCode, isRepeat = "repeat", flags,
             dx, dy, macroID = "macro"
        /// Editor insertions attach their character to a placeholder key transition via the
        /// optional "text" key. V1-era readers ignore unknown keys and load the file fine —
        /// they'd just play those transitions as key-code-0 presses, so share edited macros
        /// with Macro Maker 2.0 or newer.
        case textOverride = "text"
    }

    private enum EventType: String, Codable {
        case mouseDown, mouseUp, keyDown, keyUp
        /// Version 2 step kinds; a v1 reader rejects them by their unknown `type` name.
        case scroll, move
        /// Version 2.1 (feature 4): run another macro by its library id.
        case runMacro = "runMacro"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(TimeInterval.self, forKey: .time)
        // A time that is negative or non-finite reaches `UInt64(_:)` in the playback loop, which
        // traps and kills the app. JSON has no NaN literal, but `1e400` parses to +infinity.
        guard time.isFinite, time >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .time, in: c,
                debugDescription: "Event time must be a finite, non-negative number of seconds, got \(time).")
        }
        flags = try c.decodeIfPresent(UInt64.self, forKey: .flags) ?? 0
        textOverride = try c.decodeIfPresent(String.self, forKey: .textOverride)
        let type = try c.decode(EventType.self, forKey: .type)
        switch type {
        case .mouseDown, .mouseUp:
            let button = try c.decode(MouseButton.self, forKey: .button)
            let point = CGPoint(x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y))
            let clickCount = try c.decodeIfPresent(Int.self, forKey: .clickCount) ?? 1
            action = type == .mouseDown
                ? .mouseDown(button, point, clickCount: clickCount)
                : .mouseUp(button, point, clickCount: clickCount)
        case .keyDown:
            action = .keyDown(try c.decode(CGKeyCode.self, forKey: .keyCode),
                              isRepeat: try c.decodeIfPresent(Bool.self, forKey: .isRepeat) ?? false)
        case .keyUp:
            action = .keyUp(try c.decode(CGKeyCode.self, forKey: .keyCode))
        case .scroll:
            let point = CGPoint(x: (try? c.decodeIfPresent(Double.self, forKey: .x)) ?? nil ?? 0,
                                y: (try? c.decodeIfPresent(Double.self, forKey: .y)) ?? nil ?? 0)
            action = .scroll(point, dx: Self.delta(c, .dx), dy: Self.delta(c, .dy))
        case .move:
            let point = CGPoint(x: (try? c.decodeIfPresent(Double.self, forKey: .x)) ?? nil ?? 0,
                                y: (try? c.decodeIfPresent(Double.self, forKey: .y)) ?? nil ?? 0)
            action = .move(point)
        case .runMacro:
            // Not tolerant: a run-macro step without its id is a corrupt step, and a
            // silent "run nothing" would hide a broken chain behind a green run.
            action = .runMacro(try c.decode(UUID.self, forKey: .macroID))
        }
    }

    /// One scroll delta; absent decodes as 0 (the axis wasn't scrolled).
    private static func delta(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int {
        ((try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(time, forKey: .time)
        try c.encode(flags, forKey: .flags)
        if let textOverride { try c.encode(textOverride, forKey: .textOverride) }
        switch action {
        case let .mouseDown(button, point, clickCount), let .mouseUp(button, point, clickCount):
            try c.encode(action.isMouseDown ? EventType.mouseDown : .mouseUp, forKey: .type)
            try c.encode(button, forKey: .button)
            try c.encode(Double(point.x), forKey: .x)
            try c.encode(Double(point.y), forKey: .y)
            try c.encode(clickCount, forKey: .clickCount)
        case let .keyDown(keyCode, isRepeat):
            try c.encode(EventType.keyDown, forKey: .type)
            try c.encode(keyCode, forKey: .keyCode)
            try c.encode(isRepeat, forKey: .isRepeat)
        case let .keyUp(keyCode):
            try c.encode(EventType.keyUp, forKey: .type)
            try c.encode(keyCode, forKey: .keyCode)
        case let .scroll(aPoint, dx, dy):
            try c.encode(EventType.scroll, forKey: .type)
            try c.encode(Double(aPoint.x), forKey: .x)
            try c.encode(Double(aPoint.y), forKey: .y)
            try c.encode(dx, forKey: .dx)
            try c.encode(dy, forKey: .dy)
        case let .move(aPoint):
            try c.encode(EventType.move, forKey: .type)
            try c.encode(Double(aPoint.x), forKey: .x)
            try c.encode(Double(aPoint.y), forKey: .y)
        case let .runMacro(id):
            try c.encode(EventType.runMacro, forKey: .type)
            try c.encode(id, forKey: .macroID)
        }
    }
}

private extension MacroEvent.Action {
    var isMouseDown: Bool {
        if case .mouseDown = self { return true }
        return false
    }
}
