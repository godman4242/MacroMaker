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

    /// Tolerant per-field decoding (review N4): a corrupt region used to throw through the
    /// settings' `decodeIfPresent` and, via `Persistence.load`'s `try?`, silently reset the
    /// WHOLE AutoClickerSettings blob to defaults. One unreadable or out-of-range field now
    /// costs that field alone. Bounds mirror the UI's NumberFields; non-finite values fall
    /// back to the field default (min/max propagate NaN).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = Self.field(c, .x, fallback: 400, in: -20_000...20_000)
        y = Self.field(c, .y, fallback: 300, in: -20_000...20_000)
        width = Self.field(c, .width, fallback: 200, in: 1...20_000)
        height = Self.field(c, .height, fallback: 150, in: 1...20_000)
    }

    private enum CodingKeys: String, CodingKey { case x, y, width, height }

    private static func field(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys,
                              fallback: Double, in range: ClosedRange<Double>) -> Double {
        guard let raw = ((try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil), raw.isFinite
        else { return fallback }
        return min(max(raw, range.lowerBound), range.upperBound)
    }
}
