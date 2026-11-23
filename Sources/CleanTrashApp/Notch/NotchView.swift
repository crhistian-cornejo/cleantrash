import CleanTrashCore
import SwiftUI

enum NotchTab: String, CaseIterable, Identifiable {
    case vitals = "Estado"
    case dev = "Dev"
    case unused = "Apps"
    case actions = "Acciones"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .vitals: return "waveform.path.ecg"
        case .dev: return "terminal"
        case .unused: return "app.dashed"
        case .actions: return "bolt"
        }
    }
}

struct NotchRootView: View {
    @Bindable var appState: AppState
    @Bindable var coordinator: NotchCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedTab: NotchTab

    init(appState: AppState, coordinator: NotchCoordinator, initialTab: NotchTab = .vitals) {
        self.appState = appState
        self.coordinator = coordinator
        _selectedTab = State(initialValue: initialTab)
    }
    @Namespace private var tabNamespace
    /// Destructive actions need a second tap within 3 s (prevents accidental cleans from a stray hover-click).
    @State private var armedAction: String?
    @State private var armTask: Task<Void, Never>?

    private var isIsland: Bool { appState.settings.notchStyle == .island }
    private var hasNotice: Bool { appState.activeNotice != nil && !coordinator.isExpanded }

    private var targetWidth: CGFloat {
        if coordinator.isExpanded { return 488 }
        if hasNotice { return NotchCoordinator.noticeWidth }
        if appState.settings.showLiveNotchEars {
            return coordinator.closedWidth + 144
        }
        return coordinator.closedWidth
    }

    /// header + tab bar (8 + 32 + 12) + 2×104 tiles + 10 gap + 16 bottom padding.
    static func expandedHeight(headerHeight: CGFloat, isIsland: Bool) -> CGFloat {
        headerHeight + (isIsland ? 6 : 0) + 52 + 218 + 16
    }

    private var targetHeight: CGFloat {
        if coordinator.isExpanded {
            return Self.expandedHeight(headerHeight: headerHeight, isIsland: isIsland)
                + (coordinator.detail?.extraHeight ?? 0)
        }
        if hasNotice { return coordinator.closedHeight + 60 }
        return coordinator.closedHeight
    }

    private var currentShape: NotchShape {
        NotchShape(
            topShoulderRadius: coordinator.isExpanded ? 14 : 8,
            bottomCornerRadius: coordinator.isExpanded ? 22 : (isIsland ? 14 : 11),
            isIsland: isIsland,
            closeTopEdge: true
        )
    }

    private var currentOutlineShape: NotchShape {
        NotchShape(
            topShoulderRadius: coordinator.isExpanded ? 14 : 8,
            bottomCornerRadius: coordinator.isExpanded ? 22 : (isIsland ? 14 : 11),
            isIsland: isIsland,
            closeTopEdge: isIsland
        )
    }

