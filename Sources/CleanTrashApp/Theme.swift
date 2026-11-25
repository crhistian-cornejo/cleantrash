import CleanTrashCore
import SwiftUI

/// High-contrast Dynamic Glass & Monochrome design system unified across the Dynamic Notch
/// and the Main Dashboard Window for macOS 26/27 Liquid Glass + crisp tabular telemetry.
enum Mono {
    /// Debug snapshots: ImageRenderer can't draw Liquid Glass, so cards fall back to flat fills.
    nonisolated(unsafe) static var snapshotMode = false

    // MARK: - Surface Palette (Dynamic Glass + High-Contrast Obsidian)

    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x050507) : Color(hex: 0xF3F4F6)
    }

    static func chrome(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x090A0E) : Color(hex: 0xF9FAFB)
    }

    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.052) : Color.white.opacity(0.76)
    }

    static func cardSolid(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x111216) : Color(hex: 0xFFFFFF)
    }

    static func cardElevated(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.088) : Color.white.opacity(0.90)
    }

    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xF7F7F9) : Color(hex: 0x0D0E11)
    }

    static func muted(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xA6AAB4) : Color(hex: 0x4F545F)
    }

    static func subtle(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x727681) : Color(hex: 0x747A86)
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.09)
    }

    static func hairlineStrong(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.18)
    }

    static func primaryFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xF8F8FA) : Color(hex: 0x0F1115)
    }

    static func primaryInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x08080A) : Color(hex: 0xF8F9FA)
    }

    // Semantic status & Notch telemetry colors (shared 1:1 with the Dynamic Notch)
    static let healthy = Color(hex: 0x34D399)
    static let caution = Color(hex: 0xFBBF24)
    static let danger = Color(hex: 0xF87171)

    static let cpuAccent = Color(hex: 0x818CF8)     // Indigo
    static let ramAccent = Color(hex: 0x6EE7B7)     // Mint
    static let gpuAccent = Color(hex: 0x38BDF8)     // Cyan
    static let appsAccent = Color(hex: 0x3B82F6)    // Blue
    static let junkAccent = Color(hex: 0xF59E0B)    // Amber
    static let networkAccent = Color(hex: 0xA78BFA) // Violet
    static let batteryAccent = Color(hex: 0x34D399) // Emerald

    /// Subtle luminance ramp for charts & treemaps (high legibility on glass & obsidian).
    static func shade(_ index: Int, scheme: ColorScheme) -> Color {
        let darkSteps: [Double] = [0.92, 0.74, 0.58, 0.44, 0.34, 0.25, 0.19, 0.14]
        let lightSteps: [Double] = [0.10, 0.24, 0.38, 0.50, 0.62, 0.72, 0.80, 0.88]
        let steps = scheme == .dark ? darkSteps : lightSteps
        let w = steps[abs(index) % steps.count]
        return Color(white: w)
    }

    /// Refined Notch-aligned category palette for Disk Map charts & treemap accents.
    static func categoryAccent(_ index: Int, scheme: ColorScheme) -> Color {
        let palette: [Color] = [
            appsAccent,
            cpuAccent,
            ramAccent,
            gpuAccent,
            junkAccent,
            networkAccent,
            scheme == .dark ? Color.white.opacity(0.45) : Color.black.opacity(0.42)
        ]
        return palette[abs(index) % palette.count]
    }

    // MARK: - Motion Curves & Springs

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

// MARK: - Main Window Dynamic Glass Backdrop (Unified with NotchSurfaceMode)

/// Matches the Notch's exact Dynamic Glass / Liquid Glass / Obsidian surface philosophy
/// while respecting Apple HIG: a single behind-window translucent layer (no stacked glass-on-glass)
/// and automatic fallback when Reduce Transparency or Low Power Mode is enabled.
struct DashboardWindowBackground: View {
    let surface: NotchSurfaceMode
    let scheme: ColorScheme
    var ambientAccent: Color? = nil

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var forceSolid: Bool {
        Mono.snapshotMode || reduceTransparency || ProcessInfo.processInfo.isLowPowerModeEnabled || surface == .obsidian
    }

