import CleanTrashCore
import SwiftUI

struct MainDashboardView: View {
    @Bindable var appState: AppState
    let onToggleNotch: () -> Void

    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dismissedFDABanner = false
    @State private var showFDAGuide = false

    private var activeScheme: ColorScheme {
        appState.preferredColorScheme ?? systemScheme
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Mono.hairline(activeScheme))
            mainPane
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Mono.canvas(activeScheme))
        .preferredColorScheme(appState.preferredColorScheme)
        .sheet(isPresented: $showFDAGuide) {
            FullDiskAccessGuideSheet(appState: appState) {
                showFDAGuide = false
            }
        }
    }

    // MARK: - Collapsible AppKit Vibrancy Sidebar (Expanded <-> Icon Rail)

    private var isCollapsed: Bool { appState.settings.sidebarCollapsed }

    private var sidebar: some View {
        VStack(alignment: isCollapsed ? .center : .leading, spacing: 0) {
            // Brand header + collapse toggle right below traffic lights
            HStack(spacing: isCollapsed ? 0 : 10) {
                if !isCollapsed {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Mono.primaryFill(activeScheme))
                            .frame(width: 26, height: 26)
                        Image(systemName: "sparkle")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Mono.primaryInk(activeScheme))
                    }
                    VStack(alignment: .leading, spacing: 0.5) {
                        Text("CleanTrash")
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(Mono.ink(activeScheme))
                            .lineLimit(1)
                        Text("Tu Mac ligero")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Mono.muted(activeScheme))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }

                Button {
                    withAnimation(reduceMotion ? .none : Mono.betweenSpring) {
                        appState.settings.sidebarCollapsed.toggle()
                    }
                    AppKitHaptics.tap()
                } label: {
                    Image(systemName: isCollapsed ? "sidebar.left" : "sidebar.leading")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Mono.muted(activeScheme))
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Mono.ink(activeScheme).opacity(0.07))
                        )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(isCollapsed ? "Expandir barra lateral (⌘\\)" : "Colapsar en iconos (⌘\\)")
            }
            .padding(.top, 36)
            .padding(.horizontal, isCollapsed ? 0 : 14)
            .padding(.bottom, 14)

            // Section list
            VStack(spacing: 4) {
                ForEach(DashboardSection.allCases) { section in
                    sidebarRow(section)
                }
            }
            .padding(.horizontal, isCollapsed ? 10 : 10)

            Spacer()

            // Footer: full live vitals card OR ultra-compact icon-rail vitals
            if isCollapsed {
                VStack(spacing: 10) {
                    Button {
                        onToggleNotch()
                        AppKitHaptics.tap()
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Mono.ink(activeScheme).opacity(0.09))
                                .frame(width: 40, height: 36)
                            Image(systemName: "rectangle.topthird.inset.filled")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Mono.ink(activeScheme))
                        }
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Mostrar / Ocultar Notch (⌘N)")

                    Circle()
                        .fill(appState.telemetry.memory.pressure == .normal ? Mono.healthy : Mono.caution)
                        .frame(width: 8, height: 8)
                        .help("RAM \(Int(appState.telemetry.memory.usedPercent))% · GPU \(Int(appState.telemetry.gpu.deviceUtilizationPercent))% · CPU \(Int(appState.telemetry.cpuTotalPercent))%")
                }
                .padding(.bottom, 16)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(appState.telemetry.memory.pressure == .normal ? Mono.healthy : Mono.caution)
                                .frame(width: 6, height: 6)
                            Text("EN VIVO")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .tracking(0.8)
                                .foregroundStyle(Mono.muted(activeScheme))
                        }
                        Spacer()
                        Button {
                            onToggleNotch()
                            AppKitHaptics.tap()
                        } label: {
                            Text("Notch")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Mono.ink(activeScheme))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(Capsule().fill(Mono.ink(activeScheme).opacity(0.11)))
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }

                    VStack(spacing: 5) {
                        miniVital("CPU", pct: appState.telemetry.cpuTotalPercent)
                        miniVital("RAM", pct: appState.telemetry.memory.usedPercent)
                        miniVital("GPU", pct: appState.telemetry.gpu.deviceUtilizationPercent)
                    }

                    if appState.totalReclaimedSessionBytes > 0 {
                        HStack {
                            Text("LIBERADO HOY")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Mono.muted(activeScheme))
                            Spacer()
                            Text(ByteFormat.compact(appState.totalReclaimedSessionBytes))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Mono.healthy)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(12)
                .monoCard(radius: 12)
                .padding(12)
            }
        }
        .frame(width: isCollapsed ? 66 : 228)
        .background(
            ZStack {
                VisualEffectBackdrop(material: .sidebar, blendingMode: .behindWindow)
                Mono.chrome(activeScheme).opacity(0.76)
            }
        )
        .animation(reduceMotion ? .none : Mono.betweenSpring, value: isCollapsed)
    }

    private func sidebarRow(_ section: DashboardSection) -> some View {
        let isSelected = appState.selectedSection == section
        let badge = badgeText(for: section)
        return Button {
            withAnimation(reduceMotion ? .none : Mono.betweenSpring) {
                appState.selectedSection = section
            }
            AppKitHaptics.tap()
            if section == .diskMap && appState.diskRoot == nil && !appState.isMappingDisk {
                Task { await appState.mapDisk() }
            }
        } label: {
            if isCollapsed {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: section.symbol)
                        .font(.system(size: 14.5, weight: isSelected ? .semibold : .medium))
                        .frame(width: 42, height: 36)
                        .foregroundStyle(isSelected ? Mono.primaryInk(activeScheme) : Mono.ink(activeScheme).opacity(0.84))
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isSelected ? Mono.primaryFill(activeScheme) : Color.clear)
                        )

                    if badge != nil && !isSelected {
                        Circle()
                            .fill(Mono.ink(activeScheme))
                            .frame(width: 5.5, height: 5.5)
                            .offset(x: -5, y: 5)
                    }
                }
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 9) {
                    Image(systemName: section.symbol)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .frame(width: 18)
                    Text(section.rawValue)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(isSelected ? Mono.primaryInk(activeScheme) : Mono.ink(activeScheme).opacity(0.82))
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(
                                    isSelected
                                        ? Mono.primaryInk(activeScheme).opacity(0.16)
                                        : Mono.ink(activeScheme).opacity(0.12)
                                )
                            )
                    }
                }
                .foregroundStyle(isSelected ? Mono.primaryInk(activeScheme) : Mono.ink(activeScheme).opacity(0.86))
                .padding(.horizontal, 11)
                .padding(.vertical, 8.5)
                .frame(height: 35)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? Mono.primaryFill(activeScheme) : Color.clear)
                )
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(badge.map { "\(section.rawValue) (\($0))" } ?? section.rawValue)
    }

    private func badgeText(for section: DashboardSection) -> String? {
        switch section {
        case .devRadar:
            return appState.reclaimableDevBytes > 0 ? ByteFormat.compact(appState.reclaimableDevBytes) : nil
        case .systemJunk:
            return appState.reclaimableJunkBytes > 0 ? ByteFormat.compact(appState.reclaimableJunkBytes) : nil
        case .appsAudit:
            return appState.unusedApps.isEmpty ? nil : "\(appState.unusedApps.count)"
        default:
            return nil
        }
    }

    private func miniVital(_ label: String, pct: Double) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Mono.muted(activeScheme))
                .frame(width: 28, alignment: .leading)
            MonoProgressBar(value: pct / 100.0, height: 4)
            Text("\(Int(pct))%")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Mono.ink(activeScheme))
                .frame(width: 30, alignment: .trailing)
                .contentTransition(.numericText())
        }
    }

    // MARK: - Main Content Pane

    private var mainPane: some View {
        VStack(spacing: 0) {
            // Compact top permission bar (dismissible, zero wasted gap)
            if !appState.hasFullDiskAccess && !dismissedFDABanner {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Mono.caution)
                    Text("Activa el Acceso total al disco para limpiar también la Papelera y datos ocultos.")
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                    Spacer()
                    Button("Activar") {
                        appState.openFullDiskAccessSettings()
                        showFDAGuide = true
                    }
                    .buttonStyle(MonoGhostButtonStyle())
                    Button("Listo") {
                        appState.hasFullDiskAccess = PathSafety.hasFullDiskAccess()
                    }
                    .buttonStyle(MonoGhostButtonStyle())
                    Button {
                        withAnimation(Mono.fast) { dismissedFDABanner = true }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Mono.muted(activeScheme))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(Mono.ink(activeScheme))
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Mono.cardElevated(activeScheme))
                .overlay(alignment: .bottom) {
                    Divider().overlay(Mono.hairline(activeScheme))
                }
            }

            if let activity = appState.activityLabel, appState.isCleaning || appState.isOptimizingRAM {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(activity)
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(Mono.ink(activeScheme))
                .padding(.horizontal, 20)
                .padding(.vertical, 7)
                .background(Mono.card(activeScheme))
                .overlay(alignment: .bottom) {
                    Divider().overlay(Mono.hairline(activeScheme))
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if let banner = appState.statusBanner {
                HStack(spacing: 8) {
                    Image(systemName: appState.statusTone.symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(appState.statusTone.color)
                        .symbolEffect(.bounce, value: banner)
                    Text(banner)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer()
                    if appState.statusTone == .error, banner.contains("Acceso total") || banner.contains("Automatización") {
                        Button("Abrir Ajustes") {
                            if banner.contains("Automatización"),
                               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                                NSWorkspace.shared.open(url)
                            } else {
                                appState.openFullDiskAccessSettings()
                                showFDAGuide = true
                            }
                        }
                        .buttonStyle(MonoGhostButtonStyle())
                    }
                    Button {
                        withAnimation(Mono.fast) { appState.statusBanner = nil }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Mono.muted(activeScheme))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(Mono.ink(activeScheme))
                .padding(.horizontal, 20)
                .padding(.vertical, 7)
                .background(appState.statusTone == .success || appState.statusTone == .info
                            ? Mono.card(activeScheme)
                            : appState.statusTone.color.opacity(activeScheme == .dark ? 0.12 : 0.14))
                .overlay(alignment: .bottom) {
                    Divider().overlay(Mono.hairline(activeScheme))
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: banner) {
                    // Successes and info fade on their own; warnings/errors stay until dismissed.
                    guard appState.statusTone == .success || appState.statusTone == .info else { return }
                    try? await Task.sleep(for: .seconds(6))
                    guard !Task.isCancelled, appState.statusBanner == banner else { return }
                    withAnimation(Mono.fast) { appState.statusBanner = nil }
                }
            }

            // Active Route
            Group {
                switch appState.selectedSection {
                case .overview:
                    OverviewView(appState: appState)
                case .devRadar:
                    DevRadarView(appState: appState)
                case .diskMap:
                    DiskMapView(appState: appState)
                case .systemJunk:
                    SystemJunkView(appState: appState)
                case .appsAudit:
                    AppsAuditView(appState: appState)
                case .performance:
                    PerformanceView(appState: appState)
                case .settings:
                    SettingsView(appState: appState)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(appState.selectedSection)
            .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 4)))
            .animation(reduceMotion ? .none : Mono.emphasized, value: appState.selectedSection)
        }
    }
}

