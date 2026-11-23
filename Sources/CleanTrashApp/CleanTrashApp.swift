import AppKit
import CleanTrashCore
import SwiftUI

@main
struct CleanTrashApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView(appState: delegate.appState)
                .frame(width: 560, height: 520)
                .preferredColorScheme(delegate.appState.preferredColorScheme)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var notchController: NotchWindowController?
    private var menuBarController: MenuBarController?
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["CLEANTRASH_RENDER_NOTCH"] {
            NotchSnapshotRenderer.render(appState: appState, to: dir)
            return
        }
        #endif
        // Show in Dock & Switcher when dashboard is open, keep Notch + Menu Bar alive even when closed.
        NSApp.setActivationPolicy(.regular)

        let notch = NotchWindowController(appState: appState)
        self.notchController = notch

        appState.onSettingsChanged = { [weak notch] settings in
            notch?.applySettings(settings)
        }

        appState.onOpenMainWindow = { [weak self] in
            self?.showMainWindow()
        }

        self.menuBarController = MenuBarController(
            appState: appState,
            onOpenDashboard: { [weak self] in
                self?.showMainWindow()
            },
            onToggleNotch: { [weak notch] in
                notch?.toggleExpanded()
            }
        )

        showMainWindow()
        installAppMenuShortcuts()
    }

    private func installAppMenuShortcuts() {
        guard let mainMenu = NSApp.mainMenu else { return }

        let actionsMenu = NSMenu(title: "Acciones")

        let toggleSidebar = NSMenuItem(title: "Colapsar barra lateral", action: #selector(toggleSidebarShortcut), keyEquivalent: "\\")
        toggleSidebar.target = self
        actionsMenu.addItem(toggleSidebar)

        let toggleNotch = NSMenuItem(title: "Mostrar / Ocultar Notch", action: #selector(toggleNotchShortcut), keyEquivalent: "n")
        toggleNotch.target = self
        actionsMenu.addItem(toggleNotch)

        actionsMenu.addItem(.separator())

        let smartScan = NSMenuItem(title: "Analizar Mac", action: #selector(smartScanShortcut), keyEquivalent: "k")
        smartScan.keyEquivalentModifierMask = [.command, .shift]
        smartScan.target = self
        actionsMenu.addItem(smartScan)

        let optimizeRAM = NSMenuItem(title: "Optimizar RAM", action: #selector(optimizeRAMShortcut), keyEquivalent: "r")
        optimizeRAM.target = self
        actionsMenu.addItem(optimizeRAM)

        let emptyTrash = NSMenuItem(title: "Vaciar Papelera", action: #selector(emptyTrashShortcut), keyEquivalent: "\u{08}") // ⌘⌫
        emptyTrash.keyEquivalentModifierMask = [.command, .shift]
        emptyTrash.target = self
        actionsMenu.addItem(emptyTrash)

        let actionsMenuItem = NSMenuItem(title: "Acciones", action: nil, keyEquivalent: "")
        actionsMenuItem.submenu = actionsMenu
        mainMenu.addItem(actionsMenuItem)
    }

    @objc private func toggleSidebarShortcut() {
        withAnimation(Mono.betweenSpring) {
            appState.settings.sidebarCollapsed.toggle()
        }
        AppKitHaptics.tap()
    }

    @objc private func toggleNotchShortcut() {
        notchController?.toggleExpanded()
        AppKitHaptics.tap()
    }

    @objc private func smartScanShortcut() {
        Task { await appState.runSmartScan() }
    }

    @objc private func optimizeRAMShortcut() {
        Task { await appState.optimizeRAM() }
    }

    @objc private func emptyTrashShortcut() {
        Task { await appState.emptyTrashNow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in the Notch & Menu Bar when user closes the dashboard window.
        false
    }

    func showMainWindow() {
        if let existing = mainWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = MainDashboardView(
            appState: appState,
            onToggleNotch: { [weak self] in
                self?.notchController?.toggleExpanded()
            }
        )
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = "CleanTrash"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.tabbingMode = .disallowed
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 1120, height: 740))
        window.minSize = NSSize(width: 820, height: 580)
        window.isReleasedWhenClosed = false
        window.center()
        window.isOpaque = false
        window.backgroundColor = NSColor(calibratedWhite: 0.025, alpha: 0.98)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.mainWindow = window
    }
}
