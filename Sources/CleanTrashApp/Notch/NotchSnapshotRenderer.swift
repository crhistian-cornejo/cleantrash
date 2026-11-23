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
            coordinator.isExpanded = true
            for tab in NotchTab.allCases {
                write(NotchRootView(appState: appState, coordinator: coordinator, initialTab: tab), name: "expanded-\(tab.rawValue)", dir: dir)
            }

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
            write(NotchRootView(appState: appState, coordinator: coordinator, initialTab: .unused), name: "expanded-notch-wings", dir: dir)

            coordinator.isExpanded = false
            write(NotchRootView(appState: appState, coordinator: coordinator), name: "closed", dir: dir)
            appState.activeNotice = NotchNotice(kind: .cleaned, title: "Papelera vaciada", subtitle: "271 MB liberados")
            write(NotchRootView(appState: appState, coordinator: coordinator), name: "notice", dir: dir)
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