private struct FullDiskAccessGuideSheet: View {
    @Bindable var appState: AppState
    let onClose: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                // Draggable app icon (just like CleanMyMac's FDAResolutionUIKit!)
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 52, height: 52)
                    .draggable(Bundle.main.bundleURL)
                    .help("Arrastra este icono a la lista de Acceso total al disco")

                VStack(alignment: .leading, spacing: 3) {
                    Text("Dar Acceso total al disco")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Mono.ink(scheme))
                    Text("macOS no añade apps nuevas automáticamente a esta lista.")
                        .font(.system(size: 12))
                        .foregroundStyle(Mono.muted(scheme))
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                stepRow("1", "Si no ves CleanTrash en la lista, arrastra el icono de arriba directo a la ventana de Ajustes, o haz clic en el botón '+' abajo a la izquierda.")
                stepRow("2", "Selecciona Aplicaciones → CleanTrash.app y activa el interruptor.")
                stepRow("3", "Al estar firmada con tu certificado Developer ID, macOS recordará este permiso incluso después de actualizar.")
            }
            .padding(14)
            .monoCard(radius: 12)

            HStack(spacing: 10) {
                Button("Abrir Ajustes") {
                    appState.openFullDiskAccessSettings()
                }
                .buttonStyle(MonoGhostButtonStyle())

                Button("Ver en Finder") {
                    appState.revealAppBundleInFinder()
                }
                .buttonStyle(MonoGhostButtonStyle())

                Spacer()

                Button("Comprobar") {
                    appState.hasFullDiskAccess = PathSafety.hasFullDiskAccess()
                    if appState.hasFullDiskAccess {
                        appState.report("Acceso total al disco activado")
                        onClose()
                    }
                }
                .buttonStyle(MonoPrimaryButtonStyle())

                Button("Cerrar", action: onClose)
                    .buttonStyle(MonoGhostButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 490)
        .background(Mono.canvas(scheme))
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                if PathSafety.hasFullDiskAccess() {
                    appState.hasFullDiskAccess = true
                    appState.report("Acceso total al disco activado")
                    onClose()
                    break
                }
            }
        }
    }

    private func stepRow(_ num: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(num)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Mono.primaryInk(scheme))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Mono.primaryFill(scheme)))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Mono.ink(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
