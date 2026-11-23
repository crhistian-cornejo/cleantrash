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
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Ajustes")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Mono.ink(scheme))
                        Text("Controla cómo limpia CleanTrash, el aspecto del Notch y las alertas automáticas.")
                            .font(.system(size: 12))
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
                settingsCard(title: "ELIMINACIÓN Y DISCO", icon: "trash") {
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
                settingsCard(title: "NOTCH Y APARIENCIA", icon: "rectangle.topthird.inset.filled") {
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
                settingsCard(title: "AUTOMATIZACIÓN EN SEGUNDO PLANO", icon: "bolt.badge.automatic") {
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
                                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
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
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
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
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        }
                        .padding(.vertical, 10)
                    }
                }

                // 4. Carpetas vigiladas (Dev Radar)
                settingsCard(title: "CARPETAS DE CÓDIGO VIGILADAS", icon: "folder.badge.gearshape") {
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
                                    .font(.system(size: 12, design: .monospaced))
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

                // 5. Permiso Acceso total al disco
                HStack(spacing: 12) {
                    Circle()
                        .fill(appState.hasFullDiskAccess ? Mono.healthy : Mono.caution)
                        .frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Acceso total al disco")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Mono.ink(scheme))
                        Text(appState.hasFullDiskAccess
                             ? "Activado — CleanTrash puede limpiar cachés protegidas y la Papelera sin límites."
                             : "Pendiente — agrégalo en Ajustes del Sistema para escanear también la Papelera y contenedores.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Mono.muted(scheme))
                    }
                    Spacer()
                    Button("Ajustes del Sistema") {
                        appState.openFullDiskAccessSettings()
                    }
                    .buttonStyle(MonoGhostButtonStyle())
                }
                .padding(16)
                .monoCard(radius: 14)
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
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(0.8)
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
