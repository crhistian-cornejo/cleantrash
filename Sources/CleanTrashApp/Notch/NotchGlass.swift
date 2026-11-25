import AppKit
import CleanTrashCore
import SwiftUI

private struct NotchSurfaceEnvironmentKey: EnvironmentKey {
    static let defaultValue: NotchSurfaceMode = .glass
}

extension EnvironmentValues {
    var notchSurface: NotchSurfaceMode {
        get { self[NotchSurfaceEnvironmentKey.self] }
        set { self[NotchSurfaceEnvironmentKey.self] = newValue }
    }
}

/// Droppy + Apple HIG macOS 26/27 Liquid Glass surface:
/// - `.glass` (**Dynamic Glass**): Melts from pure `#000000` black around the physical camera housing
///   into native macOS 26/27 `.glassEffect(.regular)` toward the bottom edge.
/// - `.clearGlass` (**Liquid Glass**): Pure native `.glassEffect(.clear)` with subtle top camera blend.
/// - `.obsidian` (**Negro**): Pure jet black `#000000`.
/// Automatically respects Apple's Accessibility **Reduce Transparency** and macOS **Low Power Mode**
/// by switching cleanly to solid high-contrast black.
struct NotchSurfaceBackground: View {
    let shape: NotchShape
    let outlineShape: NotchShape
    let surface: NotchSurfaceMode
    let isExpanded: Bool
    let isIsland: Bool
    let hasToast: Bool
    let hasHardwareNotch: Bool
    var ambientAccent: Color? = nil

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var isElevated: Bool { isExpanded || hasToast || isIsland }
    private var shouldForceSolid: Bool {
        reduceTransparency || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var body: some View {
        ZStack {
            if shouldForceSolid || surface == .obsidian {
                obsidianFill
            } else {
                dynamicGlassFill(clear: surface == .clearGlass)
            }
        }
        .shadow(
            color: .black.opacity(isElevated ? 0.48 : 0.0),
            radius: isExpanded ? 28 : 14,
            y: isExpanded ? 14 : 6
        )
    }

    private var obsidianFill: some View {
        ZStack {
            shape.fill(Color.black)

            if let ambientAccent, isExpanded {
                subtleAmbientWash(ambientAccent, opacity: 0.11)
                    .clipShape(shape)
            }

            outlineShape
                .stroke(Color.white.opacity(isElevated ? 0.13 : 0.05), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func dynamicGlassFill(clear: Bool) -> some View {
        let closedHardware = !isExpanded && !hasToast && !isIsland && hasHardwareNotch

        ZStack {
            if closedHardware {
                shape.fill(Color.black)
                outlineShape
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.75)
                    .allowsHitTesting(false)
            } else if !Mono.snapshotMode, #available(macOS 26.0, *) {
                // Single native Liquid Glass layer (Apple HIG: never stack glass-on-glass or NSVisualEffectView).
                Color.clear
                    .glassEffect(
                        clear
                            ? .clear.tint(Color.black.opacity(0.18))
                            : .regular.tint(Color.black.opacity(0.28)),
                        in: shape
                    )

                // Top bezel camera-housing melt: pure black around the physical lens fading into
                // real refracted Liquid Glass toward the lower edge.
                shape.fill(
                    LinearGradient(
                        stops: clear
                            ? [
                                .init(color: Color.black.opacity(isIsland ? 0.35 : 0.90), location: 0.00),
                                .init(color: Color.black.opacity(isIsland ? 0.25 : 0.62), location: 0.22),
                                .init(color: Color.black.opacity(0.16), location: 0.60),
                                .init(color: Color.black.opacity(0.10), location: 1.00)
                            ]
                            : [
                                .init(color: Color.black.opacity(isIsland ? 0.52 : 0.98), location: 0.00),
                                .init(color: Color.black.opacity(isIsland ? 0.44 : 0.88), location: 0.24),
                                .init(color: Color.black.opacity(0.46), location: 0.64),
                                .init(color: Color.black.opacity(0.26), location: 1.00)
                            ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .allowsHitTesting(false)

                if let ambientAccent, isExpanded {
                    subtleAmbientWash(ambientAccent, opacity: 0.14)
                        .clipShape(shape)
                }

                // Specular rim accent matching macOS 27 dark glass bevels.
                outlineShape
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isIsland ? 0.24 : 0.06),
                                Color.white.opacity(0.12),
                                Color.white.opacity(clear ? 0.28 : 0.20)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            } else {
                shape.fill(
                    LinearGradient(
                        colors: [Color.black, Color(hex: 0x090A0F).opacity(clear ? 0.72 : 0.84)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                outlineShape
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }

    private func subtleAmbientWash(_ accent: Color, opacity: Double) -> some View {
        RadialGradient(
            colors: [accent.opacity(opacity), .clear],
            center: .topLeading,
            startRadius: 8,
            endRadius: 260
        )
        .allowsHitTesting(false)
    }
}

/// Official Apple HIG `GlassEffectContainer` wrapper so the floating capsule dock and `[×]` circle
/// share one unified macOS 26/27 Liquid Glass sampling group.
struct NotchGlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if !Mono.snapshotMode, #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

/// Native macOS 27 interactive Liquid Glass capsule / circle modifier for the detached floating dock.
struct FloatingDockGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let surface: NotchSurfaceMode
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let allowGlass = surface.isGlass && !reduceTransparency && !ProcessInfo.processInfo.isLowPowerModeEnabled
        if allowGlass, !Mono.snapshotMode, #available(macOS 26.0, *) {
            content
                .glassEffect(
                    (surface == .clearGlass
                        ? Glass.clear.tint(Color.black.opacity(0.42))
                        : Glass.regular.tint(Color.black.opacity(0.66))
                    ).interactive(),
                    in: shape
                )
                .overlay(
                    shape.stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                )
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        } else {
            content
                .background(shape.fill(Color.black.opacity(0.95)))
                .overlay(shape.stroke(Color.white.opacity(0.15), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
        }
    }
}

extension View {
    func floatingDockGlass<S: Shape>(in shape: S, surface: NotchSurfaceMode) -> some View {
        modifier(FloatingDockGlassModifier(shape: shape, surface: surface))
    }
}
