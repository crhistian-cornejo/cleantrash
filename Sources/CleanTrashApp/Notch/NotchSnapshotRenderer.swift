#if DEBUG
import AppKit
import CleanTrashCore
import SwiftUI

/// Debug-only: `CLEANTRASH_RENDER_NOTCH=/some/dir CleanTrash` writes a PNG of every expanded notch tab
/// (plus the closed and notice states) and quits. Lets layout be checked without screen recording.
@MainActor
enum NotchSnapshotRenderer {
    static func render(appState: AppState, to dir: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(9)) // let telemetry + initial scans populate
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            let coordinator = NotchCoordinator()
            appState.agents.injectPreview()
            appState.agents.clearPreviewPending()
            appState.media.injectPreview()
            Mono.snapshotMode = true
            coordinator.isExpanded = true
            for tab in NotchTab.allCases {
                coordinator.selectedTab = tab
                write(NotchRootView(appState: appState, coordinator: coordinator), name: "expanded-\(tab.rawValue)", dir: dir)
            }
            coordinator.selectedTab = .home
            coordinator.showLyricsTheater = true
            write(NotchRootView(appState: appState, coordinator: coordinator), name: "expanded-music-lyrics", dir: dir)
            coordinator.showLyricsTheater = false
            coordinator.isEditingWidgets = true
            write(NotchRootView(appState: appState, coordinator: coordinator), name: "expanded-home-edit", dir: dir)
            coordinator.isEditingWidgets = false

            await appState.refreshSimulators()
            for detail in [NotchDetail.cpu, .memory, .gpu, .disk] {
                coordinator.detail = detail
                write(NotchRootView(appState: appState, coordinator: coordinator), name: "detail-\(detail.rawValue)", dir: dir)
            }
            coordinator.detail = nil

            // Simulated MacBook camera housing (wings layout).
            coordinator.geometry = HardwareNotchGeometry(
                screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                hasHardwareNotch: true, cameraWidth: 185, cameraHeight: 32, menuBarHeight: 32
            )
            write(NotchRootView(appState: appState, coordinator: coordinator, initialTab: .home), name: "expanded-notch-wings", dir: dir)

            Mono.snapshotMode = true
            for scheme in [ColorScheme.dark, .light] {
                write(
                    OverviewView(appState: appState).headerHero
                        .frame(width: 900)
                        .padding(20)
                        .background(Mono.canvas(scheme))
                        .environment(\.colorScheme, scheme),
                    name: "overview-hero-\(scheme == .dark ? "dark" : "light")", dir: dir
                )
            }
            write(
                MainDashboardView(appState: appState, onToggleNotch: {})
                    .frame(width: 1120, height: 740)
                    .environment(\.colorScheme, .dark),
                name: "dashboard-overview-dark", dir: dir
            )
            appState.selectedSection = .notchHub
            write(
                MainDashboardView(appState: appState, onToggleNotch: {})
                    .frame(width: 1120, height: 740)
                    .environment(\.colorScheme, .dark),
                name: "dashboard-hub-dark", dir: dir
            )
            appState.selectedSection = .overview

