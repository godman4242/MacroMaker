import CoreGraphics

enum MouseButton: String, Codable, CaseIterable, Identifiable, Sendable {
    case left, right, middle

    var id: Self { self }

    var title: String { rawValue.capitalized }

    var cgButton: CGMouseButton {
        switch self {
        case .left: .left
        case .right: .right
        case .middle: .center
        }
    }

    var downEventType: CGEventType {
        switch self {
        case .left: .leftMouseDown
        case .right: .rightMouseDown
        case .middle: .otherMouseDown
        }
    }

    var upEventType: CGEventType {
        switch self {
        case .left: .leftMouseUp
        case .right: .rightMouseUp
        case .middle: .otherMouseUp
        }
    }

    /// Maps a CGEvent mouse button number (0 = left, 1 = right, 2 = middle) to a button.
    /// Extra buttons (back/forward) are not supported and return `nil`.
    init?(buttonNumber: Int64) {
        switch buttonNumber {
        case 0: self = .left
        case 1: self = .right
        case 2: self = .middle
        default: return nil
        }
    }
}
