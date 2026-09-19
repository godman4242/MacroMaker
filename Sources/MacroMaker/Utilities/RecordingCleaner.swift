import CoreGraphics

/// Removes the artifacts that starting and stopping a recording leaves behind.
enum RecordingCleaner {
    /// - Drops key/mouse "ups" whose "down" happened before recording began
    ///   (e.g. releasing the ⌃⌥R that started the recording).
    /// - Drops the trailing run of keys *and buttons* still held when recording stopped
    ///   (e.g. pressing the ⌃⌥R that stopped it, or a button still down at the stop) — replaying
    ///   those would leave inputs stuck down.
    /// - Shifts time so the first event happens at 0 (no dead wait at the start of playback).
    static func clean(_ events: [MacroEvent]) -> [MacroEvent] {
        var heldKeys = Set<CGKeyCode>()
        var heldButtons = Set<MouseButton>()
        var kept: [MacroEvent] = []

        for event in events {
            switch event.action {
            case let .keyDown(code, _):
                heldKeys.insert(code)
                kept.append(event)
            case let .keyUp(code):
                if heldKeys.remove(code) != nil { kept.append(event) }
            case let .mouseDown(button, _, _):
                heldButtons.insert(button)
                kept.append(event)
            case let .mouseUp(button, _, _):
                if heldButtons.remove(button) != nil { kept.append(event) }
            }
        }

        while let last = kept.last {
            let stillHeld: Bool
            switch last.action {
            case let .keyDown(code, _): stillHeld = heldKeys.contains(code)
            case let .mouseDown(button, _, _): stillHeld = heldButtons.contains(button)
            default: stillHeld = false
            }
            guard stillHeld else { break }
            kept.removeLast()
        }

        guard let start = kept.first?.time else { return [] }
        return kept.map { event in
            var shifted = event
            shifted.time -= start
            return shifted
        }
    }
}
