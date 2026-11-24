import AppKit
import CleanTrashCore
import Observation
import SwiftUI

struct HardwareNotchGeometry: Equatable {
    let screenFrame: CGRect
    let hasHardwareNotch: Bool
    let cameraWidth: CGFloat
    let cameraHeight: CGFloat
    let menuBarHeight: CGFloat

    static func detect() -> HardwareNotchGeometry {
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else {
            return HardwareNotchGeometry(
                screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                hasHardwareNotch: false,
                cameraWidth: 184,
                cameraHeight: 32,
                menuBarHeight: 28
            )
        }

        let frame = screen.frame
        let visible = screen.visibleFrame
        let safeTop = screen.safeAreaInsets.top
        let menuBar = max(0, (frame.maxY) - (visible.maxY))

        if safeTop > 0,
           let leftRect = screen.auxiliaryTopLeftArea,
           let rightRect = screen.auxiliaryTopRightArea {
            let notchWidth = max(140, frame.width - leftRect.width - rightRect.width)
            let notchHeight = menuBar > 0 ? min(safeTop, menuBar) : safeTop
            return HardwareNotchGeometry(
                screenFrame: frame,
                hasHardwareNotch: true,
                cameraWidth: notchWidth,
                cameraHeight: notchHeight,
                menuBarHeight: menuBar
            )
        }

        return HardwareNotchGeometry(
            screenFrame: frame,
            hasHardwareNotch: false,
            cameraWidth: 188,
            cameraHeight: 28,
            menuBarHeight: max(24, menuBar)
        )
    }
}

@MainActor
@Observable
final class NotchCoordinator {
    var isExpanded = false {
        didSet { if !isExpanded { detail = nil } }
    }
    /// Drill-down shown instead of the tabs (tap a tile on Estado).
    var detail: NotchDetail?
    var isHovering = false
    var geometry = HardwareNotchGeometry.detect()

    // Window stays at a fixed generous stage rect above the notch so SwiftUI spring animations
    // never fight AppKit frame resizing (same architectural principle as monoBOT's notch/mod.rs!).
    let stageWidth: CGFloat = 580
    let stageHeight: CGFloat = 460

    var closedWidth: CGFloat {
        geometry.hasHardwareNotch ? geometry.cameraWidth : 176
    }

    var closedHeight: CGFloat {
        geometry.hasHardwareNotch ? geometry.cameraHeight : 28
    }

    var isIsland = false
    static let noticeWidth: CGFloat = 440
    /// Open shelf width (content area is this minus 2 × `NotchRootView.sideInset`).
    static let expandedWidth: CGFloat = 520
    static let permissionWidth: CGFloat = 470
    /// Each live ear beside the camera (metrics on the left, agents on the right).
    static let earWidth: CGFloat = 158

    func activeHitRect(in stageSize: CGSize, hasNotice: Bool, hasPermission: Bool = false, showEars: Bool) -> CGRect {
        let width: CGFloat
        let height: CGFloat
        if isExpanded {
            width = Self.expandedWidth + 4
            let header = geometry.hasHardwareNotch && !isIsland ? max(closedHeight, 28) : 40
            height = NotchRootView.expandedHeight(headerHeight: header, isIsland: isIsland, showsStatus: detail == nil)
                + (detail?.extraHeight ?? 0) + 6
        } else if hasPermission {
            width = Self.permissionWidth + 4
            height = closedHeight + 142
        } else if hasNotice {
            width = Self.noticeWidth + 4
            height = closedHeight + 62
        } else if showEars {
            width = closedWidth + 2 * Self.earWidth + 4
            height = closedHeight + 4
        } else {
            width = closedWidth + 24
            height = closedHeight + 8
        }
        let x = (stageSize.width - width) / 2
        return CGRect(x: x, y: 0, width: width, height: height)
    }
}

/// Borderless NSPanel hovering seamlessly over the MacBook camera housing (or top center edge).
@MainActor
final class NotchWindowController {
    private let panel: NSPanel
    private let appState: AppState
    let coordinator = NotchCoordinator()

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var openDelayTask: Task<Void, Never>?
    private var closeDelayTask: Task<Void, Never>?

    init(appState: AppState) {
        self.appState = appState

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: coordinator.stageWidth, height: coordinator.stageHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isRestorable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        // Above the menu bar and its menus (NSMainMenuWindowLevel + 3), identical to monoBOT.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]

        let rootView = NotchRootView(appState: appState, coordinator: coordinator)
        let hosting = NSHostingView(rootView: rootView)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        self.panel = panel

        repositionPanel()
        installMonitors()

        if appState.settings.notchEnabled {
            panel.orderFrontRegardless()
        }
    }