    var body: some View {
        ZStack {
            if forceSolid {
                Mono.canvas(scheme)
            } else {
                // Single native macOS behind-window translucency layer
                VisualEffectBackdrop(
                    material: scheme == .dark ? .underWindowBackground : .hudWindow,
                    blendingMode: .behindWindow
                )

                // Deep top-to-bottom Dynamic Glass veil (echoes the Notch's obsidian-to-glass fade)
                LinearGradient(
                    stops: veilStops,
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            if let ambientAccent {
                RadialGradient(
                    colors: [
                        ambientAccent.opacity(scheme == .dark ? (surface == .clearGlass ? 0.11 : 0.08) : 0.07),
                        .clear
                    ],
                    center: .topTrailing,
                    startRadius: 20,
                    endRadius: 560
                )
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }

    private var veilStops: [Gradient.Stop] {
        let clear = surface == .clearGlass
        if scheme == .dark {
            return clear
                ? [
                    .init(color: Color(hex: 0x040407).opacity(0.68), location: 0.0),
                    .init(color: Color(hex: 0x06070C).opacity(0.58), location: 0.45),
                    .init(color: Color(hex: 0x080A10).opacity(0.52), location: 1.0)
                ]
                : [
                    .init(color: Color(hex: 0x030306).opacity(0.86), location: 0.0),
                    .init(color: Color(hex: 0x06070B).opacity(0.78), location: 0.45),
                    .init(color: Color(hex: 0x090A10).opacity(0.70), location: 1.0)
                ]
        } else {
            return clear
                ? [
                    .init(color: Color(hex: 0xF7F8FA).opacity(0.64), location: 0.0),
                    .init(color: Color(hex: 0xF1F3F7).opacity(0.56), location: 1.0)
                ]
                : [
                    .init(color: Color(hex: 0xF8F9FB).opacity(0.84), location: 0.0),
                    .init(color: Color(hex: 0xEFF1F5).opacity(0.76), location: 1.0)
                ]
        }
    }
}

// MARK: - macOS 27 Dynamic Glass Card Modifiers

struct MonoCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.notchSurface) private var surface
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var cornerRadius: CGFloat = 16
    var interactive: Bool = false
    var useGlass: Bool = false

    func body(content: Content) -> some View {
        let isObsidian = surface == .obsidian || reduceTransparency || Mono.snapshotMode
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if useGlass, !isObsidian, !Mono.snapshotMode, #available(macOS 26.0, *) {
            // Hero / Highlight card: elevated luminous glass layer with specular bevel
            content
                .background(
                    shape.fill(
                        scheme == .dark
                            ? Color.white.opacity(surface == .clearGlass ? 0.075 : 0.062)
                            : Color.white.opacity(0.82)
                    )
                )
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: scheme == .dark
                                ? [Color.white.opacity(0.24), Color.white.opacity(0.08), Color.white.opacity(0.14)]
                                : [Color.white.opacity(0.95), Color.black.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                )
                .shadow(color: .black.opacity(scheme == .dark ? 0.34 : 0.06), radius: 18, y: 8)
        } else {
            content
                .background(
                    shape.fill(isObsidian ? Mono.cardSolid(scheme) : Mono.card(scheme))
                )
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: scheme == .dark
                                ? [Color.white.opacity(0.15), Color.white.opacity(0.06)]
                                : [Color.white.opacity(0.85), Color.black.opacity(0.09)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.9
                    )
                )
                .shadow(color: .black.opacity(scheme == .dark ? 0.20 : 0.04), radius: 10, y: 4)
        }
    }
}

extension View {
    func monoCard(radius: CGFloat = 16, interactive: Bool = false, glass: Bool = false) -> some View {
        modifier(MonoCardModifier(cornerRadius: radius, interactive: interactive, useGlass: glass))
    }

