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
