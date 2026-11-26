import AppKit
import CleanTrashCore
import SwiftUI

/// Menu bar item: one template icon plus (optionally) a single live value. Left click opens a
/// popover with Salud · Agentes · Música; right click shows the classic menu.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let appState: AppState
    private let onOpenDashboard: () -> Void
    private let onToggleNotch: () -> Void
    private var refreshTimer: Timer?
    private let popover = NSPopover()

    init(
        appState: AppState,
        onOpenDashboard: @escaping () -> Void,
        onToggleNotch: @escaping () -> Void
    ) {
        self.appState = appState
        self.onOpenDashboard = onOpenDashboard
        self.onToggleNotch = onToggleNotch
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        configurePopover()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard !SystemActivity.isIdle else { return }
                self?.updateTitle()
            }
        }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        if let symbol = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "CleanTrash") {
            symbol.isTemplate = true
            button.image = symbol
            button.imagePosition = .imageLeading
        }
        button.target = self
        button.action = #selector(buttonClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateTitle()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: MenuBarPopoverView(
            appState: appState,
            onOpenDashboard: { [weak self] in self?.closePopover(); self?.onOpenDashboard() },
            onOpenSection: { [weak self] section in
                self?.closePopover()
                self?.appState.selectedSection = section
                self?.onOpenDashboard()
            },
            onToggleNotch: { [weak self] in self?.closePopover(); self?.onToggleNotch() }
        ))
    }

    /// Icon alone, or icon + one value. A small amber/red dot appears only when something needs attention.
    func updateTitle() {
        guard let button = statusItem.button else { return }
        let t = appState.telemetry
        let cpu = Int(t.cpuTotalPercent.rounded())
        let ram = Int(t.memory.usedPercent.rounded())
        let gpu = Int(t.gpu.deviceUtilizationPercent.rounded())
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

        let text: String
        switch appState.settings.menuBarDisplay {
        case .iconOnly: text = ""
        case .memory: text = " \(ram)%"
        case .cpu: text = " \(cpu)%"
        case .all: text = " \(cpu)% · \(ram)% · \(gpu)%"
        }
        let title = NSMutableAttributedString(string: text, attributes: [.font: font])
        let health = appState.macHealth
        if health.level != .good {
            let color: NSColor = health.level == .critical ? .systemRed : .systemOrange
            title.append(NSAttributedString(string: " ●", attributes: [
                .font: NSFont.systemFont(ofSize: 7),
                .foregroundColor: color,
                .baselineOffset: 2
            ]))
        }
        button.attributedTitle = title
        button.toolTip = "CleanTrash · CPU \(cpu)% · RAM \(ram)% · GPU \(gpu)%" + (health.reason.map { " · \($0)" } ?? "")
    }

    @objc private func buttonClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else if popover.isShown {
            closePopover()
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    // MARK: Right-click menu

    private func showMenu() {
        let menu = NSMenu()
        let items: [(String, Selector, String)] = [
            ("Abrir CleanTrash", #selector(openDashboardAction), "o"),
            ("Mostrar/ocultar Notch", #selector(toggleNotchAction), "n"),
            ("Analizar Mac", #selector(smartScanAction), "s"),
            ("Liberar RAM", #selector(optimizeRAMAction), "r")
        ]
        for (title, action, key) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        if appState.updater.isAvailable {
            let update = NSMenuItem(title: "Buscar actualizaciones…", action: #selector(checkUpdatesAction), keyEquivalent: "")
            update.target = self
            update.isEnabled = appState.updater.canCheckForUpdates
            menu.addItem(update)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Salir de CleanTrash", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openDashboardAction() { onOpenDashboard() }
    @objc private func toggleNotchAction() { onToggleNotch() }
    @objc private func optimizeRAMAction() { Task { await appState.optimizeRAM() } }
    @objc private func smartScanAction() { Task { await appState.runSmartScan() } }
    @objc private func checkUpdatesAction() { appState.updater.checkForUpdates() }
    @objc private func quitAction() { NSApp.terminate(nil) }
}

// MARK: - Popover

private struct MenuBarPopoverView: View {
    @Bindable var appState: AppState
    let onOpenDashboard: () -> Void
    let onOpenSection: (DashboardSection) -> Void
    let onToggleNotch: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            healthBlock
            if !appState.agents.earStack.isEmpty || !appState.agents.pending.isEmpty {
                divider
                agentsBlock
            }
            if appState.media.track != nil {
                divider
                musicBlock
            }
            divider
            footer
        }
        .padding(14)
        .frame(width: 300)
    }

    // Salud: verdict, three meters, one action.

    private var healthBlock: some View {
        let health = appState.macHealth
        let t = appState.telemetry
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(health.tint).frame(width: 7, height: 7)
                Text(health.label)
                    .font(.system(size: 13, weight: .semibold))
                if let reason = health.reason {
                    Text(reason)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                meter("CPU", t.cpuTotalPercent)
                meter("RAM", t.memory.usedPercent)
                meter("GPU", t.gpu.deviceUtilizationPercent)
            }
            HStack {
                Text("\(ByteFormat.compact(t.disk.availableBytes)) libres")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                primaryAction
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        let reclaimable = appState.totalSmartReclaimableBytes
        if appState.isCleaning || appState.isOptimizingRAM {
            ProgressView().controlSize(.small)
        } else if appState.macHealth.area == .cpu, appState.macHealth.level != .good {
            Button("Ver procesos") { onOpenSection(.performance) }
                .buttonStyle(MonoPrimaryButtonStyle())
        } else if appState.telemetry.memory.pressure != .normal {
            Button("Liberar RAM") { Task { await appState.optimizeRAM() } }
                .buttonStyle(MonoPrimaryButtonStyle())
        } else if reclaimable >= 500_000_000 {
            Button("Limpiar \(ByteFormat.compact(reclaimable))") { onOpenSection(.overview) }
                .buttonStyle(MonoPrimaryButtonStyle())
        } else {
            Button("Analizar") { Task { await appState.runSmartScan() } }
                .buttonStyle(MonoGhostButtonStyle())
        }
    }

    private func meter(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value.rounded()))%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
            }
            MonoProgressBar(value: value / 100, height: 4, tint: value >= 92 ? Mono.danger : value >= 80 ? Mono.caution : Mono.ink(scheme))
        }
        .frame(maxWidth: .infinity)
    }

    // Agentes: what each one is doing right now.

    private var agentsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agentes").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if !appState.agents.pending.isEmpty {
                    Button("Responder (\(appState.agents.pending.count))", action: onToggleNotch)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Mono.caution)
                }
            }
            ForEach(appState.agents.earStack.prefix(3)) { session in
                Button { appState.agents.focus(session) } label: {
                    HStack(spacing: 8) {
                        ProviderLogo(source: session.source, size: 18)
                        Text(session.project)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(NotchAgentsEar.liveActivity(session))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // Música: one compact row.

    @ViewBuilder
    private var musicBlock: some View {
        let media = appState.media
        if let track = media.track {
            HStack(spacing: 10) {
                Group {
                    if let art = media.artwork {
                        Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "music.note").frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.secondary.opacity(0.15))
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(track.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Button { media.togglePlayPause() } label: {
                    Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                Button { media.nextTrack() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Abrir CleanTrash", action: onOpenDashboard)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            iconButton("rectangle.topthird.inset.filled", help: "Notch", action: onToggleNotch)
            iconButton("gearshape", help: "Ajustes") {
                appState.settingsPane = .general
                onOpenSection(.settings)
            }
            iconButton("power", help: "Salir") { NSApp.terminate(nil) }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var divider: some View {
        Divider().opacity(0.6)
    }
}
