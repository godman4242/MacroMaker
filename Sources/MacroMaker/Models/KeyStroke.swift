import CoreGraphics

/// A fully resolved key press: which key to post and which modifiers to hold while doing so.
struct KeyStroke: Equatable, Sendable {
    enum Key: Equatable, Sendable {
        /// A physical key, identified by its virtual key code. Can be held down.
        case code(CGKeyCode)
        /// Text that isn't on the current keyboard layout (e.g. "é" on a US layout).
        /// Posted as a Unicode string, so it can be tapped but not held.
        case text(String)
    }

    let key: Key
    /// Every modifier held during the press, including ones the layout needs (⇧ for "!").
    let modifiers: KeyModifiers
    /// Human-readable description, e.g. "⌘⇧A", "Space", "!".
    let label: String

    var canHold: Bool {
        if case .code = key { return true }
        return false
    }
}
