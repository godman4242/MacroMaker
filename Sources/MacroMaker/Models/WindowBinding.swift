import CoreGraphics
import Foundation

/// Per-app window binding (feature 5, F-14): what a recorded mouse step carries so
/// replay can follow the window it was clicked in, and the pure translation rule.
///
/// A recording made before this feature (or while the window couldn't be resolved) has
/// no anchor and plays absolute — exactly what the app always did. A step WITH an anchor
/// and "Follow the window" on translates by the origin delta, so a window moved since
/// recording still gets its clicks; the app gone or window missing at replay fails the
/// run loud rather than posting into whatever sits at those coordinates now.
struct WindowAnchor: Equatable, Sendable {
    /// The app whose window was clicked (the frontmost app at the mouseDown).
    let bundleID: String
    /// The window's frame origin at record time, in global top-left-origin points.
    let origin: CGPoint
}

enum WindowBinding {
    /// The point to post for a step recorded at `step`: the same spot inside the window,
    /// translated by (current − recorded) window origin. A nil anchor (or nil current
    /// origin, for callers that treat "window gone" differently) plays the recorded point.
    static func translated(_ step: CGPoint, recordedOrigin: CGPoint?, currentOrigin: CGPoint?) -> CGPoint {
        guard let recordedOrigin, let currentOrigin else { return step }
        return CGPoint(x: step.x + (currentOrigin.x - recordedOrigin.x),
                       y: step.y + (currentOrigin.y - recordedOrigin.y))
    }
}