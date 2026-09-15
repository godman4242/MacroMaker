import CoreGraphics
import Foundation

/// A recorded sequence of mouse clicks and key presses, saved as a `.macromaker` JSON file.
///
/// File format (version 1):
/// ```json
/// { "format": "macromaker", "version": 1, "name": "Login", "createdAt": "2026-09-16T10:00:00Z",
///   "events": [
///     { "t": 0,    "type": "mouseDown", "button": "left", "x": 512, "y": 384, "clickCount": 1, "flags": 256 },
///     { "t": 0.08, "type": "mouseUp",   "button": "left", "x": 512, "y": 384, "clickCount": 1, "flags": 256 },
///     { "t": 1.5,  "type": "keyDown",   "keyCode": 0, "repeat": false, "flags": 256 },
///     { "t": 1.6,  "type": "keyUp",     "keyCode": 0, "flags": 256 } ] }
/// ```
/// `t` is seconds from the first event, `x`/`y` are global screen points (origin top-left of the
/// main display), `keyCode` is a macOS virtual key code and `flags` the raw CGEventFlags.
struct Macro: Codable, Equatable, Sendable {
    static let fileExtension = "macromaker"
    static let formatName = "macromaker"
    static let formatVersion = 1

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
        guard version <= Self.formatVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "This macro was saved by a newer version of Macro Maker.")
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
    }

    /// Seconds since the start of the macro.
    var time: TimeInterval
    var action: Action
    /// Raw `CGEventFlags` at the moment of the event (which modifiers were held).
    var flags: UInt64

    @MainActor var summary: String {
        switch action {
        case let .mouseDown(button, point, clickCount):
            "\(button.title) mouse down at \(Int(point.x)), \(Int(point.y))" + (clickCount > 1 ? " (×\(clickCount))" : "")
        case let .mouseUp(button, point, _):
            "\(button.title) mouse up at \(Int(point.x)), \(Int(point.y))"
        case let .keyDown(keyCode, isRepeat):
            "Key down \(KeyboardLayout.displayName(for: keyCode))" + (isRepeat ? " (repeat)" : "")
        case let .keyUp(keyCode):
            "Key up \(KeyboardLayout.displayName(for: keyCode))"
        }
    }
}

extension MacroEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case time = "t", type, button, x, y, clickCount, keyCode, isRepeat = "repeat", flags
    }

    private enum EventType: String, Codable {
        case mouseDown, mouseUp, keyDown, keyUp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(TimeInterval.self, forKey: .time)
        flags = try c.decodeIfPresent(UInt64.self, forKey: .flags) ?? 0
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
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(time, forKey: .time)
        try c.encode(flags, forKey: .flags)
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
        }
    }
}

private extension MacroEvent.Action {
    var isMouseDown: Bool {
        if case .mouseDown = self { return true }
        return false
    }
}
