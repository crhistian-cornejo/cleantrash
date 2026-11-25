import SwiftUI

/// Hardware-fused Dynamic Notch silhouette with smooth, generous concave top shoulders
/// (matching Droppy's liquid top-to-bottom drop) that morphs cleanly into a floating rounded
/// island pill when `isIsland` is active.
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

        let s = min(topShoulderRadius, rect.width / 5, rect.height / 3)
        let r = min(bottomCornerRadius, (rect.width - s * 2) / 2, rect.height / 2)

        var path = Path()
        // Start at top-left flare tip fused to the screen top edge
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Silky cubic concave top-left shoulder curving inward into the vertical side
        path.addCurve(
            to: CGPoint(x: rect.minX + s, y: rect.minY + s),
            control1: CGPoint(x: rect.minX + s * 0.62, y: rect.minY),
            control2: CGPoint(x: rect.minX + s, y: rect.minY + s * 0.35)
        )
        // Left vertical edge down to bottom-left corner
        path.addLine(to: CGPoint(x: rect.minX + s, y: rect.maxY - r))
        // Smooth bottom-left continuous corner
        path.addCurve(
            to: CGPoint(x: rect.minX + s + r, y: rect.maxY),
            control1: CGPoint(x: rect.minX + s, y: rect.maxY - r * 0.36),
            control2: CGPoint(x: rect.minX + s + r * 0.36, y: rect.maxY)
        )
        // Bottom edge
        path.addLine(to: CGPoint(x: rect.maxX - s - r, y: rect.maxY))
        // Smooth bottom-right continuous corner
        path.addCurve(
            to: CGPoint(x: rect.maxX - s, y: rect.maxY - r),
            control1: CGPoint(x: rect.maxX - s - r * 0.36, y: rect.maxY),
            control2: CGPoint(x: rect.maxX - s, y: rect.maxY - r * 0.36)
        )
        // Right vertical edge up to top-right shoulder
        path.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY + s))
        // Silky cubic concave top-right shoulder flaring outward to the top bezel
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(x: rect.maxX - s, y: rect.minY + s * 0.35),
            control2: CGPoint(x: rect.maxX - s * 0.62, y: rect.minY)
        )
        if closeTopEdge {
            path.closeSubpath()
        }
        return path
    }
}
