import Foundation
import Testing
@testable import MacroMaker

@Suite struct MacroFileTests {
    private let sample = Macro(
        name: "Login",
        createdAt: Date(timeIntervalSince1970: 1_789_000_000),
        events: [
            MacroEvent(time: 0, action: .mouseDown(.left, CGPoint(x: 512, y: 384.5), clickCount: 2), flags: 256),
            MacroEvent(time: 0.08, action: .mouseUp(.right, CGPoint(x: -10, y: 20), clickCount: 1), flags: 256),
            MacroEvent(time: 1.5, action: .keyDown(0, isRepeat: true), flags: 0x20_0100),
            MacroEvent(time: 1.6, action: .keyUp(0), flags: 256),
        ]
    )

    @Test func roundTrip() throws {
        #expect(try Macro(jsonData: sample.jsonData()) == sample)
    }

    /// Pins the on-disk format: files saved by version 1 must keep opening.
    @Test func decodesVersionOneFile() throws {
        let json = """
        { "format": "macromaker", "version": 1, "name": "Pinned", "createdAt": "2026-09-16T10:00:00Z",
          "events": [
            { "t": 0, "type": "mouseDown", "button": "middle", "x": 1, "y": 2, "clickCount": 1, "flags": 0 },
            { "t": 0.5, "type": "keyDown", "keyCode": 36, "repeat": false, "flags": 0 },
            { "t": 0.6, "type": "keyUp", "keyCode": 36 }
          ] }
        """
        let macro = try Macro(jsonData: Data(json.utf8))
        #expect(macro.name == "Pinned")
        #expect(macro.events.map(\.action) == [
            .mouseDown(.middle, CGPoint(x: 1, y: 2), clickCount: 1),
            .keyDown(36, isRepeat: false),
            .keyUp(36),
        ])
        #expect(macro.events[2].flags == 0, "missing flags default to 0")
        #expect(macro.duration == 0.6)
    }

    @Test func rejectsOtherFormatsAndNewerVersions() {
        let wrongFormat = #"{ "format": "other", "version": 1, "name": "x", "createdAt": "2026-09-16T10:00:00Z", "events": [] }"#
        let newer = #"{ "format": "macromaker", "version": 99, "name": "x", "createdAt": "2026-09-16T10:00:00Z", "events": [] }"#
        let badType = #"{ "format": "macromaker", "version": 1, "name": "x", "createdAt": "2026-09-16T10:00:00Z", "events": [ { "t": 0, "type": "scroll" } ] }"#
        for json in [wrongFormat, newer, badType, "not json"] {
            #expect(throws: DecodingError.self) { try Macro(jsonData: Data(json.utf8)) }
        }
    }
}
