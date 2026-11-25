import CleanTrashCore
import SwiftUI

struct MainDashboardView: View {
    @Bindable var appState: AppState
    let onToggleNotch: () -> Void

    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dismissedFDABanner = false
    @State private var showFDAGuide = false
    @State private var hoveredSection: DashboardSection?

    private var activeScheme: ColorScheme {
        appState.preferredColorScheme ?? systemScheme
    }

    private var activeSurface: NotchSurfaceMode {
        appState.settings.notchSurface
    }

    private var ambientAccent: Color? {
        if appState.selectedSection == .notchHub, appState.media.hasActiveTrack {
            return appState.media.palette.primary
        }
        return appState.macHealth.tint(for: activeScheme)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(Mono.hairline(activeScheme))
                .frame(width: 1)
                .ignoresSafeArea()
            mainPane
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(
            DashboardWindowBackground(
                surface: activeSurface,
                scheme: activeScheme,
                ambientAccent: ambientAccent
            )
        )
        .environment(\.notchSurface, activeSurface)
        .preferredColorScheme(appState.preferredColorScheme)
        .sheet(isPresented: $showFDAGuide) {
            FullDiskAccessGuideSheet(appState: appState) {
                showFDAGuide = false
            }
        }
    }

    // MARK: - Collapsible Dynamic Glass Sidebar (Expanded <-> Icon Rail)

    private var isCollapsed: Bool { appState.settings.sidebarCollapsed }

