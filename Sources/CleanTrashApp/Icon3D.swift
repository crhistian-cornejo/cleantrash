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
    case mac, memory, cpu, gpu, disk, dev, trash, apps, smartcare, diskmap, performance, settings

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

/// A 3D glass icon with a soft contact shadow (lighter on light surfaces).
struct Icon3D: View {
    let name: Icon3DName
    var size: CGFloat = 32
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let image = Icon3DStore.image(name) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fit)
            } else {
                // Glass-chip stand-in that matches the rendered set's frosted white look.
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.96), Color(white: 0.72)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(
                            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                                .strokeBorder(LinearGradient(colors: [.white, Color(white: 0.6)], startPoint: .top, endPoint: .bottom), lineWidth: max(1, size * 0.03))
                        )
                        .padding(size * 0.1)
                    Image(systemName: name.fallbackSymbol)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: [Color(white: 0.45), Color(white: 0.25)], startPoint: .top, endPoint: .bottom))
                        .shadow(color: .white.opacity(0.8), radius: 0, y: max(0.5, size * 0.015))
                }
            }
        }
        .frame(width: size, height: size)
        // White glass disappears on light surfaces: drop it to brushed silver there.
        .brightness(scheme == .light ? -0.2 : 0)
        .contrast(scheme == .light ? 1.15 : 1)
        .shadow(
            color: .black.opacity(scheme == .light ? 0.1 : 0.4),
            radius: size * (scheme == .light ? 0.04 : 0.08),
            y: size * (scheme == .light ? 0.025 : 0.06)
        )
        .accessibilityHidden(true)
    }
}
