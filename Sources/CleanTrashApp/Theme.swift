import SwiftUI

/// High-contrast Monochrome Black & White design system inspired by monoBOT's precision visual language
/// and tuned for macOS 27 Liquid Glass + crisp tabular telemetry.
enum Mono {
    // MARK: - Surface Palette (Crisp High-Contrast Monochrome)

    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x050505) : Color(hex: 0xF2F2F2)
    }

    static func chrome(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x0B0B0B) : Color(hex: 0xFAFAFA)
    }

    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x141414) : Color(hex: 0xFFFFFF)
    }

    static func cardElevated(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x1D1D1D) : Color(hex: 0xEAEAEA)
    }

    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xF5F5F5) : Color(hex: 0x0D0D0D)
    }

    static func muted(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xA8A8A8) : Color(hex: 0x525252)
    }

    static func subtle(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x767676) : Color(hex: 0x787878)
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.13) : Color.black.opacity(0.11)
    }

    static func hairlineStrong(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.24) : Color.black.opacity(0.22)
    }

    static func primaryFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xF7F7F7) : Color(hex: 0x0E0E0E)
    }

    static func primaryInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x080808) : Color(hex: 0xF8F8F8)
    }

    // Semantic status colors (used sparingly for real health signals & destructive actions)
    static let healthy = Color(hex: 0x34D399)
    static let caution = Color(hex: 0xFBBF24)
    static let danger = Color(hex: 0xF87171)

    /// Subtle monochrome shade ramp for charts & treemaps (pure luminance steps, high legibility).
    static func shade(_ index: Int, scheme: ColorScheme) -> Color {
        let darkSteps: [Double] = [0.95, 0.78, 0.62, 0.48, 0.36, 0.27, 0.20, 0.14]
        let lightSteps: [Double] = [0.08, 0.22, 0.36, 0.48, 0.60, 0.70, 0.78, 0.86]
        let steps = scheme == .dark ? darkSteps : lightSteps
        let w = steps[abs(index) % steps.count]
        return Color(white: w)
    }

    // MARK: - Motion Curves & Springs (ported from monoBOT's motion.rs & notch/mod.rs)

    static let openingSpring = Animation.spring(response: 0.30, dampingFraction: 0.80)
    static let betweenSpring = Animation.spring(response: 0.20, dampingFraction: 0.95)
    static let foldingSpring = Animation.spring(response: 0.26, dampingFraction: 1.0)
    static let emphasized = Animation.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.28)
    static let quick = Animation.timingCurve(0.0, 0.0, 0.58, 1.0, duration: 0.18)
    static let fast = Animation.easeOut(duration: 0.14)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

// MARK: - macOS 27 Liquid Glass + Monochrome Card Modifiers

struct MonoCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var cornerRadius: CGFloat = 14
    var interactive: Bool = false
    var useGlass: Bool = false

    func body(content: Content) -> some View {
        if useGlass, #available(macOS 26.0, *) {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Mono.card(scheme).opacity(0.72))
                )
                .glassEffect(
                    interactive ? .regular.interactive() : .regular,
                    in: .rect(cornerRadius: cornerRadius)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Mono.hairlineStrong(scheme), lineWidth: 1)
                )
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Mono.card(scheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Mono.hairline(scheme), lineWidth: 1)
                )
        }
    }
}

extension View {
    func monoCard(radius: CGFloat = 14, interactive: Bool = false, glass: Bool = false) -> some View {
        modifier(MonoCardModifier(cornerRadius: radius, interactive: interactive, useGlass: glass))
    }

    @ViewBuilder
    func monoGlassPill(interactive: Bool = true) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

// MARK: - Reusable Monochrome Buttons & Badges

struct MonoPrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Mono.primaryInk(scheme))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Mono.primaryFill(scheme).opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1.0) : 0.35))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(Mono.fast, value: configuration.isPressed)
    }
}

struct MonoGhostButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Mono.ink(scheme).opacity(isEnabled ? 1.0 : 0.4))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Mono.ink(scheme).opacity(configuration.isPressed ? 0.18 : 0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Mono.hairline(scheme), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(Mono.fast, value: configuration.isPressed)
    }
}

struct MonoTag: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    var inverted: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(inverted ? Mono.primaryInk(scheme) : Mono.ink(scheme).opacity(0.84))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                Capsule()
                    .fill(inverted ? Mono.primaryFill(scheme) : Mono.ink(scheme).opacity(0.11))
            )
            .overlay(
                Capsule()
                    .strokeBorder(inverted ? Color.clear : Mono.hairline(scheme), lineWidth: 0.75)
            )
    }
}

struct MonoProgressBar: View {
    @Environment(\.colorScheme) private var scheme
    let value: Double // 0...1
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Mono.ink(scheme).opacity(0.16))
                Capsule()
                    .fill(Mono.ink(scheme))
                    .frame(width: max(0, geo.size.width * min(1, max(0, value))))
                    .animation(Mono.betweenSpring, value: value)
            }
        }
        .frame(height: height)
    }
}