    private var sidebar: some View {
        VStack(alignment: isCollapsed ? .center : .leading, spacing: 0) {
            // Brand header + collapse toggle right below traffic lights
            HStack(spacing: isCollapsed ? 0 : 10) {
                if !isCollapsed {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Mono.primaryFill(activeScheme))
                            .frame(width: 28, height: 28)
                            .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                        Image(systemName: "sparkle")
                            .font(.system(size: 13, weight: .bold))
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
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Mono.muted(activeScheme))
                        .frame(width: 30, height: 30)
                        .background(
                            Capsule()
                                .fill(Mono.ink(activeScheme).opacity(0.08))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(Mono.hairline(activeScheme), lineWidth: 0.75)
                        )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(isCollapsed ? "Expandir barra lateral (⌘\\)" : "Colapsar en iconos (⌘\\)")
            }
            .padding(.top, 38)
            .padding(.horizontal, isCollapsed ? 0 : 14)
            .padding(.bottom, 14)

            // Section list
            VStack(spacing: 4) {
                ForEach(DashboardSection.allCases) { section in
                    sidebarRow(section)
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 8)

            // Footer: Live Vitals (colored like Notch) + Surface & Notch Quick Pills
            if isCollapsed {
                VStack(spacing: 10) {
                    Button {
                        withAnimation(reduceMotion ? .none : Mono.betweenSpring) {
                            appState.settings.notchSurface = activeSurface.next
                        }
                        AppKitHaptics.tap()
                    } label: {
                        Image(systemName: activeSurface.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Mono.gpuAccent)
                            .frame(width: 38, height: 34)
                            .background(Capsule().fill(Mono.ink(activeScheme).opacity(0.09)))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Superficie: \(activeSurface.label)")

                    Button {
                        onToggleNotch()
                        AppKitHaptics.tap()
                    } label: {
                        ZStack {
                            Capsule()
                                .fill(Mono.ink(activeScheme).opacity(0.11))
                                .frame(width: 40, height: 34)
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
                VStack(alignment: .leading, spacing: 9) {
                    // Mini Now Playing strip when Spotify/Apple Music is active
                    if let track = appState.media.track {
                        Button {
                            withAnimation(reduceMotion ? .none : Mono.betweenSpring) {
                                appState.selectedSection = .notchHub
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if let art = appState.media.artwork {
                                    Image(nsImage: art)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 24, height: 24)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                } else {
                                    Image(systemName: "music.note")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Mono.ink(activeScheme))
                                        .frame(width: 24, height: 24)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(Mono.ink(activeScheme).opacity(0.1)))
                                }
                                VStack(alignment: .leading, spacing: 0.5) {
                                    Text(track.title)
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(Mono.ink(activeScheme))
                                        .lineLimit(1)
                                    Text(track.artist)
                                        .font(.system(size: 9))
                                        .foregroundStyle(Mono.muted(activeScheme))
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 2)
                                Button {
                                    appState.media.togglePlayPause()
                                } label: {
                                    Image(systemName: appState.media.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Mono.ink(activeScheme))
                                        .frame(width: 22, height: 22)
                                        .background(Circle().fill(Mono.ink(activeScheme).opacity(0.11)))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.bottom, 2)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()

                        Divider().overlay(Mono.hairline(activeScheme))
                    }

                    HStack(spacing: 5) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(appState.telemetry.memory.pressure == .normal ? Mono.healthy : Mono.caution)
                                .frame(width: 6, height: 6)
                            Text("En vivo")
                                .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                                .foregroundStyle(Mono.muted(activeScheme))
                        }
                        Spacer()

                        // 1-click Dynamic Glass / Liquid Glass / Negro cycle
                        Button {
                            withAnimation(reduceMotion ? .none : Mono.betweenSpring) {
                                appState.settings.notchSurface = activeSurface.next
                            }
                            AppKitHaptics.tap()
                        } label: {
                            Image(systemName: activeSurface.symbol)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(activeSurface.isGlass ? Mono.gpuAccent : Mono.muted(activeScheme))
                                .frame(width: 24, height: 22)
                                .background(Capsule().fill(Mono.ink(activeScheme).opacity(0.09)))
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .help("Superficie: \(activeSurface.label)")

                        Button {
                            onToggleNotch()
                            AppKitHaptics.tap()
                        } label: {
                            Text("Notch")
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Mono.ink(activeScheme))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Mono.ink(activeScheme).opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }

                    VStack(spacing: 6) {
                        miniVital("CPU", pct: appState.telemetry.cpuTotalPercent, tint: Mono.cpuAccent)
                        miniVital("RAM", pct: appState.telemetry.memory.usedPercent, tint: Mono.ramAccent)
                        miniVital("GPU", pct: appState.telemetry.gpu.deviceUtilizationPercent, tint: Mono.gpuAccent)
                    }

                    if appState.totalReclaimedSessionBytes > 0 {
                        HStack {
                            Text("Liberado hoy")
                                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Mono.muted(activeScheme))
                            Spacer()
                            Text(ByteFormat.compact(appState.totalReclaimedSessionBytes))
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(Mono.healthy)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(12)
                .monoCard(radius: 15)
                .padding(12)
            }
        }
        .frame(width: isCollapsed ? 68 : 232)
        .background(
            activeScheme == .dark
                ? Color.black.opacity(activeSurface == .obsidian ? 0.42 : 0.24)
                : Color.white.opacity(0.28)
        )
        .animation(reduceMotion ? .none : Mono.betweenSpring, value: isCollapsed)
    }

    private func sidebarRow(_ section: DashboardSection) -> some View {
        let isSelected = appState.selectedSection == section
        let isHovered = hoveredSection == section
        let badge = badgeText(for: section)
        let isLiveIcon = isSelected || (section == .notchHub && appState.media.isPlaying) || (section == .vault && appState.vault.isUnlocked)
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
                    VStack(spacing: 2) {
                        Icon3D(
                            name: section.icon3D,
                            size: 27,
                            isActive: isLiveIcon,
                            externalHover: isHovered,
                            interactive: false,
                            tiltX: isHovered ? 0.35 : 0
                        )
                        .scaleEffect(isHovered && !reduceMotion ? 1.16 : 1.0)
                        .offset(y: isHovered && !reduceMotion ? -2 : 0)

                        Circle()
                            .fill(isSelected ? Mono.ink(activeScheme).opacity(0.85) : .clear)
                            .frame(width: 4, height: 4)
                    }
                    .frame(width: 46, height: 40)
                    .background(
                        Capsule()
                            .fill(isSelected ? Mono.ink(activeScheme).opacity(0.14) : (isHovered ? Mono.ink(activeScheme).opacity(0.08) : Color.clear))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(isSelected ? Mono.hairlineStrong(activeScheme) : Color.clear, lineWidth: 0.9)
                    )

                    if badge != nil && !isSelected {
                        Circle()
                            .fill(Color(hex: 0xFF4B3A))
                            .frame(width: 7, height: 7)
                            .offset(x: -4, y: 4)
                    }
                }
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 10) {
                    Icon3D(
                        name: section.icon3D,
                        size: 26,
                        isActive: isLiveIcon,
                        externalHover: isHovered,
                        interactive: false,
                        tiltX: isHovered ? 0.32 : 0
                    )
                    .scaleEffect(isHovered && !reduceMotion ? 1.12 : 1.0)
                    .frame(width: 28)

                    Text(section.rawValue)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(Mono.ink(activeScheme).opacity(0.88))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(
                                    Mono.ink(activeScheme).opacity(isSelected ? 0.17 : 0.11)
                                )
                            )
                    }
                }
                .foregroundStyle(Mono.ink(activeScheme).opacity(isSelected ? 1 : (isHovered ? 0.94 : 0.78)))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .frame(height: 39)
                .background(
                    Capsule()
                        .fill(
                            isSelected
                                ? Mono.ink(activeScheme).opacity(activeScheme == .dark ? 0.14 : 0.10)
                                : (isHovered ? Mono.ink(activeScheme).opacity(activeScheme == .dark ? 0.07 : 0.05) : Color.clear)
                        )
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isSelected
                                ? (activeScheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.12))
                                : (isHovered ? Mono.hairline(activeScheme) : Color.clear),
                            lineWidth: 0.9
                        )
                )
                .contentShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? .none : .spring(response: 0.28, dampingFraction: 0.72), value: isHovered)
        .onHover { inside in
            if inside { hoveredSection = section } else if hoveredSection == section { hoveredSection = nil }
        }
        .pointingHandCursor()
        .help(badge.map { "\(section.rawValue) (\($0))" } ?? section.rawValue)
    }

    private func badgeText(for section: DashboardSection) -> String? {
        switch section {
        case .notchHub:
            let shelfCount = appState.productivity.shelfItems.count
            if appState.media.isPlaying { return "♪" }
            return shelfCount > 0 ? "\(shelfCount)" : nil
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

    private func miniVital(_ label: String, pct: Double, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Mono.muted(activeScheme))
                .frame(width: 28, alignment: .leading)
            MonoProgressBar(value: pct / 100.0, height: 4.5, tint: tint)
            Text("\(Int(pct))%")
                .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                .foregroundStyle(Mono.ink(activeScheme))
                .frame(width: 30, alignment: .trailing)
                .contentTransition(.numericText())
        }
    }

    // MARK: - Main Content Pane

    private var mainPane: some View {
        VStack(spacing: 0) {
            // Compact top permission bar (dismissible, glass-styled)
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
                    if banner.contains("Grabación de pantalla") {
                        Button("Abrir Ajustes") {
                            VisionTextCapture.openScreenRecordingSettings()
                        }
                        .buttonStyle(MonoGhostButtonStyle())
                    } else if appState.statusTone == .error, banner.contains("Acceso total") || banner.contains("Automatización") {
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
                            : appState.statusTone.color.opacity(activeScheme == .dark ? 0.14 : 0.15))
                .overlay(alignment: .bottom) {
                    Divider().overlay(Mono.hairline(activeScheme))
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: banner) {
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
                case .notchHub:
                    NotchHubView(appState: appState, onToggleNotch: onToggleNotch)
                case .vault:
                    VaultView(appState: appState)
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
            .monoCard(radius: 14)

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
                .font(.system(size: 11, weight: .bold).monospacedDigit())
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