    var body: some View {
        let shape = currentShape
        let outlineShape = currentOutlineShape
        ZStack(alignment: .top) {
            Color.clear

            VStack(spacing: 0) {
                if coordinator.isExpanded {
                    expandedContent
                        .transition(.opacity.combined(with: .offset(y: -4)))
                } else if let notice = appState.activeNotice {
                    noticeContent(notice)
                        .transition(.opacity)
                } else {
                    idleContent
                }
            }
            .frame(width: targetWidth, height: targetHeight, alignment: .top)
            .background(
                shape
                    .fill(Color(hex: 0x050505))
                    .overlay(
                        outlineShape.stroke(
                            Color.white.opacity(coordinator.isExpanded || hasNotice ? 0.14 : 0.06),
                            lineWidth: 1
                        )
                    )
                    .shadow(
                        color: .black.opacity(coordinator.isExpanded || hasNotice ? 0.55 : 0.0),
                        radius: coordinator.isExpanded ? 26 : 12,
                        y: coordinator.isExpanded ? 12 : 4
                    )
            )
            .clipShape(shape)
            .animation(
                reduceMotion ? .none : (coordinator.isExpanded ? Mono.openingSpring : Mono.foldingSpring),
                value: coordinator.isExpanded
            )
            .animation(reduceMotion ? .none : Mono.betweenSpring, value: appState.activeNotice?.id)
        }
        .frame(width: coordinator.stageWidth, height: coordinator.stageHeight, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Idle Hardware Ears

    private var idleContent: some View {
        HStack(spacing: 0) {
            if appState.settings.showLiveNotchEars {
                // Left Ear: live activity spinner while working, otherwise RAM %
                HStack(spacing: 4) {
                    if appState.activityLabel != nil {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                            .scaleEffect(0.7)
                            .frame(width: 10, height: 10)
                        Text(activityShort)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else {
                        Circle()
                            .fill(memoryDotColor)
                            .frame(width: 4.5, height: 4.5)
                        Text("RAM \(Int(appState.telemetry.memory.usedPercent))%")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.82))
                            .contentTransition(.numericText())
                    }
                }
                .frame(width: 68, alignment: .leading)
                .padding(.leading, 14)
                .animation(Mono.betweenSpring, value: appState.activityLabel)

                Spacer(minLength: coordinator.closedWidth - 16)

                // Right Ear: GPU % or Reclaimable Dev Badge
                HStack(spacing: 4) {
                    if appState.reclaimableDevBytes >= 1_000_000_000 {
                        Text(ByteFormat.compact(appState.reclaimableDevBytes))
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                    } else {
                        Text("GPU \(Int(appState.telemetry.gpu.deviceUtilizationPercent))%")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.82))
                            .contentTransition(.numericText())
                    }
                }
                .frame(width: 68, alignment: .trailing)
                .padding(.trailing, 14)
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var activityShort: String {
        guard let label = appState.activityLabel else { return "" }
        let word = label.split(separator: " ").first.map(String.init) ?? label
        return word.replacingOccurrences(of: "…", with: "")
    }

    private var memoryDotColor: Color {
        switch appState.telemetry.memory.pressure {
        case .normal: return Color.white.opacity(0.45)
        case .critical: return Mono.danger
        default: return Mono.caution
        }
    }

    // MARK: - Live Notice Toast

    private func noticeContent(_ notice: NotchNotice) -> some View {
        VStack(spacing: 6) {
            Spacer().frame(height: isIsland ? 10 : coordinator.closedHeight + 4)
            HStack(spacing: 10) {
                Image(systemName: noticeIcon(notice.kind))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(noticeTint(notice.kind))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(noticeTint(notice.kind).opacity(0.18)))
                    .symbolEffect(.bounce, value: notice.id)

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(notice.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(notice.subtitle)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(notice.subtitle)
                }

                Spacer(minLength: 4)

                if let action = notice.primaryActionTitle {
                    Button(action) {
                        appState.handleNoticePrimaryAction(notice)
                    }
                    .font(.system(size: 10.5, weight: .bold))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.white))
                    .buttonStyle(NotchPressStyle())
                }

                Button {
                    appState.dismissNotice()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
    }

    private func noticeIcon(_ kind: NotchNoticeKind) -> String {
        switch kind {
        case .devBloat: return "terminal"
        case .highMemory: return "memorychip"
        case .unusedApp: return "app.dashed"
        case .cleaned: return "checkmark"
        case .warning: return "exclamationmark"
        case .failed: return "xmark"
        case .heavyCPU: return "flame.fill"
        }
    }

    private func noticeTint(_ kind: NotchNoticeKind) -> Color {
        switch kind {
        case .cleaned: return Mono.healthy
        case .warning, .highMemory, .heavyCPU: return Mono.caution
        case .failed: return Mono.danger
        case .devBloat, .unusedApp: return .white
        }
    }

    /// Two-step confirm for destructive notch actions: first tap arms, second tap (within 3 s) runs.
    private func confirmOrArm(_ key: String, action: @escaping () -> Void) {
        if armedAction == key {
            armTask?.cancel()
            armedAction = nil
            action()
            return
        }
        withAnimation(Mono.betweenSpring) { armedAction = key }
        armTask?.cancel()
        armTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(Mono.betweenSpring) { armedAction = nil }
        }
    }

    // MARK: - Expanded Monochrome Control Shelf

    private var expandedContent: some View {
        VStack(spacing: 0) {
            expandedHeader
            if let detail = coordinator.detail {
                NotchDetailView(appState: appState, coordinator: coordinator, detail: detail)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                        removal: .opacity
                    ))
            } else {
            tabBar
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .transition(.opacity)

            // Tab Body
            Group {
                switch selectedTab {
                case .vitals:
                    vitalsTab
                case .dev:
                    devTab
                case .unused:
                    unusedTab
                case .actions:
                    quickActionsTab
                }
            }
            .id(selectedTab)
            .transition(.opacity.combined(with: .offset(y: 3)))
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .animation(reduceMotion ? .none : Mono.openingSpring, value: coordinator.detail)
    }

    private func openDetail(_ detail: NotchDetail) {
        withAnimation(reduceMotion ? .none : Mono.openingSpring) {
            coordinator.detail = detail
        }
    }

    /// On a real notch the header sits in the two "wings" beside the camera housing (like the Dynamic
    /// Island), so the camera never eats a row of content. Island mode uses a normal single row.
    private var usesCameraWings: Bool { coordinator.geometry.hasHardwareNotch && !isIsland }

    private var headerHeight: CGFloat { usesCameraWings ? max(coordinator.closedHeight, 28) : 40 }

    private var expandedHeader: some View {
        HStack(spacing: 0) {
            // Left wing: brand
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: appState.activityLabel != nil && !reduceMotion)
                Text("CLEANTRASH")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if usesCameraWings {
                Color.clear.frame(width: coordinator.closedWidth + 8)
            }

            // Right wing: live status + open dashboard
            HStack(spacing: 6) {
                if appState.activityLabel != nil {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini).tint(.white).scaleEffect(0.65).frame(width: 10, height: 10)
                        Text(activityShort)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .help(appState.activityLabel ?? "")
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else if appState.totalReclaimedSessionBytes > 0 {
                    Text("+\(ByteFormat.compact(appState.totalReclaimedSessionBytes))")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Mono.healthy)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Mono.healthy.opacity(0.16)))
                        .help("Liberado en esta sesión")
                        .transition(.opacity)
                }

