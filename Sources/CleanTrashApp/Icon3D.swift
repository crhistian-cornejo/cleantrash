import AppKit
import SwiftUI

/// Overall verdict shown as "Estado del Mac: …" in the notch and the dashboard.
struct MacHealth: Equatable {
    enum Level: Int, Comparable {
        case good, attention, critical
        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Area { case memory, cpu, disk }

    var level: Level
    var reason: String?
    var area: Area?
    var issueCount: Int

    var label: String {
        switch level {
        case .good: return "Correcto"
        case .attention: return "Atención"
        case .critical: return "Crítico"
        }
    }

    /// Light surfaces need a deeper teal to stay legible.
    func tint(for scheme: ColorScheme) -> Color {
        scheme == .light && level == .good ? Color(hex: 0x0E9384) : tint
    }

    var tint: Color {
        switch level {
        case .good: return Color(hex: 0x7FE7D8)
        case .attention: return Mono.caution
        case .critical: return Mono.danger
        }
    }
}

/// Pre-rendered 3D glass icons (generated with Nano Banana, keyed to transparency by
/// `scripts/process-icons.swift`). Shipped in `Contents/Resources/Icons3D`.
enum Icon3DName: String, CaseIterable {
    case mac, memory, cpu, gpu, disk, dev, trash, apps, smartcare, diskmap, performance, settings, notch, vault

}

/// Interactive Layered Frosted Glass icon (adapted from the Glass Dock motion system).
/// Each icon renders solid vibrant colored geometry behind a translucent frosted glass pane
/// with bespoke spring micro-interactions on hover or active state.
struct Icon3D: View {
    let name: Icon3DName
    var size: CGFloat = 32
    var isActive: Bool = false
    var externalHover: Bool = false
    var interactive: Bool = true
    var tiltX: Double = 0

    var body: some View {
        GlassLayeredIcon(
            name: name,
            size: size,
            isActive: isActive,
            externalHover: externalHover,
            interactive: interactive,
            tiltX: tiltX
        )
    }
}
