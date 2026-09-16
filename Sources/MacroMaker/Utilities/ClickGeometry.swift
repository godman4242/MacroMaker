import CoreGraphics

/// Point math for click regions and micro-jitter, kept pure so it can be tested.
enum ClickGeometry {
    /// A uniformly random point inside the rect. `u1`/`u2` are uniforms in 0...1, injected for tests.
    /// Out-of-range uniforms are clamped, so a caller can't land outside the rect.
    static func randomPoint(in rect: CGRect, u1: Double, u2: Double) -> CGPoint {
        CGPoint(x: rect.minX + CGFloat(clamp01(u1)) * rect.width,
                y: rect.minY + CGFloat(clamp01(u2)) * rect.height)
    }

    /// Moves a point by a uniform offset within ±amount on each axis. Amount ≤ 0 returns the point.
    static func jitter(_ point: CGPoint, amount: Double, u1: Double, u2: Double) -> CGPoint {
        let amount = max(0, amount)
        guard amount > 0 else { return point }
        return CGPoint(x: point.x + CGFloat(2 * clamp01(u1) - 1) * CGFloat(amount),
                       y: point.y + CGFloat(2 * clamp01(u2) - 1) * CGFloat(amount))
    }

    private static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
