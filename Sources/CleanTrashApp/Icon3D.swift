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

    /// Closest rendered icon to use while this one hasn't been generated yet.
    var standIn: Icon3DName? {
        switch self {
        case .smartcare: return .mac
        case .diskmap: return .disk
        case .performance: return .gpu
        default: return nil
        }
    }

    /// SF Symbol used if neither the PNG nor a stand-in exists (e.g. a dev build without assets).
    var fallbackSymbol: String {
        switch self {
        case .mac: return "laptopcomputer"
        case .memory: return "memorychip"
        case .cpu: return "cpu"
        case .gpu: return "sparkles"
        case .disk: return "internaldrive"
        case .dev: return "terminal"
        case .trash: return "trash"
        case .apps: return "square.grid.2x2"
        case .smartcare: return "sparkle"
        case .diskmap: return "chart.pie"
        case .performance: return "bolt"
        case .settings: return "gearshape"
        case .notch: return "rectangle.topthird.inset.filled"
        case .vault: return "lock.shield.fill"
        }
    }
}

@MainActor
enum Icon3DStore {
    private static var cache: [Icon3DName: NSImage] = [:]
    private static var missing: Set<Icon3DName> = []

    static func image(_ name: Icon3DName) -> NSImage? {
        if let hit = cache[name] { return hit }
        if missing.contains(name) { return nil }
        for dir in searchDirectories {
            let url = dir.appendingPathComponent("\(name.rawValue).png")
            if let image = NSImage(contentsOf: url) {
                cache[name] = image
                return image
            }
        }
        missing.insert(name)
        if let alt = name.standIn, let image = image(alt) {
            cache[name] = image
            return image
        }
        return nil
    }

    private static let searchDirectories: [URL] = {
        var dirs: [URL] = []
        if let res = Bundle.main.resourceURL {
            dirs.append(res.appendingPathComponent("Icons3D"))
        }
        // `swift run` / debug renders: read straight from the repo's assets folder.
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CleanTrashApp
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo root
        dirs.append(repo.appendingPathComponent("assets/icons3d"))
        return dirs
    }()
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
