import AppKit
import CleanTrashCore
import Foundation

/// Monochrome macOS menu bar status item displaying live RAM & GPU telemetry
/// with quick access to the Dynamic Notch, RAM/GPU optimization, and main dashboard.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let appState: AppState
    private let onOpenDashboard: () -> Void
    private let onToggleNotch: () -> Void
    private var refreshTimer: Timer?

    init(
        appState: AppState,
        onOpenDashboard: @escaping () -> Void,
        onToggleNotch: @escaping () -> Void
    ) {
        self.appState = appState
        self.onOpenDashboard = onOpenDashboard
        self.onToggleNotch = onToggleNotch
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        configureButton()
        rebuildMenu()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateTitle()
            }
        }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        if let symbol = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "CleanTrash") {
            symbol.isTemplate = true
            button.image = symbol
            button.imagePosition = .imageOnly
        }
        updateTitle()
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let ram = Int(appState.telemetry.memory.usedPercent)
        let gpu = Int(appState.telemetry.gpu.deviceUtilizationPercent)
        // Icon only: the live numbers already live in the notch, so they go in the tooltip here.
        button.title = ""
        button.toolTip = "CleanTrash · RAM \(ram)% · GPU \(gpu)%"
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func openDashboardAction() {
        onOpenDashboard()
    }

    @objc private func toggleNotchAction() {
        onToggleNotch()
    }

    @objc private func optimizeRAMAction() {
        Task { await appState.optimizeRAM() }
    }

    @objc private func trimGPUAction() {
        Task { await appState.trimGPUCaches() }
    }

    @objc private func emptyTrashAction() {
        let alert = NSAlert()
        alert.messageText = "¿Vaciar la Papelera?"
        alert.informativeText = "Los elementos se borrarán definitivamente. No se puede deshacer."
        alert.addButton(withTitle: "Vaciar Papelera")
        alert.addButton(withTitle: "Cancelar")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await appState.emptyTrashNow() }
    }

    @objc private func smartScanAction() {
        Task { await appState.runSmartScan() }
    }

    @objc private func openUnusedAppsAction() {
        appState.selectedSection = .appsAudit
        onOpenDashboard()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }
}

extension MenuBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let t = appState.telemetry
        let header = NSMenuItem(
            title: "CleanTrash · RAM \(Int(t.memory.usedPercent))% · GPU \(Int(t.gpu.deviceUtilizationPercent))% · CPU \(Int(t.cpuTotalPercent))%",
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)

        let diskInfo = NSMenuItem(
            title: "\(t.disk.volumeName): \(ByteFormat.compact(t.disk.availableBytes)) libres · \(ByteFormat.compact(appState.totalSmartReclaimableBytes)) recuperables",
            action: nil,
            keyEquivalent: ""
        )
        diskInfo.isEnabled = false
        menu.addItem(diskInfo)

        if !t.externalVolumes.isEmpty {
            for vol in t.externalVolumes {
                let volItem = NSMenuItem(
                    title: "Disco \(vol.name): \(ByteFormat.compact(vol.availableBytes)) libres",
                    action: nil,
                    keyEquivalent: ""
                )
                volItem.isEnabled = false
                menu.addItem(volItem)
            }
        }

        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Abrir panel", action: #selector(openDashboardAction), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let notchItem = NSMenuItem(title: "Mostrar/ocultar Notch", action: #selector(toggleNotchAction), keyEquivalent: "n")
        notchItem.target = self
        menu.addItem(notchItem)

        if !appState.unusedApps.isEmpty {
            let unusedItem = NSMenuItem(
                title: "Revisar apps sin usar (\(appState.unusedApps.count))",
                action: #selector(openUnusedAppsAction),
                keyEquivalent: "u"
            )
            unusedItem.target = self
            menu.addItem(unusedItem)
        }

        menu.addItem(.separator())

        let ramItem = NSMenuItem(title: "Optimizar RAM ahora", action: #selector(optimizeRAMAction), keyEquivalent: "r")
        ramItem.target = self
        menu.addItem(ramItem)

        let gpuItem = NSMenuItem(title: "Limpiar cachés de GPU", action: #selector(trimGPUAction), keyEquivalent: "g")
        gpuItem.target = self
        menu.addItem(gpuItem)

        let trashTitle = appState.trashContents.itemCount > 0
            ? "Vaciar Papelera (\(ByteFormat.compact(appState.trashContents.totalBytes)))…"
            : "Vaciar Papelera…"
        let trashItem = NSMenuItem(title: trashTitle, action: #selector(emptyTrashAction), keyEquivalent: "")
        trashItem.target = self
        trashItem.isEnabled = !appState.isCleaning
        menu.addItem(trashItem)

        let scanItem = NSMenuItem(title: "Analizar Mac", action: #selector(smartScanAction), keyEquivalent: "s")
        scanItem.target = self
        menu.addItem(scanItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Salir de CleanTrash", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
}
