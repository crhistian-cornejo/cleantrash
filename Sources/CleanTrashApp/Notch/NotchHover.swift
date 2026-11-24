import SwiftUI

/// Buttons on the notch: glow + slight lift on hover, press-down on click, pointing-hand cursor.
struct NotchButtonStyle: ButtonStyle {
    var hoverScale: CGFloat = 1.04

    func makeBody(configuration: Configuration) -> some View {
        NotchButtonBody(configuration: configuration, hoverScale: hoverScale)
    }
}

private struct NotchButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let hoverScale: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var active: Bool { hovering && isEnabled }

    var body: some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.05 : (active ? 0.07 : 0))
            .shadow(color: .white.opacity(active ? 0.22 : 0), radius: active ? 7 : 0)
            .scaleEffect(configuration.isPressed ? 0.95 : (active ? hoverScale : 1))
            .animation(Mono.fast, value: active)
            .animation(Mono.fast, value: configuration.isPressed)
            .onHover { hovering = $0 }
            .pointingHandCursor()
    }
}

/// List rows on the notch (processes, projects, disk items): the fill lifts and a hairline appears on hover.
struct NotchHoverRow: ViewModifier {
    var cornerRadius: CGFloat = 8
    var base: Double = 0.04
    var hover: Double = 0.09
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(hovering ? hover : base))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(hovering ? 0.1 : 0), lineWidth: 1)
            )
            .onHover { inside in
                withAnimation(Mono.fast) { hovering = inside }
            }
    }
}

/// Card tiles (quick actions): darker card that brightens, strokes and lifts on hover.
struct NotchCardHover: ViewModifier {
    var cornerRadius: CGFloat = 11
    var isArmed = false
    var isEnabled = true
    @State private var hovering = false

    private var active: Bool { hovering && isEnabled }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(hex: active ? 0x1C1C1C : 0x121212))
            )
            .background(alignment: .topLeading) {
                // Soft spotlight in the corner where the icon sits.
                if active {
                    Circle()
                        .fill(Color.white.opacity(0.09))
                        .frame(width: 70, height: 70)
                        .blur(radius: 18)
                        .offset(x: -10, y: -14)
                        .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isArmed ? Mono.danger.opacity(0.8) : Color.white.opacity(active ? 0.3 : 0.14),
                        lineWidth: 1
                    )
            )
            .scaleEffect(active ? 1.015 : 1)
            .animation(Mono.fast, value: active)
            .onHover { hovering = $0 }
    }
}

extension View {
    func notchHoverRow(cornerRadius: CGFloat = 8, base: Double = 0.04, hover: Double = 0.09) -> some View {
        modifier(NotchHoverRow(cornerRadius: cornerRadius, base: base, hover: hover))
    }
}
