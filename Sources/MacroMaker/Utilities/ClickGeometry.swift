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

    /// Pulls a point back inside a rect (H5: jitter must not push a click outside the window
    /// it is aimed at). An empty rect returns the point unchanged.
    ///
    /// The max edges are EXCLUSIVE: a point clamped ONTO `rect.maxX` sits on the window's
    /// boundary, where a real click lands on the neighbouring surface — and the game route's
    /// visibility gate (`CGRect.contains`, max-exclusive by contract) rejects it as covered,
    /// so the two disagree and jitter toward the far edge was refused as "covered" by nothing.
    /// Clamp steps one ULP inside instead (`nextDown`, not −1 pt: the click position must not
    /// visibly jump). The min edges were already fine: `contains` accepts them.
    static func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        guard !rect.isEmpty else { return point }
        return CGPoint(x: min(max(point.x, rect.minX), rect.maxX.nextDown),
                       y: min(max(point.y, rect.minY), rect.maxY.nextDown))
    }

    private static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