                Button {
                    coordinator.isExpanded = false
                    appState.onOpenMainWindow?()
                } label: {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                        .contentShape(Circle())
                }
                .buttonStyle(NotchPressStyle())
                .help("Abrir el panel de CleanTrash")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .animation(Mono.betweenSpring, value: appState.activityLabel)
        }
        .frame(height: headerHeight)
        .padding(.horizontal, 22)
        .padding(.top, isIsland ? 6 : 0)
    }

    /// Full-width segmented control: equal segments, one line each, sliding selection pill.
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(NotchTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button {
                    guard selectedTab != tab else { return }
                    withAnimation(reduceMotion ? .none : Mono.betweenSpring) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                        if let badge = tabBadge(tab) {
                            Text(badge)
                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(isSelected ? Color.white : Color.black)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(isSelected ? Color.black.opacity(0.75) : Color.white.opacity(0.85)))
                                .fixedSize()
                        }
                    }
                    .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.62))
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Color.white)
                                .matchedGeometryEffect(id: "notchTabPill", in: tabNamespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }

    /// 4 rows fit the shelf exactly; with more items show 3 + a "see all" link.
    private var devRowLimit: Int { appState.devArtifacts.count > 4 ? 3 : 4 }

    private func tabBadge(_ tab: NotchTab) -> String? {
        switch tab {
        case .dev:
            let count = appState.devArtifacts.filter { !$0.isActiveBuild }.count
            return count > 0 ? "\(count)" : nil
        case .unused:
            return appState.unusedApps.isEmpty ? nil : "\(appState.unusedApps.count)"
        default:
            return nil
        }
    }

    private func notchEmptyState(icon: String, title: String, subtitle: String, busy: Bool = false) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            ZStack {
                Circle().fill(Color.white.opacity(0.06)).frame(width: 44, height: 44)
                if busy {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Mono.healthy)
                }
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.5))
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tab 1: Live Vitals (Uniform 2x2 Swiss Bento Grid)

    private var vitalsTab: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                // Top-Left: RAM Card with Optimize action
                notchMetricTile(
                    icon: "memorychip",
                    title: "MEMORIA",
                    value: "\(Int(appState.telemetry.memory.usedPercent))%",
                    detail: "\(ByteFormat.memory(appState.telemetry.memory.usedBytes)) / \(ByteFormat.memory(appState.telemetry.memory.totalBytes)) · \(appState.telemetry.memory.pressure.label)",
                    progress: appState.telemetry.memory.usedPercent / 100.0,
                    actionTitle: appState.isOptimizingRAM ? "Liberando…" : "Optimizar",
                    isDisabled: appState.isOptimizingRAM,
                    onOpen: { openDetail(.memory) }
                ) {
                    Task { await appState.optimizeRAM() }
                }

                // Top-Right: GPU Card with Trim action
                notchMetricTile(
                    icon: "cpu.fill",
                    title: "GPU · \(appState.telemetry.gpu.modelName)",
                    value: "\(Int(appState.telemetry.gpu.deviceUtilizationPercent))%",
                    detail: "En uso \(ByteFormat.memory(appState.telemetry.gpu.inUseMemoryBytes)) · Asignada \(ByteFormat.memory(appState.telemetry.gpu.allocatedMemoryBytes))",
                    progress: appState.telemetry.gpu.deviceUtilizationPercent / 100.0,
                    actionTitle: "Limpiar caché",
                    isDisabled: appState.isCleaning,
                    onOpen: { openDetail(.gpu) }
                ) {
                    Task { await appState.trimGPUCaches() }
                }
            }

            GridRow {
                // Bottom-Left: Disk Card
                notchMetricTile(
                    icon: "internaldrive",
                    title: appState.telemetry.disk.volumeName.uppercased(),
                    value: ByteFormat.compact(appState.telemetry.disk.availableBytes),
                    detail: "de \(ByteFormat.compact(appState.telemetry.disk.totalBytes)) · basura \(ByteFormat.compact(appState.totalSmartReclaimableBytes))",
                    progress: appState.telemetry.disk.usedPercent / 100.0,
                    actionTitle: armedAction == "smartClean"
                        ? "¿Borrar \(ByteFormat.compact(appState.totalSmartReclaimableBytes))?"
                        : (appState.isCleaning ? "Limpiando…" : "Limpiar"),
                    isDisabled: appState.isCleaning || appState.totalSmartReclaimableBytes == 0,
                    isArmed: armedAction == "smartClean",
                    onOpen: { openDetail(.disk) }
                ) {
                    confirmOrArm("smartClean") {
                        Task { await appState.runSmartClean() }
                    }
                }

                // Bottom-Right: CPU with one-tap relief for whatever is hogging it
                notchMetricTile(
                    icon: "cpu",
                    title: "CPU · \(appState.telemetry.thermalState.uppercased())",
                    value: "\(Int(appState.telemetry.cpuTotalPercent))%",
                    detail: cpuTileDetail,
                    progress: appState.telemetry.cpuTotalPercent / 100.0,
                    progressTint: appState.isCPUOverloaded ? Mono.danger : nil,
                    actionTitle: cpuTileActionTitle,
                    isDisabled: false,
                    onOpen: { openDetail(.cpu) }
                ) {
                    openDetail(.cpu)
                }
            }
        }
    }

    private var cpuTileDetail: String {
        let sim = appState.telemetry.simulatorLoad
        if sim.cpuPercent >= 50 {
            return "Simuladores \(Int(sim.cpuPercent))% · carga \(Int(appState.telemetry.loadAverage))"
        }
        if let top = appState.visibleCPUProcesses.first {
            return "\(top.name) \(Int(top.cpuPercent))% · carga \(Int(appState.telemetry.loadAverage))"
        }
        return "Carga \(Int(appState.telemetry.loadAverage)) · \(appState.telemetry.processCount) procesos"
    }

    private var cpuTileActionTitle: String {
        let heavy = appState.heavyCPUProcesses.count
        if appState.telemetry.simulatorLoad.cpuPercent >= 50 { return "Ver simuladores" }
        if heavy > 0 { return "\(heavy) pesada\(heavy == 1 ? "" : "s")" }
        return "Procesos"
    }

    private func notchMetricTile(
        icon: String,
        title: String,
        value: String,
        detail: String,
        progress: Double,
        progressTint: Color? = nil,
        actionTitle: String,
        isDisabled: Bool = false,
        isArmed: Bool = false,
        onOpen: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
                Text(title)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .lineLimit(1)
                Spacer()
                if onOpen != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.4))
                }
            }

            HStack(alignment: .center, spacing: 6) {
                Text(value)
                    .font(.system(size: 19, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .contentTransition(.numericText())
                Spacer(minLength: 4)
                Button(actionTitle, action: action)
                    .font(.system(size: 10, weight: .bold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(isArmed ? Color.white : Color.black)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(isArmed ? Mono.danger : Color.white))
                    .opacity(isDisabled && !isArmed ? 0.4 : 1)
                    .buttonStyle(.plain)
                    .disabled(isDisabled && !isArmed)
                    .contentTransition(.interpolate)
            }

            NotchBar(value: progress, tint: progressTint ?? .white)

            Spacer(minLength: 0)

            Text(detail)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.72))
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 104, maxHeight: 104, alignment: .topLeading)
        .modifier(NotchTileChrome(onOpen: onOpen))
    }

    // MARK: - Tab 2: Live Dev Radar (Cargo target/, node_modules/, Swift .build/)

    private var devTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PROYECTOS · \(ByteFormat.compact(appState.reclaimableDevBytes)) RECUPERABLES")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.65))
                Spacer()
                Button(appState.isScanningDev ? "Buscando…" : "Buscar") {
                    Task { await appState.scanDevArtifacts() }
                }
                .buttonStyle(MonoGhostButtonStyle())
                .disabled(appState.isScanningDev)

                Button(armedAction == "devAll" ? "¿Confirmar?" : "Limpiar todo") {
                    confirmOrArm("devAll") {
                        Task { await appState.cleanSelectedDevArtifacts() }
                    }
                }
                .buttonStyle(MonoPrimaryButtonStyle())
                .disabled(appState.reclaimableDevBytes == 0 || appState.isCleaning)
            }

            if appState.devArtifacts.isEmpty {
                notchEmptyState(
                    icon: "checkmark",
                    title: appState.isScanningDev ? "Buscando proyectos…" : "Proyectos ligeros",
                    subtitle: appState.isScanningDev ? "target/ · node_modules/ · .build/" : "No hay compilaciones pesadas que borrar",
                    busy: appState.isScanningDev
                )
            } else {
                VStack(spacing: 6) {
                        ForEach(appState.devArtifacts.prefix(devRowLimit)) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.ecosystem.symbolName)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.white.opacity(0.7))
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(item.projectName)
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Text(item.artifactKind)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(Color.white.opacity(0.55))
                                        if item.isActiveBuild {
                                            MonoTag(text: "EN USO", inverted: true)
                                        }
                                    }
                                    Text("Sin tocar \(ByteFormat.relativeAge(item.lastModified))")
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(Color.white.opacity(0.45))
                                }

                                Spacer()

                                Text(ByteFormat.compact(item.sizeBytes))
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white)

                                Button {
                                    Task { await appState.cleanSingleDevArtifact(item) }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(item.isActiveBuild ? Color.white.opacity(0.25) : Color.white.opacity(0.85))
                                        .frame(width: 24, height: 24)
                                        .background(Circle().fill(Color.white.opacity(0.08)))
                                }
                                .buttonStyle(.plain)
                                .disabled(item.isActiveBuild || appState.isCleaning)
                                .help(item.isActiveBuild ? "Compilación en uso: no se puede borrar" : "Borrar \(item.artifactKind)")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.045)))
                        }

                        if appState.devArtifacts.count > devRowLimit {
                            Button {
                                coordinator.isExpanded = false
                                appState.selectedSection = .devRadar
                                appState.onOpenMainWindow?()
                            } label: {
                                Text("+\(appState.devArtifacts.count - devRowLimit) más · Ver todo en Dev Radar")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.white.opacity(0.55))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                }
            }
        }
    }

    // MARK: - Tab 3: Unused Apps Quick Triage

    private var unusedTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(appState.unusedApps.isEmpty ? "APPS SIN USAR" : "\(appState.unusedApps.count) SIN USAR > \(appState.settings.unusedAppThresholdDays) DÍAS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.65))
                Spacer()
                Button("Ver todas") {
                    coordinator.isExpanded = false
                    appState.selectedSection = .appsAudit
                    appState.onOpenMainWindow?()
                }
                .buttonStyle(MonoGhostButtonStyle())
            }

            if let candidate = appState.unusedApps.first {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.appPath))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 42, height: 42)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("¿Aún usas \(candidate.name)?")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("\(ByteFormat.relativeAge(candidate.lastUsedDate)) · \(ByteFormat.compact(candidate.totalSizeBytes))")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.72))
                                .lineLimit(2)
                        }
                    }

                    HStack(spacing: 8) {
                        Button("La uso") {
                            withAnimation(Mono.betweenSpring) {
                                appState.markAppDecision(candidate, decision: .keep)
                            }
                        }
                        .buttonStyle(MonoGhostButtonStyle())

                        Button("Luego") {
                            withAnimation(Mono.betweenSpring) {
                                appState.markAppDecision(candidate, decision: .snoozed, snoozeDays: 30)
                            }
                        }
                        .buttonStyle(MonoGhostButtonStyle())

                        Spacer()

                        Button {
                            Task { await appState.deepUninstallApp(candidate) }
                        } label: {
                            Label("Eliminar", systemImage: "touchid")
                        }
                        .buttonStyle(MonoPrimaryButtonStyle())
                        .disabled(appState.isCleaning)
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.055)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            } else {
                notchEmptyState(
                    icon: "checkmark",
                    title: appState.isAuditingApps ? "Revisando apps…" : "Todo en uso",
                    subtitle: appState.isAuditingApps
                        ? "Midiendo último uso de cada app"
                        : "Ninguna app lleva más de \(appState.settings.unusedAppThresholdDays) días sin abrirse",
                    busy: appState.isAuditingApps
                )
            }
        }
    }

    // MARK: - Tab 4: Quick Actions

    private var quickActionsTab: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            quickActionTile("Analizar Mac", subtitle: "Dev + Basura + Apps", icon: "magnifyingglass") {
                Task { await appState.runSmartScan() }
            }
            quickActionTile("Optimizar RAM", subtitle: appState.isOptimizingRAM ? "Liberando…" : "Liberar caché inactiva", icon: "memorychip", isDisabled: appState.isOptimizingRAM) {
                Task { await appState.optimizeRAM() }
            }
            quickActionTile(
                armedAction == "trash" ? "¿Vaciar ya?" : "Vaciar Papelera",
                subtitle: trashSubtitle,
                icon: "trash.slash",
                isDisabled: appState.isCleaning,
                isArmed: armedAction == "trash"
            ) {
                confirmOrArm("trash") {
                    Task { await appState.emptyTrashNow() }
                }
            }
            quickActionTile("Limpiar GPU", subtitle: "Shaders Metal y WebGPU", icon: "sparkles", isDisabled: appState.isCleaning) {
                Task { await appState.trimGPUCaches() }
            }
            quickActionTile("Mapa de Disco", subtitle: "Ver carpetas grandes", icon: "chart.pie") {
                coordinator.isExpanded = false
                appState.selectedSection = .diskMap
                appState.onOpenMainWindow?()
                if appState.diskRoot == nil {
                    Task { await appState.mapDisk() }
                }
            }
            quickActionTile("Snapshots APFS", subtitle: "Reducir copias locales", icon: "clock.arrow.circlepath") {
                Task { await appState.thinAPFSSnapshots() }
            }
        }
    }

    private var trashSubtitle: String {
        let trash = appState.trashContents
        if !trash.readable { return "Se vaciará con Finder" }
        if trash.itemCount == 0 { return "Ya está vacía" }
        return "\(ByteFormat.compact(trash.totalBytes)) · \(trash.itemCount) \(trash.itemCount == 1 ? "elemento" : "elementos")"
    }

    private func quickActionTile(
        _ title: String,
        subtitle: String,
        icon: String,
        isDisabled: Bool = false,
        isArmed: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(isArmed ? Mono.danger : Color.white.opacity(0.14)))

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.68))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color(hex: 0x121212)))
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(isArmed ? Mono.danger.opacity(0.8) : Color.white.opacity(0.14), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11))
            .opacity(isDisabled && !isArmed ? 0.45 : 1)
        }
        .buttonStyle(NotchPressStyle())
        .disabled(isDisabled && !isArmed)
    }
}

/// Subtle press-down feedback for notch tiles.
private struct NotchPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? 0.06 : 0)
            .animation(Mono.fast, value: configuration.isPressed)
    }
}

/// Tile background that lights up on hover and opens the drill-down when tapped anywhere outside its button.
private struct NotchTileChrome: ViewModifier {
    let onOpen: (() -> Void)?
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(hex: hovering && onOpen != nil ? 0x1A1A1A : 0x121212))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(hovering && onOpen != nil ? 0.28 : 0.14), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onHover { inside in
                withAnimation(Mono.fast) { hovering = inside }
            }
            .onTapGesture { onOpen?() }
            .scaleEffect(hovering && onOpen != nil ? 1.01 : 1)
            .animation(Mono.fast, value: hovering)
    }
}

/// Thin progress bar for dark notch surfaces, optionally tinted (red when the CPU is overloaded).
private struct NotchBar: View {
    let value: Double
    var tint: Color = .white

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule().fill(tint)
                    .frame(width: max(0, geo.size.width * min(1, max(0, value))))
                    .animation(Mono.betweenSpring, value: value)
            }
        }
        .frame(height: 4.5)
    }
}
