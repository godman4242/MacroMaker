import CoreGraphics

/// Removes the artifacts that starting and stopping a recording leaves behind.
enum RecordingCleaner {
    /// - Drops key/mouse "ups" whose "down" happened before recording began
    ///   (e.g. releasing the ⌃⌥R that started the recording).
    /// - Drops the trailing run of keys still held when recording stopped
    ///   (e.g. pressing the ⌃⌥R that stopped it) — replaying those would leave keys stuck down.
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

        while let last = kept.last, case let .keyDown(code, _) = last.action, heldKeys.contains(code) {
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