    func applySettings(_ settings: CleanTrashSettings) {
        if settings.notchEnabled {
            repositionPanel()
            panel.orderFrontRegardless()
        } else {
            coordinator.isExpanded = false
            panel.orderOut(nil)
        }
    }

    func toggleExpanded() {
        withAnimation(coordinator.isExpanded ? Mono.foldingSpring : Mono.openingSpring) {
            coordinator.isExpanded.toggle()
        }
        panel.ignoresMouseEvents = !coordinator.isExpanded
    }

    func closeExpanded() {
        guard coordinator.isExpanded else { return }
        withAnimation(Mono.foldingSpring) {
            coordinator.isExpanded = false
        }
        panel.ignoresMouseEvents = true
    }

    private func repositionPanel() {
        let geo = HardwareNotchGeometry.detect()
        coordinator.geometry = geo
        coordinator.isIsland = appState.settings.notchStyle == .island
        let topOffset: CGFloat = appState.settings.notchStyle == .island ? (geo.menuBarHeight + 6) : 0
        let x = geo.screenFrame.midX - coordinator.stageWidth / 2
        let y = geo.screenFrame.maxY - coordinator.stageHeight - topOffset
        panel.setFrame(
            NSRect(x: x, y: y, width: coordinator.stageWidth, height: coordinator.stageHeight),
            display: true
        )
    }

    private func installMonitors() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repositionPanel()
            }
        }

        // Global mouse movement + click tracking so hovering over the hardware notch
        // wakes it even when another app (Terminal, Xcode, Zed, Cursor) is focused.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handlePointerEvent(isClick: event.type == .leftMouseDown)
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handlePointerEvent(isClick: event.type == .leftMouseDown)
            }
            return event
        }
    }

    private func handlePointerEvent(isClick: Bool) {
        guard appState.settings.notchEnabled else { return }

        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        let stageSize = frame.size

        // Convert AppKit bottom-left screen coordinate into top-left stage coordinate
        let localX = mouse.x - frame.minX
        let localY = frame.maxY - mouse.y
        let localPoint = CGPoint(x: localX, y: localY)

        let hitRect = coordinator.activeHitRect(
            in: stageSize,
            hasNotice: appState.activeNotice != nil,
            hasPermission: !appState.agents.pending.isEmpty,
            showEars: appState.settings.showLiveNotchEars
        )
        let inside = hitRect.insetBy(dx: -8, dy: -6).contains(localPoint)

        // Toggle click-through dynamically so windows underneath remain clickable everywhere outside the pill.
        let shouldAcceptMouse = inside
        if panel.ignoresMouseEvents == shouldAcceptMouse {
            panel.ignoresMouseEvents = !shouldAcceptMouse
        }

        // A card with buttons (permission request, notice with an action) must stay put under the cursor:
        // hovering it never auto-expands, and only a click on the camera strip opens the shelf.
        let hasActionableToast = !coordinator.isExpanded
            && (!appState.agents.pending.isEmpty || appState.activeNotice?.primaryActionTitle != nil)

        if isClick {
            if !inside && coordinator.isExpanded {
                closeExpanded()
            } else if inside && !coordinator.isExpanded
                        && (hasActionableToast ? localY <= coordinator.closedHeight + 2 : appState.settings.notchTrigger == .click) {
                openDelayTask?.cancel()
                closeDelayTask?.cancel()
                withAnimation(Mono.openingSpring) {
                    coordinator.isExpanded = true
                }
            }
            return
        }

        coordinator.isHovering = inside

        guard appState.settings.notchTrigger == .hover else { return }

        if inside {
            closeDelayTask?.cancel()
            if !coordinator.isExpanded && !hasActionableToast {
                openDelayTask?.cancel()
                openDelayTask = Task { @MainActor [weak self] in
                    // 90ms hover dwell (identical to monoBOT's OPEN_DELAY)
                    try? await Task.sleep(for: .milliseconds(90))
                    guard !Task.isCancelled, let self, self.coordinator.isHovering else { return }
                    withAnimation(Mono.openingSpring) {
                        self.coordinator.isExpanded = true
                    }
                    self.panel.ignoresMouseEvents = false
                }
            }
        } else {
            openDelayTask?.cancel()
            if coordinator.isExpanded {
                closeDelayTask?.cancel()
                closeDelayTask = Task { @MainActor [weak self] in
                    // 260ms exit grace (identical to monoBOT's CLOSE_DELAY)
                    try? await Task.sleep(for: .milliseconds(260))
                    guard !Task.isCancelled, let self, !self.coordinator.isHovering else { return }
                    withAnimation(Mono.foldingSpring) {
                        self.coordinator.isExpanded = false
                    }
                    self.panel.ignoresMouseEvents = self.appState.activeNotice == nil && self.appState.agents.pending.isEmpty
                }
            }
        }
    }

    isolated deinit {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m) }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m) }
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
    }
}