    @ViewBuilder
    func monoGlassPill(interactive: Bool = true) -> some View {
        if !Mono.snapshotMode, #available(macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

// MARK: - Reusable Notch-Matched 3D Metric Ring

/// Signature Dynamic Notch visual: our custom 3D glass icon nested inside a glowing circular
/// progress ring with crisp tabular percentage and accent tint.
struct MetricRing3D: View {
    let icon: Icon3DName
    let percent: Double
    let tint: Color
    var size: CGFloat = 46
    var iconSize: CGFloat? = nil
    var lineWidth: CGFloat = 3.5

    @Environment(\.colorScheme) private var scheme

    private var clamped: Double { min(1, max(0, percent / 100.0)) }

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(scheme == .dark ? 0.11 : 0.10))
            Circle()
                .stroke(
                    scheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.08),
                    lineWidth: lineWidth
                )
            Circle()
                .trim(from: 0, to: max(0.03, clamped))
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(scheme == .dark ? 0.45 : 0.20), radius: 4)
                .animation(Mono.betweenSpring, value: clamped)

            Icon3D(name: icon, size: iconSize ?? (size * 0.56))
        }
        .frame(width: size, height: size)
    }
}

/// Matching glowing circular ring for SF Symbols (Network, Battery, Focus, etc.).
struct MetricSymbolRing: View {
    let symbol: String
    let percent: Double
    let tint: Color
    var size: CGFloat = 46
    var lineWidth: CGFloat = 3.5

    @Environment(\.colorScheme) private var scheme

    private var clamped: Double { min(1, max(0, percent / 100.0)) }

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(scheme == .dark ? 0.11 : 0.10))
            Circle()
                .stroke(
                    scheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.08),
                    lineWidth: lineWidth
                )
            Circle()
                .trim(from: 0, to: max(0.03, clamped))
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(scheme == .dark ? 0.42 : 0.18), radius: 4)
                .animation(Mono.betweenSpring, value: clamped)

            Image(systemName: symbol)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Reusable Capsule Buttons, Tags & Bars (Notch Dock Style)

struct MonoPrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Mono.primaryInk(scheme))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Mono.primaryFill(scheme).opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1.0) : 0.35))
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0.28 : 0.10), radius: 6, y: 2)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(Mono.fast, value: configuration.isPressed)
    }
}

struct MonoGhostButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Mono.ink(scheme).opacity(isEnabled ? 0.92 : 0.4))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Mono.ink(scheme).opacity(configuration.isPressed ? 0.18 : 0.085))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Mono.hairline(scheme), lineWidth: 0.9)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(Mono.fast, value: configuration.isPressed)
    }
}

struct MonoTag: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    var inverted: Bool = false
    var tint: Color? = nil

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 7.5)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(backgroundColor))
            .overlay(
                Capsule()
                    .strokeBorder(borderColor, lineWidth: 0.75)
            )
    }

    private var foregroundColor: Color {
        if let tint {
            return inverted ? .black : tint
        }
        return inverted ? Mono.primaryInk(scheme) : Mono.ink(scheme).opacity(0.84)
    }

    private var backgroundColor: Color {
        if let tint {
            return inverted ? tint : tint.opacity(scheme == .dark ? 0.16 : 0.14)
        }
        return inverted ? Mono.primaryFill(scheme) : Mono.ink(scheme).opacity(0.10)
    }

    private var borderColor: Color {
        if let tint {
            return inverted ? .clear : tint.opacity(0.28)
        }
        return inverted ? .clear : Mono.hairline(scheme)
    }
}

struct MonoProgressBar: View {
    @Environment(\.colorScheme) private var scheme
    let value: Double // 0...1
    var height: CGFloat = 5
    var tint: Color? = nil

    var body: some View {
        GeometryReader { geo in
            let fillColor = tint ?? Mono.ink(scheme)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Mono.ink(scheme).opacity(scheme == .dark ? 0.12 : 0.11))
                Capsule()
                    .fill(fillColor)
                    .frame(width: max(0, geo.size.width * min(1, max(0, value))))
                    .shadow(color: (tint ?? .clear).opacity(0.45), radius: tint == nil ? 0 : 4)
                    .animation(Mono.betweenSpring, value: value)
            }
        }
        .frame(height: height)
    }
}
