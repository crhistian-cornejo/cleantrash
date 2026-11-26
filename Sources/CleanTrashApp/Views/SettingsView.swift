import AppKit
import CleanTrashCore
import SwiftUI

/// Settings, split by surface. Every option lives in exactly one pane.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General"
    case notch = "Notch"
    case menuBar = "Barra de menús"
    case agents = "Agentes"
    case cleaning = "Limpieza"
    case permissions = "Permisos"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .notch: return "rectangle.topthird.inset.filled"
        case .menuBar: return "menubar.rectangle"
        case .agents: return "sparkles"
        case .cleaning: return "trash"
        case .permissions: return "lock.shield"
        }
    }
}

struct SettingsView: View {
    @Bindable var appState: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var paneNamespace

    private var pane: SettingsPane {
        get { appState.settingsPane }
        nonmutating set { appState.settingsPane = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ajustes")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Mono.ink(scheme))
                Spacer()
            }
            paneBar

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch pane {
                    case .general: generalPane
                    case .notch: notchPane
                    case .menuBar: menuBarPane
                    case .agents: agentsPane
                    case .cleaning: cleaningPane
                    case .permissions: permissionsPane
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.bottom, 24)
                .id(pane)
                .transition(.opacity)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .animation(reduceMotion ? .none : Mono.betweenSpring, value: pane)
    }

    // MARK: - Pane bar

