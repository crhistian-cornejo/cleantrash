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
    private var mascotController: AgentMascotWindowController?
    private var menuBarController: MenuBarController?
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["CLEANTRASH_RENDER_SHOWCASE"] {
            NotchSnapshotRenderer.renderShowcase(appState: appState, to: dir)
            return
        }
        if let dir = ProcessInfo.processInfo.environment["CLEANTRASH_RENDER_NOTCH"] {
            NotchSnapshotRenderer.render(appState: appState, to: dir)
            return
        }
        #endif
        // Show in Dock & Switcher when dashboard is open, keep Notch + Menu Bar alive even when closed.
        NSApp.setActivationPolicy(.regular)

        let notch = NotchWindowController(appState: appState)
        self.notchController = notch

        let mascot = AgentMascotWindowController()
        self.mascotController = mascot
        if appState.settings.agentMascotEnabled {
            mascot.show(appState: appState)
        }

        appState.agents.canPrompt = { [weak appState] in appState?.settings.notchEnabled ?? false }
        appState.agents.start()
        appState.hud.isEnabled = appState.settings.notchEnabled && appState.settings.systemHUDInNotch
        appState.hud.start()

        appState.onSettingsChanged = { [weak self, weak notch, weak mascot] settings in
            notch?.applySettings(settings)
            self?.menuBarController?.updateTitle()
            if let appState = self?.appState {
                mascot?.setVisible(settings.agentMascotEnabled, appState: appState)
            }
        }

        appState.onOpenMainWindow = { [weak self] in
            self?.showMainWindow()
        }
        appState.onOpenNotchVault = { [weak self] in
            self?.openNotchVaultShortcut()
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

        if !ProcessInfo.processInfo.arguments.contains("--background") {
            showMainWindow()
        }
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

        let quickTranslate = NSMenuItem(title: "Traductor rápido (En este Mac)", action: #selector(toggleQuickTranslateShortcut), keyEquivalent: "t")
        quickTranslate.keyEquivalentModifierMask = [.option, .shift]
        quickTranslate.target = self
        actionsMenu.addItem(quickTranslate)

        let toggleMascot = NSMenuItem(title: "Mascota de Agentes IA", action: #selector(toggleMascotShortcut), keyEquivalent: "m")
        toggleMascot.keyEquivalentModifierMask = [.option, .shift]
        toggleMascot.target = self
        actionsMenu.addItem(toggleMascot)

        let vaultQuickFill = NSMenuItem(title: "Bóveda en el Notch (Autocompletar)", action: #selector(openNotchVaultShortcut), keyEquivalent: "p")
        vaultQuickFill.keyEquivalentModifierMask = [.option, .shift]
        vaultQuickFill.target = self
        actionsMenu.addItem(vaultQuickFill)

        let standByMode = NSMenuItem(title: "Modo StandBy / Spotify Pantalla Completa", action: #selector(toggleStandByShortcut), keyEquivalent: "l")
        standByMode.keyEquivalentModifierMask = [.option, .shift]
        standByMode.target = self
        actionsMenu.addItem(standByMode)

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

    @objc private func toggleQuickTranslateShortcut() {
        appState.productivity.quickTranslate.toggle(surface: appState.settings.notchSurface)
        AppKitHaptics.tap()
    }

    @objc private func toggleMascotShortcut() {
        appState.settings.agentMascotEnabled.toggle()
        AppKitHaptics.tap()
    }

    @objc private func toggleStandByShortcut() {
        appState.productivity.standBy.toggle(appState: appState)
        AppKitHaptics.tap()
    }

    @objc private func openNotchVaultShortcut() {
        appState.vault.refreshFrontmostContext()
        if let notch = notchController {
            withAnimation(Mono.openingSpring) {
                notch.coordinator.detail = nil
                notch.coordinator.selectedTab = .shelf
                notch.coordinator.productivitySubTab = .vault
                notch.coordinator.isExpanded = true
            }
        }
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

    func applicationWillTerminate(_ notification: Notification) {
        // Waiting hooks get "ask" so the agents fall back to their own prompt.
        appState.agents.stop()
        appState.media.stop()
        appState.productivity.stop()
        appState.vault.lock()
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
        window.backgroundColor = .clear
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.mainWindow = window
    }
}
