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
        didSet {
            if !isExpanded {
                detail = nil
                showLyricsTheater = false
                isEditingWidgets = false
            }
        }
    }
    var selectedTab: NotchTab = .home {
        didSet {
            if selectedTab != .home {
                showLyricsTheater = false
                isEditingWidgets = false
            }
        }
    }
    var productivitySubTab: ProductivitySubTab = .shelf
    /// When true on Home, expands into the full-bleed synced karaoke lyrics theater.
    var showLyricsTheater = false
    /// Droppy Home widget customization drawer (add/remove/drag-reorder widgets).
    var isEditingWidgets = false
    /// Drill-down shown instead of the tabs (tap CPU/RAM/GPU/Disk).
    var detail: NotchDetail?
    var isHovering = false
    var geometry = HardwareNotchGeometry.detect()

    // Window stays at a fixed generous stage rect above the notch so SwiftUI spring animations
    // never fight AppKit frame resizing (supports wide multi-widget Home bar & full drill-downs!).
    let stageWidth: CGFloat = 900
    let stageHeight: CGFloat = 620

    var closedWidth: CGFloat {
        geometry.hasHardwareNotch ? geometry.cameraWidth : 176
    }

    var closedHeight: CGFloat {
        geometry.hasHardwareNotch ? geometry.cameraHeight : 28
    }

    var isIsland = false
    static let noticeWidth: CGFloat = 450
    static let defaultExpandedWidth: CGFloat = 564
    static let permissionWidth: CGFloat = 480
    /// Each live ear beside the camera (+5 pt breathing room on both outer edges).
    static let earWidth: CGFloat = 158
    /// Detached Droppy floating capsule dock below the expanded notch (10 pt gap + 42 pt pill).
    static let floatingDockReserve: CGFloat = 54

    func expandedWidth(for homeWidgets: [NotchWidgetID]) -> CGFloat {
        if showLyricsTheater {
            return min(780, max(640, geometry.screenFrame.width - 100))
        }
        if detail != nil || selectedTab != .home {
            return Self.defaultExpandedWidth
        }
        let active = homeWidgets.isEmpty ? NotchWidgetID.defaultLayout : homeWidgets
        let sum = active.reduce(CGFloat(0)) { $0 + $1.preferredWidth }
        let dividers = CGFloat(max(0, active.count - 1)) * 22
        let raw = sum + dividers + NotchRootView.sideInset * 2
        let maxAllowed = min(840, max(560, geometry.screenFrame.width - 100))
        return min(maxAllowed, max(540, raw))
    }

    var extraExpandedHeight: CGFloat {
        if let detail { return detail.extraHeight }
        if showLyricsTheater { return 112 }
        if selectedTab == .home && isEditingWidgets { return 70 }
        return 0
    }

    func activeHitRect(
        in stageSize: CGSize,
        hasNotice: Bool,
        hasPermission: Bool = false,
        showEars: Bool,
        homeWidgets: [NotchWidgetID] = NotchWidgetID.defaultLayout
    ) -> CGRect {
        let width: CGFloat
        let height: CGFloat
        if isExpanded {
            width = expandedWidth(for: homeWidgets) + 8
            let header = geometry.hasHardwareNotch && !isIsland ? max(closedHeight, 28) : 34
            height = NotchRootView.expandedHeight(
                headerHeight: header,
                isIsland: isIsland,
                bodyHeight: detail == nil ? selectedTab.bodyHeight : 230
            ) + extraExpandedHeight + Self.floatingDockReserve + 8
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
        // Above the menu bar and its menus (NSMainMenuWindowLevel + 3).
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

        // Global mouse movement, drag, and click tracking so hovering or dragging files to the
        // notch wakes it even when another app (Finder, Spotify, Terminal, T3 Code) is focused.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handlePointerEvent(type: event.type)
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask.union(.keyDown)) { [weak self] event in
            if event.type == .keyDown && event.keyCode == 53 {
                Task { @MainActor [weak self] in
                    self?.closeExpanded()
                }
                return event
            }
            Task { @MainActor [weak self] in
                self?.handlePointerEvent(type: event.type)
            }
            return event
        }
    }

    private func handlePointerEvent(type: NSEvent.EventType) {
        guard appState.settings.notchEnabled else { return }

        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        let stageSize = frame.size

        // Convert AppKit bottom-left screen coordinate into top-left stage coordinate
        let localX = mouse.x - frame.minX
        let localY = frame.maxY - mouse.y
        let localPoint = CGPoint(x: localX, y: localY)

        // Droppy-style drag-to-notch auto-open: dragging files toward the top center wakes the File Shelf.
        if type == .leftMouseDragged && appState.settings.autoOpenShelfOnDrag {
            let topDropZone = CGRect(x: 30, y: -12, width: stageSize.width - 60, height: max(96, coordinator.closedHeight + 70))
            if topDropZone.contains(localPoint), Self.dragPasteboardHasFiles() {
                openDelayTask?.cancel()
                closeDelayTask?.cancel()
                appState.productivity.isDragOverNotch = true
                if !coordinator.isExpanded || coordinator.selectedTab != .shelf {
                    withAnimation(Mono.openingSpring) {
                        coordinator.selectedTab = .shelf
                        coordinator.productivitySubTab = .shelf
                        coordinator.detail = nil
                        coordinator.isExpanded = true
                    }
                }
                panel.ignoresMouseEvents = false
                return
            }
        } else if type == .leftMouseUp {
            if appState.productivity.isDragOverNotch {
                appState.productivity.isDragOverNotch = false
            }
        }

        let hasLiveEars = appState.settings.showLiveNotchEars && (
            appState.activityLabel != nil
                || !appState.agents.earStack.isEmpty
                || (appState.settings.showMusicInNotchEars && appState.media.hasActiveTrack)
                || appState.productivity.isTimerRunning
        )
        let hitRect = coordinator.activeHitRect(
            in: stageSize,
            hasNotice: appState.activeNotice != nil,
            hasPermission: !appState.agents.pending.isEmpty,
            showEars: hasLiveEars,
            homeWidgets: appState.settings.homeWidgets
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

        if type == .leftMouseDown {
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

        guard type == .mouseMoved else { return }

        coordinator.isHovering = inside

        guard appState.settings.notchTrigger == .hover else { return }

        if inside {
            closeDelayTask?.cancel()
            if !coordinator.isExpanded && !hasActionableToast {
                openDelayTask?.cancel()
                openDelayTask = Task { @MainActor [weak self] in
                    // 90ms hover dwell
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
                    // 260ms exit grace
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

    private static func dragPasteboardHasFiles() -> Bool {
        let pb = NSPasteboard(name: .drag)
        guard let types = pb.types else { return false }
        return types.contains(.fileURL) || types.contains(NSPasteboard.PasteboardType("NSFilenamesPboardType"))
    }

    isolated deinit {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m) }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m) }
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
    }
}
