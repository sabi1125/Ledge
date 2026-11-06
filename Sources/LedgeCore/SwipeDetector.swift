import CoreGraphics

/// Turns a stream of two-finger scroll deltas into at most one swipe per gesture.
public struct SwipeDetector: Sendable {
    public enum Phase: Sendable { case began, changed, ended }
    public enum Direction: Equatable, Sendable { case left, right }

    public var threshold: CGFloat
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var fired = false

    public init(threshold: CGFloat = 55) {
        self.threshold = threshold
    }

    /// `dx`/`dy` are physical finger movement (positive x = fingers moved right).
    public mutating func handle(dx: CGFloat, dy: CGFloat, phase: Phase) -> Direction? {
        switch phase {
        case .began:
            accumulatedX = dx
            accumulatedY = dy
            fired = false
        case .changed:
            accumulatedX += dx
            accumulatedY += dy
        case .ended:
            accumulatedX = 0
            accumulatedY = 0
            fired = false
            return nil
        }
        guard !fired, abs(accumulatedX) >= threshold, abs(accumulatedX) > abs(accumulatedY) * 2 else {
            return nil
        }
        fired = true
        return accumulatedX < 0 ? .left : .right
    }
}
