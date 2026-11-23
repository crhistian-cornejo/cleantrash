import SwiftUI

/// Hardware-fused Dynamic Notch silhouette with concave top shoulders
/// (inspired by monoBOT's notch geometry), smoothly morphing into a floating
/// pill when `isIsland` is active.
struct NotchShape: Shape {
    var topShoulderRadius: CGFloat
    var bottomCornerRadius: CGFloat
    var isIsland: Bool
    var closeTopEdge: Bool = true

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topShoulderRadius, bottomCornerRadius) }
        set {
            topShoulderRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        if isIsland {
            return Path(roundedRect: rect, cornerRadius: bottomCornerRadius, style: .continuous)
        }

        let s = min(topShoulderRadius, rect.width / 6, rect.height / 3)
        let r = min(bottomCornerRadius, (rect.width - s * 2) / 2, rect.height / 2)

        var path = Path()
        // Start at top-left flare tip
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Concave top-left shoulder curving inward into the vertical side
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + s, y: rect.minY + s),
            control: CGPoint(x: rect.minX + s, y: rect.minY)
        )
        // Left vertical edge down to bottom-left corner
        path.addLine(to: CGPoint(x: rect.minX + s, y: rect.maxY - r))
        // Bottom-left rounded corner
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + s + r, y: rect.maxY),
            control: CGPoint(x: rect.minX + s, y: rect.maxY)
        )
        // Bottom edge
        path.addLine(to: CGPoint(x: rect.maxX - s - r, y: rect.maxY))
        // Bottom-right rounded corner
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - s, y: rect.maxY - r),
            control: CGPoint(x: rect.maxX - s, y: rect.maxY)
        )
        // Right vertical edge up to top-right shoulder
        path.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY + s))
        // Concave top-right shoulder flaring outward to top edge
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - s, y: rect.minY)
        )
        if closeTopEdge {
            path.closeSubpath()
        }
        return path
    }
}