            coordinator.isExpanded = false
            appState.activeNotice = nil
            for _ in 0..<60 where appState.activityLabel != nil { try? await Task.sleep(for: .seconds(1)) }
            write(NotchRootView(appState: appState, coordinator: coordinator), name: "closed", dir: dir)
            appState.agents.previewDone()
            write(NotchRootView(appState: appState, coordinator: coordinator), name: "closed-done", dir: dir)
            appState.activeNotice = NotchNotice(kind: .cleaned, title: "Papelera vaciada", subtitle: "271 MB liberados")
            write(NotchRootView(appState: appState, coordinator: coordinator), name: "notice", dir: dir)
            appState.activeNotice = NotchNotice(kind: .heavyCPU, title: "Simuladores al 744% de CPU", subtitle: "4 iOS encendidos · 9.3 GB", primaryActionTitle: "Apagar")
            write(NotchRootView(appState: appState, coordinator: coordinator), name: "notice-cpu", dir: dir)
            appState.agents.injectPreview()
            write(NotchRootView(appState: appState, coordinator: coordinator), name: "agent-permission", dir: dir)
            coordinator.isExpanded = true
            write(NotchRootView(appState: appState, coordinator: coordinator, initialTab: .home), name: "expanded-agents-pending", dir: dir)
            NSApp.terminate(nil)
        }
    }

    /// Renders clean, AppKit-hosted showcase screenshots (zero ImageRenderer ScrollView/Charts artifacts,
    /// zero personal credentials) for the repository README.
    static func renderShowcase(appState: AppState, to dir: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            let coordinator = NotchCoordinator()
            coordinator.geometry = HardwareNotchGeometry(
                screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                hasHardwareNotch: true, cameraWidth: 185, cameraHeight: 32, menuBarHeight: 32
            )
            appState.settings.notchStyle = .notch
            appState.settings.notchSurface = .obsidian
            appState.settings.sidebarCollapsed = false
            appState.hasFullDiskAccess = true
            appState.productivity.clipboardEnabled = false
            appState.productivity.clearUnpinnedClipboard()
            appState.agents.injectPreview()
            appState.agents.clearPreviewPending()
            appState.media.injectPreview()
            appState.vault.lock() // Guarantee zero real credentials appear in any screenshot
            Mono.snapshotMode = true

            // 1. Dynamic Notch — Home Widgets + Floating Capsule Dock
            coordinator.isExpanded = true
            coordinator.selectedTab = .home
            coordinator.showLyricsTheater = false
            coordinator.detail = nil
            await captureShowcase(
                notchFrame(NotchRootView(appState: appState, coordinator: coordinator), width: 980, height: 340),
                size: CGSize(width: 980, height: 340),
                name: "notch-home",
                dir: dir
            )

            // 2. Dynamic Notch — Side-by-side Karaoke Lyrics Theater
            coordinator.showLyricsTheater = true
            await captureShowcase(
                notchFrame(NotchRootView(appState: appState, coordinator: coordinator), width: 980, height: 380),
                size: CGSize(width: 980, height: 380),
                name: "notch-karaoke",
                dir: dir
            )
            coordinator.showLyricsTheater = false

            // 3. Dynamic Notch — Drop Shelf / Clipboard / Vault / Focus
            coordinator.selectedTab = .shelf
            coordinator.productivitySubTab = .shelf
            await captureShowcase(
                notchFrame(NotchRootView(appState: appState, coordinator: coordinator), width: 980, height: 410),
                size: CGSize(width: 980, height: 410),
                name: "notch-shelf",
                dir: dir
            )

            // 4. Main App — Overview Dashboard
            appState.selectedSection = .overview
            await captureShowcase(
                windowFrame(
                    MainDashboardView(appState: appState, onToggleNotch: {})
                        .frame(width: 1120, height: 700)
                        .environment(\.colorScheme, .dark)
                ),
                size: CGSize(width: 1168, height: 748),
                name: "dashboard-overview",
                dir: dir
            )

            // 5. Main App — Centro Notch Studio
            appState.selectedSection = .notchHub
            await captureShowcase(
                windowFrame(
                    MainDashboardView(appState: appState, onToggleNotch: {})
                        .frame(width: 1120, height: 700)
                        .environment(\.colorScheme, .dark)
                ),
                size: CGSize(width: 1168, height: 748),
                name: "dashboard-studio",
                dir: dir
            )

            // 6. Main App — Touch ID Vault (Locked State — 100% Privacy-Safe)
            appState.selectedSection = .vault
            await captureShowcase(
                windowFrame(
                    MainDashboardView(appState: appState, onToggleNotch: {})
                        .frame(width: 1120, height: 660)
                        .environment(\.colorScheme, .dark)
                ),
                size: CGSize(width: 1168, height: 708),
                name: "dashboard-vault",
                dir: dir
            )

            NSApp.terminate(nil)
        }
    }

    private static func notchFrame<V: View>(_ content: V, width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(hex: 0x0D111A), Color(hex: 0x151B28), Color(hex: 0x0B0E16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color(hex: 0x6366F1).opacity(0.22), .clear],
                center: UnitPoint(x: 0.25, y: 0.15),
                startRadius: 10,
                endRadius: 420
            )
            RadialGradient(
                colors: [Color(hex: 0x38BDF8).opacity(0.16), .clear],
                center: UnitPoint(x: 0.80, y: 0.20),
                startRadius: 10,
                endRadius: 380
            )

            // Subtle simulated macOS menu bar strip across the very top
            HStack {
                HStack(spacing: 14) {
                    Image(systemName: "apple.logo").font(.system(size: 11.5))
                    Text("CleanTrash").font(.system(size: 11, weight: .semibold))
                    Text("Archivo").font(.system(size: 11))
                    Text("Ventana").font(.system(size: 11))
                }
                .foregroundStyle(.white.opacity(0.75))
                Spacer()
                HStack(spacing: 10) {
                    Text("CPU 18% · RAM 62% · GPU 9%")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    Image(systemName: "wifi").font(.system(size: 10.5))
                    Text("22:55").font(.system(size: 11, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 18)
            .frame(height: 30)
            .background(Color.black.opacity(0.22))

            content
                .frame(width: width, height: height, alignment: .top)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private static func windowFrame<V: View>(_ content: V) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x0C0F18), Color(hex: 0x141926)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            content
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 7) {
                        Circle().fill(Color(hex: 0xFF5F56)).frame(width: 11, height: 11)
                        Circle().fill(Color(hex: 0xFFBD2E)).frame(width: 11, height: 11)
                        Circle().fill(Color(hex: 0x27C93F)).frame(width: 11, height: 11)
                    }
                    .padding(.leading, 16)
                    .padding(.top, 14)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
                .padding(24)
        }
    }

    private static func captureShowcase<V: View>(_ view: V, size: CGSize, name: String, dir: String) async {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(350))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            window.orderOut(nil)
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
        window.orderOut(nil)
    }

    private static func write(_ view: some View, name: String, dir: String) {
        let renderer = ImageRenderer(content: view.background(Color(white: 0.93)))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
}
#endif
