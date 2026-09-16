import CoreGraphics

/// A rectangle in global screen coordinates (top-left origin of the main display) that the
/// clicker picks random points from.
struct ClickRegion: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double = 400, y: Double = 300, width: Double = 200, height: Double = 150) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Builds the smallest region containing both corners (never smaller than 1×1).
    init(corner1: CGPoint, corner2: CGPoint) {
        self.init(x: min(corner1.x, corner2.x),
                  y: min(corner1.y, corner2.y),
                  width: max(1, abs(corner2.x - corner1.x)),
                  height: max(1, abs(corner2.y - corner1.y)))
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
