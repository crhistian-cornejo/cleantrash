import AppKit
import CleanTrashCore
import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header
                HStack(alignment: .center) {
                    Icon3D(name: .settings, size: 58)
                        .padding(.trailing, 8)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Ajustes")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(Mono.ink(scheme))
                        Text("Controla cómo limpia CleanTrash, el aspecto del Notch y las alertas automáticas.")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Mono.muted(scheme))
                    }
                    Spacer()
                    Button {
                        Task { await appState.emptyTrashNow() }
                    } label: {
                        Label("Vaciar Papelera", systemImage: "trash.slash")
                    }
                    .buttonStyle(MonoGhostButtonStyle())
                    .disabled(appState.isCleaning)
                }

                // 1. Modo de eliminación (Directo vs Papelera)
                settingsCard(title: "Eliminación y disco", icon: "trash") {
                    VStack(spacing: 0) {
                        HStack(alignment: .center) {
                            rowLabel(
                                title: "Al limpiar archivos o desinstalar apps",
                                subtitle: appState.settings.useTrashByDefault
                                    ? "Se envían a la Papelera primero (el espacio se libera al vaciarla)."
                                    : "Se eliminan directo del disco y recuperas el espacio al instante."
                            )
                            Spacer()
                            Picker("", selection: $appState.settings.useTrashByDefault) {
                                Text("Eliminar directo").tag(false)
                                Text("Mover a Papelera").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 240)
                        }
                        .padding(.vertical, 10)

                        divider

                        toggleRow(
                            title: "Borrar carpetas de compilación al instante",
                            subtitle: "target/, node_modules/ y .build/ se borran directo sin pasar por la Papelera.",
                            isOn: $appState.settings.permanentDeleteDevBuilds
                        )

                        divider

                        HStack {
                            rowLabel(
                                title: "Apps que marcaste como \"La uso\" o \"Luego\"",
                                subtitle: "Vuelve a revisarlas en la pestaña de Apps."
                            )
                            Spacer()
                            Button("Restablecer") {
                                appState.resetAppDecisions()
                                AppKitHaptics.tap()
                            }
                            .buttonStyle(MonoGhostButtonStyle())
                        }
                        .padding(.vertical, 10)
                    }
                }

                // 2. Dynamic Notch y Apariencia
                settingsCard(title: "Notch y apariencia", icon: "rectangle.topthird.inset.filled") {
                    VStack(spacing: 0) {
                        toggleRow(
                            title: "Activar Dynamic Notch",
                            subtitle: "Panel rápido junto a la cámara con RAM, GPU, disco y limpiezas en 1 clic.",
                            isOn: $appState.settings.notchEnabled
                        )
                        divider
                        toggleRow(
                            title: "Mostrar indicadores junto a la cámara",
                            subtitle: "Muestra el % de RAM a la izquierda y GPU o espacio limpiable a la derecha.",
                            isOn: $appState.settings.showLiveNotchEars
                        )
                        divider
                        HStack {
                            rowLabel(title: "Estilo", subtitle: "Pegado a la cámara del MacBook o píldora flotante.")
                            Spacer()
                            Picker("", selection: $appState.settings.notchStyle) {
                                Text("Notch").tag(NotchStyleMode.notch)
                                Text("Isla flotante").tag(NotchStyleMode.island)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                        }
                        .padding(.vertical, 10)

                        divider
                        HStack {
                            rowLabel(title: "Superficie (Notch y ventana)", subtitle: "Negro fusionado con la cámara, Dynamic Glass o Liquid Glass en toda la app.")
                            Spacer()
                            Picker("", selection: $appState.settings.notchSurface) {
                                Text("Negro").tag(NotchSurfaceMode.obsidian)
                                Text("Dynamic Glass").tag(NotchSurfaceMode.glass)
                                Text("Liquid Glass").tag(NotchSurfaceMode.clearGlass)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 280)
                        }
                        .padding(.vertical, 10)

                        divider
                        toggleRow(
                            title: "Mostrar Spotify / Música junto a la cámara",
                            subtitle: "Muestra portada, visualizador y canción en vivo en la oreja derecha cuando no hay agentes trabajando.",
                            isOn: $appState.settings.showMusicInNotchEars
                        )
                        divider
                        toggleRow(
                            title: "Letras sincronizadas en la oreja del Notch",
                            subtitle: "Muestra la línea actual de la canción en vivo al lado de la cámara.",
                            isOn: $appState.settings.showLyricsInNotchEar
                        )
                        divider
                        toggleRow(
                            title: "Abrir Bandeja al arrastrar archivos al Notch",
                            subtitle: "Al llevar un archivo hacia arriba, el Notch se abre para guardarlo, comprimirlo o compartirlo.",
                            isOn: $appState.settings.autoOpenShelfOnDrag
                        )
                        divider
                        toggleRow(
                            title: "Mascota flotante de Agentes IA (CleanBot)",
                            subtitle: "Muestra un compañero animado en pantalla que reacciona a Claude/Codex/Antigravity y permite aprobar permisos en 1 clic.",
                            isOn: $appState.settings.agentMascotEnabled
                        )
                        divider
                        toggleRow(
                            title: "Breather — pausas 20-20-20 (ojos, estiramiento, agua)",
                            subtitle: "Recordatorios suaves en el Notch cada 20 min; se silencia automáticamente cuando estás en llamada.",
                            isOn: $appState.settings.breatherEnabled
                        )
                        divider
                        toggleRow(
                            title: "Historial del portapapeles en la Bandeja",
                            subtitle: "Guarda texto, enlaces, colores HEX e imágenes copiadas (ignora contraseñas).",
                            isOn: $appState.settings.clipboardHistoryEnabled
                        )

                        divider
                        VStack(alignment: .leading, spacing: 8) {
                            rowLabel(
                                title: "Widgets del Home en el Notch",
                                subtitle: "Elige hasta 4 widgets activos (también puedes arrastrarlos desde el botón ⊞ del Notch)."
                            )
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 6)], spacing: 6) {
                                ForEach(NotchWidgetID.allCases) { widget in
                                    let active = appState.settings.homeWidgets.contains(widget)
                                    Button {
                                        var current = appState.settings.homeWidgets
                                        if let idx = current.firstIndex(of: widget) {
                                            if current.count > 1 { current.remove(at: idx) }
                                        } else {
                                            if current.count >= 4 { current.removeFirst() }
                                            current.append(widget)
                                        }
                                        appState.settings.homeWidgets = current
                                        AppKitHaptics.tap()
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: widget.symbol)
                                                .font(.system(size: 11, weight: .semibold))
                                            Text(widget.title)
                                                .font(.system(size: 11, weight: .semibold))
                                                .lineLimit(1)
                                            Spacer(minLength: 0)
                                            if active {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.system(size: 11))
                                            }
                                        }
                                        .foregroundStyle(active ? Mono.primaryInk(scheme) : Mono.ink(scheme))
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(active ? Mono.primaryFill(scheme) : Mono.ink(scheme).opacity(0.06))
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .pointingHandCursor()
                                }
                            }
                        }
                        .padding(.vertical, 10)

                        divider
                        HStack {
                            rowLabel(title: "Cómo abrir el Notch", subtitle: "Al pasar el cursor o solo al hacer clic.")
                            Spacer()
                            Picker("", selection: $appState.settings.notchTrigger) {
                                Text("Al pasar mouse").tag(NotchOpenTrigger.hover)
                                Text("Al hacer clic").tag(NotchOpenTrigger.click)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                        }
                        .padding(.vertical, 10)

                        divider
                        HStack {
                            rowLabel(title: "Tema de la ventana", subtitle: "Monocromo oscuro, claro o igual que macOS.")
                            Spacer()
                            Picker("", selection: $appState.settings.monochromeAppearance) {
                                Text("Oscuro").tag("dark")
                                Text("Claro").tag("light")
                                Text("Sistema").tag("system")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                        }
                        .padding(.vertical, 10)
                    }
                }

                // 3. Automatización inteligente
                settingsCard(title: "Agentes de IA en el notch", icon: "sparkles") {
                    VStack(spacing: 0) {
                        ForEach(Array(AgentSource.allCases.enumerated()), id: \.element) { index, source in
                            if index > 0 { divider }
                            toggleRow(
                                title: source.displayName,
                                subtitle: agentSubtitle(source),
                                isOn: Binding(
                                    get: { appState.agents.installed[source] ?? false },
                                    set: { appState.agents.setIntegration(source, enabled: $0) }
                                )
                            )
                            .disabled(appState.agents.present[source] != true && appState.agents.installed[source] != true)
                        }
                        if let error = appState.agents.lastError {
                            Text(error)
                                .font(.system(size: 11))
                                .foregroundStyle(Mono.danger)
                                .padding(.bottom, 8)
                        }
                    }
                }
                .onAppear { appState.agents.refreshInstallState() }

                settingsCard(title: "Automatización en segundo plano", icon: "bolt.badge.automatic") {
                    VStack(spacing: 0) {
                        toggleRow(
                            title: "Abrir CleanTrash al iniciar sesión en macOS",
                            subtitle: "Mantiene el Notch y la barra de menú listos al encender tu Mac.",
                            isOn: Binding(
                                get: { appState.launchAtLoginEnabled },
                                set: { appState.setLaunchAtLogin($0) }
                            )
                        )
                        divider
                        toggleRow(
                            title: "Avisar cuando tus proyectos acumulen mucha basura",
                            subtitle: "Notifica en el Notch si target/ o node_modules/ superan tu límite.",
                            isOn: $appState.settings.autoNotifyDevArtifacts
                        )
                        divider
                        toggleRow(
                            title: "Preguntar por apps que llevas tiempo sin abrir",
                            subtitle: "Te muestra una tarjeta rápida para conservar o desinstalar con tu huella.",
                            isOn: $appState.settings.autoAskUnusedApps
                        )
                        divider
                        toggleRow(
                            title: "Optimizar RAM automáticamente en carga crítica",
                            subtitle: "Libera memoria inactiva si macOS entra en presión roja.",
                            isOn: $appState.settings.autoOptimizeCriticalRAM
                        )
                        divider
                        toggleRow(
                            title: "Limpiar proyectos viejos si queda poco disco libre",
                            subtitle: "Borra compilaciones inactivas (> \(appState.settings.devStaleDays) días) automáticamente.",
                            isOn: $appState.settings.autoCleanStaleDevEnabled
                        )

                        if appState.settings.autoCleanStaleDevEnabled {
                            HStack {
                                Text("Activar cuando el espacio libre baje de")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Mono.muted(scheme))
                                Spacer()
                                Slider(value: $appState.settings.autoCleanMinFreeGB, in: 10...120, step: 5)
                                    .frame(width: 170)
                                Text("\(Int(appState.settings.autoCleanMinFreeGB)) GB")
                                    .font(.system(size: 11.5, weight: .bold).monospacedDigit())
                                    .frame(width: 52, alignment: .trailing)
                            }
                            .padding(.bottom, 10)
                        }

                        divider
                        HStack {
                            rowLabel(
                                title: "Aviso de basura en proyectos",
                                subtitle: "Avisar al superar este tamaño total."
                            )
                            Spacer()
                            Slider(value: $appState.settings.devAlertThresholdGB, in: 0.5...20.0, step: 0.5)
                                .frame(width: 160)
                            Text(String(format: "%.1f GB", appState.settings.devAlertThresholdGB))
                                .font(.system(size: 11.5, weight: .bold).monospacedDigit())
                                .frame(width: 54, alignment: .trailing)
                        }
                        .padding(.vertical, 10)

                        divider
                        HStack {
                            rowLabel(
                                title: "Considerar una app sin usar después de",
                                subtitle: "Días sin abrirla según Spotlight."
                            )
                            Spacer()
                            Stepper("\(appState.settings.unusedAppThresholdDays) días", value: $appState.settings.unusedAppThresholdDays, in: 14...180, step: 15)
                                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        }
                        .padding(.vertical, 10)
                    }
                }

                // 4. Carpetas vigiladas (Dev Radar)
                settingsCard(title: "Carpetas de código vigiladas", icon: "folder.badge.gearshape") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("CleanTrash vigila estas carpetas en tiempo real para detectar target/, node_modules/ y .build/.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Mono.muted(scheme))
                            Spacer()
                            Button("Agregar carpeta…") { addWatchedFolder() }
                                .buttonStyle(MonoGhostButtonStyle())
                        }
                        .padding(.top, 4)

                        ForEach(appState.settings.watchedDevFolders, id: \.self) { folder in
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Mono.muted(scheme))
                                Text(folder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(Mono.ink(scheme))
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
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Mono.ink(scheme).opacity(0.05)))
                        }
                    }
                    .padding(.vertical, 6)
                }

                // 5. Permisos del sistema (Acceso total al disco + Grabación de pantalla para OCR)
                settingsCard(title: "Permisos de privacidad", icon: "lock.shield") {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(appState.hasFullDiskAccess ? Mono.healthy : Mono.caution)
                                .frame(width: 9, height: 9)
                            rowLabel(
                                title: "Acceso total al disco",
                                subtitle: appState.hasFullDiskAccess
                                    ? "Activado — CleanTrash puede limpiar cachés protegidas y la Papelera sin límites."
                                    : "Pendiente — agrégalo en Ajustes del Sistema para escanear también la Papelera y contenedores."
                            )
                            Spacer()
                            Button("Ajustes del Sistema") {
                                appState.openFullDiskAccessSettings()
                            }
                            .buttonStyle(MonoGhostButtonStyle())
                        }
                        .padding(.vertical, 10)

                        divider

                        HStack(spacing: 12) {
                            Circle()
                                .fill(VisionTextCapture.hasScreenRecordingPermission ? Mono.healthy : Mono.caution)
                                .frame(width: 9, height: 9)
                            rowLabel(
                                title: "Captura de pantalla (OCR interactivo)",
                                subtitle: VisionTextCapture.hasScreenRecordingPermission
                                    ? "Activado — OCR captura texto del área que elijas usando Apple Vision 100% local (sin audio)."
                                    : "Opcional — macOS muestra el aviso estándar de pantalla/audio, pero CleanTrash solo lee el área elegida localmente. También puedes usar OCR Clip con ⌘⇧⌃4 sin este permiso."
                            )
                            Spacer()
                            Button("Abrir permiso") {
                                VisionTextCapture.openScreenRecordingSettings()
                            }
                            .buttonStyle(MonoGhostButtonStyle())
                        }
                        .padding(.vertical, 10)
                    }
                }
            }
            .padding(20)
        }
    }

    private func settingsCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .bold))
                Text(title)
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
            }
            .foregroundStyle(Mono.muted(scheme))

            content()
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .monoCard(radius: 14)
        }
    }

    private func rowLabel(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Mono.ink(scheme))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(Mono.muted(scheme))
        }
    }

    private func toggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            rowLabel(title: title, subtitle: subtitle)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 10)
    }

    private func agentSubtitle(_ source: AgentSource) -> String {
        if appState.agents.present[source] != true && appState.agents.installed[source] != true {
            return "No está instalado en este Mac."
        }
        switch source {
        case .claude:
            return "Actividad y solicitudes de permiso (Permitir / Denegar) desde el notch. Incluye los hilos de Claude en T3 Code."
        case .codex:
            return "Actividad y permisos de Codex, también los hilos de Codex en T3 Code. Codex pedirá confiar en el hook la primera vez."
        case .antigravity:
            return "Muestra qué herramienta usa y cuándo termina. Sus permisos se siguen respondiendo en Antigravity."
        }
    }

    private var divider: some View {
        Divider().overlay(Mono.hairline(scheme))
    }

    private func addWatchedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            if !appState.settings.watchedDevFolders.contains(url.path) {
                appState.settings.watchedDevFolders.append(url.path)
            }
        }
    }
}