    private var paneBar: some View {
        HStack(spacing: 4) {
            ForEach(SettingsPane.allCases) { item in
                let selected = item == pane
                Button {
                    pane = item
                    AppKitHaptics.tap()
                } label: {
                    Label(item.rawValue, systemImage: item.symbol)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Mono.ink(scheme) : Mono.muted(scheme))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Mono.ink(scheme).opacity(scheme == .dark ? 0.12 : 0.08))
                                    .matchedGeometryEffect(id: "pane", in: paneNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .padding(3)
        .background(Capsule().fill(Mono.ink(scheme).opacity(0.04)))
        .overlay(Capsule().strokeBorder(Mono.hairline(scheme), lineWidth: 0.75))
    }

    // MARK: - General

    @ViewBuilder
    private var generalPane: some View {
        group("Inicio") {
            toggleRow("Abrir al iniciar sesión", isOn: Binding(
                get: { appState.launchAtLoginEnabled },
                set: { appState.setLaunchAtLogin($0) }
            ))
        }
        group("Apariencia") {
            pickerRow("Tema", selection: $appState.settings.monochromeAppearance, width: 220) {
                Text("Oscuro").tag("dark")
                Text("Claro").tag("light")
                Text("Sistema").tag("system")
            }
            divider
            pickerRow("Superficie", note: "Notch y ventana", selection: $appState.settings.notchSurface, width: 260) {
                ForEach(NotchSurfaceMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        }
        group("Bienestar") {
            toggleRow("Pausas 20-20-20", note: "Se silencian en llamadas", isOn: $appState.settings.breatherEnabled)
            divider
            toggleRow("Mascota de agentes", isOn: $appState.settings.agentMascotEnabled)
        }
        updatesGroup
    }

    @ViewBuilder
    private var updatesGroup: some View {
        @Bindable var updater = appState.updater
        group("Actualizaciones", note: "Versión \(updater.version)") {
            if updater.isAvailable {
                toggleRow("Buscar automáticamente", isOn: $updater.automaticallyChecks)
                divider
                HStack(spacing: 12) {
                    rowLabel("Buscar ahora")
                    Spacer()
                    Button("Buscar actualizaciones") { updater.checkForUpdates() }
                        .buttonStyle(MonoGhostButtonStyle())
                        .disabled(!updater.canCheckForUpdates)
                }
                .padding(.vertical, 8)
            } else {
                HStack {
                    rowLabel("No disponible en compilaciones de desarrollo")
                    Spacer()
                }
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Notch

    @ViewBuilder
    private var notchPane: some View {
        group("Notch") {
            toggleRow("Activar Notch", isOn: $appState.settings.notchEnabled)
            divider
            pickerRow("Estilo", selection: $appState.settings.notchStyle, width: 200) {
                Text("Notch").tag(NotchStyleMode.notch)
                Text("Isla").tag(NotchStyleMode.island)
            }
            divider
            pickerRow("Abrir", selection: $appState.settings.notchTrigger, width: 200) {
                Text("Al pasar").tag(NotchOpenTrigger.hover)
                Text("Al hacer clic").tag(NotchOpenTrigger.click)
            }
        }

        group("Junto a la cámara") {
            toggleRow("Actividad en vivo", note: "Agentes, tareas y temporizador", isOn: $appState.settings.showLiveNotchEars)
            divider
            toggleRow("Música", isOn: $appState.settings.showMusicInNotchEars)
                .disabled(!appState.settings.showLiveNotchEars)
            divider
            toggleRow("Letra en vivo", isOn: $appState.settings.showLyricsInNotchEar)
                .disabled(!appState.settings.showLiveNotchEars || !appState.settings.showMusicInNotchEars)
            divider
            HStack(spacing: 12) {
                rowLabel("Volumen y brillo", note: appState.hud.isReplacingSystemHUD
                    ? "Reemplaza el aviso de macOS"
                    : "Requiere Accesibilidad para ocultar el de macOS")
                Spacer()
                if appState.settings.systemHUDInNotch && !appState.hud.isReplacingSystemHUD {
                    Button("Activar") { appState.hud.openAccessibilitySettings() }
                        .buttonStyle(MonoGhostButtonStyle())
                }
                switchControl($appState.settings.systemHUDInNotch)
            }
            .padding(.vertical, 10)
        }

        group("Bandeja") {
            toggleRow("Abrir al arrastrar archivos", isOn: $appState.settings.autoOpenShelfOnDrag)
            divider
            toggleRow("Historial del portapapeles", note: "Ignora contraseñas", isOn: $appState.settings.clipboardHistoryEnabled)
        }

        group("Widgets del inicio", note: "Hasta 4") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
                ForEach(NotchWidgetID.allCases) { widget in
                    widgetChip(widget)
                }
            }
            .padding(.vertical, 10)
        }
    }

    private func widgetChip(_ widget: NotchWidgetID) -> some View {
        let active = appState.settings.homeWidgets.contains(widget)
        return Button {
            appState.toggleHomeWidget(widget)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: widget.symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(widget.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .opacity(active ? 1 : 0.35)
            }
            .foregroundStyle(active ? Mono.primaryInk(scheme) : Mono.ink(scheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(active ? Mono.primaryFill(scheme) : Mono.ink(scheme).opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: - Menu bar

    @ViewBuilder
    private var menuBarPane: some View {
        group("Barra de menús", note: "Clic: resumen · clic derecho: menú") {
            pickerRow("Mostrar", selection: $appState.settings.menuBarDisplay, width: 300) {
                ForEach(MenuBarDisplay.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        }
    }

    // MARK: - Agents

    @ViewBuilder
    private var agentsPane: some View {
        group("Conectar", note: "Actividad y permisos en el Notch") {
            ForEach(Array(AgentSource.allCases.enumerated()), id: \.element) { index, source in
                if index > 0 { divider }
                let present = appState.agents.present[source] == true || appState.agents.installed[source] == true
                HStack(spacing: 12) {
                    ProviderLogo(source: source, size: 22)
                    rowLabel(source.displayName, note: agentNote(source, present: present))
                    Spacer()
                    switchControl(Binding(
                        get: { appState.agents.installed[source] ?? false },
                        set: { appState.agents.setIntegration(source, enabled: $0) }
                    ))
                    .disabled(!present)
                }
                .padding(.vertical, 9)
            }
            if let error = appState.agents.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Mono.danger)
                    .padding(.bottom, 8)
            }
        }
        .onAppear { appState.agents.refreshInstallState() }
    }

    private func agentNote(_ source: AgentSource, present: Bool) -> String? {
        guard present else { return "No instalado" }
        switch source {
        case .claude: return "Incluye T3 Code"
        case .codex: return "Incluye T3 Code · pide confiar la primera vez"
        case .antigravity: return "Solo actividad"
        }
    }

    // MARK: - Cleaning

    @ViewBuilder
    private var cleaningPane: some View {
        group("Al borrar") {
            pickerRow("Archivos y apps", selection: $appState.settings.useTrashByDefault, width: 220) {
                Text("Borrar").tag(false)
                Text("A la Papelera").tag(true)
            }
            divider
            toggleRow("Compilaciones directo", note: "target/, node_modules/, .build/", isOn: $appState.settings.permanentDeleteDevBuilds)
            divider
            HStack {
                rowLabel("Papelera")
                Spacer()
                Button("Vaciar ahora") { Task { await appState.emptyTrashNow() } }
                    .buttonStyle(MonoGhostButtonStyle())
                    .disabled(appState.isCleaning)
            }
            .padding(.vertical, 10)
        }

        group("Avisos") {
            toggleRow("Memoria alta", isOn: $appState.settings.autoNotifyHighMemory)
            divider
            toggleRow("Basura en proyectos", isOn: $appState.settings.autoNotifyDevArtifacts)
            if appState.settings.autoNotifyDevArtifacts {
                sliderRow(
                    "Avisar desde",
                    value: $appState.settings.devAlertThresholdGB,
                    range: 0.5...20, step: 0.5,
                    format: String(format: "%.1f GB", appState.settings.devAlertThresholdGB)
                )
            }
            divider
            toggleRow("Apps sin usar", isOn: $appState.settings.autoAskUnusedApps)
            if appState.settings.autoAskUnusedApps {
                HStack {
                    Text("Sin abrir desde hace")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Mono.muted(scheme))
                    Spacer()
                    Stepper("\(appState.settings.unusedAppThresholdDays) días", value: $appState.settings.unusedAppThresholdDays, in: 14...180, step: 15)
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                }
                .padding(.bottom, 10)
            }
            divider
            HStack {
                rowLabel("Decisiones sobre apps", note: "\"La uso\" y \"Luego\"")
                Spacer()
                Button("Restablecer") {
                    appState.resetAppDecisions()
                    AppKitHaptics.tap()
                }
                .buttonStyle(MonoGhostButtonStyle())
            }
            .padding(.vertical, 10)
        }

        group("Automático") {
            toggleRow("Liberar RAM en presión crítica", isOn: $appState.settings.autoOptimizeCriticalRAM)
            divider
            toggleRow(
                "Limpiar proyectos viejos",
                note: "Inactivos más de \(appState.settings.devStaleDays) días",
                isOn: $appState.settings.autoCleanStaleDevEnabled
            )
            if appState.settings.autoCleanStaleDevEnabled {
                sliderRow(
                    "Con menos de",
                    value: $appState.settings.autoCleanMinFreeGB,
                    range: 10...120, step: 5,
                    format: "\(Int(appState.settings.autoCleanMinFreeGB)) GB libres"
                )
            }
        }

        group("Carpetas de código", trailing: AnyView(
            Button("Agregar…") { addWatchedFolder() }.buttonStyle(MonoGhostButtonStyle())
        )) {
            VStack(spacing: 6) {
                ForEach(appState.settings.watchedDevFolders, id: \.self) { folder in
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Mono.muted(scheme))
                        Text(folder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 12))
                            .foregroundStyle(Mono.ink(scheme))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            appState.settings.watchedDevFolders.removeAll { $0 == folder }
                            AppKitHaptics.tap()
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Mono.muted(scheme))
                        }
                        .buttonStyle(.plain)
                        .help("Dejar de vigilar")
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Permissions

    @ViewBuilder
    private var permissionsPane: some View {
        group("macOS") {
            permissionRow(
                "Acceso total al disco",
                note: "Papelera y cachés protegidas",
                granted: appState.hasFullDiskAccess
            ) { appState.openFullDiskAccessSettings() }
            divider
            permissionRow(
                "Accesibilidad",
                note: "Teclas de volumen y brillo · autocompletar",
                granted: AXIsProcessTrusted()
            ) { appState.hud.openAccessibilitySettings() }
            divider
            permissionRow(
                "Grabación de pantalla",
                note: "Solo para OCR",
                granted: VisionTextCapture.hasScreenRecordingPermission
            ) { VisionTextCapture.openScreenRecordingSettings() }
        }
    }

    private func permissionRow(_ title: String, note: String, granted: Bool, open: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(granted ? Mono.healthy : Mono.caution)
            rowLabel(title, note: note)
            Spacer()
            if !granted {
                Button("Abrir", action: open)
                    .buttonStyle(MonoGhostButtonStyle())
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: - Building blocks

    private func group<Content: View>(
        _ title: String,
        note: String? = nil,
        trailing: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Mono.muted(scheme))
                if let note {
                    Text("· \(note)")
                        .font(.system(size: 11))
                        .foregroundStyle(Mono.muted(scheme).opacity(0.7))
                }
                Spacer()
                if let trailing { trailing }
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) { content() }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
                .monoCard(radius: 12)
        }
    }

    private func rowLabel(_ title: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Mono.ink(scheme))
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Mono.muted(scheme))
                    .lineLimit(1)
            }
        }
    }

    private func switchControl(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }

    private func toggleRow(_ title: String, note: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            rowLabel(title, note: note)
            Spacer()
            switchControl(isOn)
        }
        .padding(.vertical, 10)
    }

    private func pickerRow<Value: Hashable, Options: View>(
        _ title: String,
        note: String? = nil,
        selection: Binding<Value>,
        width: CGFloat,
        @ViewBuilder options: () -> Options
    ) -> some View {
        HStack(spacing: 12) {
            rowLabel(title, note: note)
            Spacer()
            Picker("", selection: selection, content: options)
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: width)
        }
        .padding(.vertical, 9)
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: String
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(Mono.muted(scheme))
            Spacer()
            Slider(value: value, in: range, step: step)
                .frame(width: 170)
            Text(format)
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Mono.ink(scheme))
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.bottom, 10)
    }

    private var divider: some View {
        Divider().overlay(Mono.hairline(scheme))
    }

    private func addWatchedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           !appState.settings.watchedDevFolders.contains(url.path) {
            appState.settings.watchedDevFolders.append(url.path)
        }
    }
}
