import CleanTrashCore
import SwiftUI
import UniformTypeIdentifiers

enum NotchTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case shelf = "Bandeja"
    case cleaner = "Limpiar"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .shelf: return "tray.fill"
        case .cleaner: return "sparkles"
        }
    }

    var glassIcon: Icon3DName {
        switch self {
        case .home: return .notch
        case .shelf: return .trash
        case .cleaner: return .smartcare
        }
    }

    /// Tailored inner content height per tab so each view matches Droppy's sleek proportions.
    var bodyHeight: CGFloat {
        switch self {
        case .home: return 154
        case .shelf: return 224
        case .cleaner: return 226
        }
    }
}

struct NotchRootView: View {
    @Bindable var appState: AppState
    @Bindable var coordinator: NotchCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(appState: AppState, coordinator: NotchCoordinator, initialTab: NotchTab? = nil) {
        self.appState = appState
        self.coordinator = coordinator
        if let initialTab {
            coordinator.selectedTab = initialTab
        }
    }
    @Namespace private var dockNamespace
    /// Destructive actions need a second tap within 3 s (prevents accidental cleans from a stray hover-click).
    @State private var armedAction: String?
    @State private var armTask: Task<Void, Never>?
    @State private var hoveredTab: NotchTab?
    @State private var hoveredUtility: String?

    private var isIsland: Bool { appState.settings.notchStyle == .island }
    private var surface: NotchSurfaceMode { appState.settings.notchSurface }
    private var hasNotice: Bool { appState.activeNotice != nil && !coordinator.isExpanded && !hasHUD }
    /// Volume / brightness overlay riding the closed notch.
    private var hasHUD: Bool { appState.hud.current != nil && !coordinator.isExpanded && appState.agents.pending.isEmpty }
    /// An agent is waiting for Allow / Deny: the closed notch grows into a permission card.
    private var hasPermission: Bool { !appState.agents.pending.isEmpty && !coordinator.isExpanded }

    private var ambientAccent: Color? {
        guard appState.media.hasActiveTrack, coordinator.selectedTab == .home else { return nil }
        return appState.media.palette.primary
    }

    /// Only expand closed ears when there is live activity (Music, Agents, Focus Timer, or CleanTrash task).
    /// System vitals (RAM/CPU/GPU) now live cleanly in the macOS Menu Bar icon bar instead of crowding the closed notch.
    private var hasLiveClosedEars: Bool {
        guard appState.settings.showLiveNotchEars else { return false }
        if appState.activityLabel != nil { return true }
        if !appState.agents.earStack.isEmpty { return true }
        if showsMusicInEars { return true }
        if appState.productivity.isTimerRunning { return true }
        return false
    }

    /// The closed notch hands music over to the floating player while that one is on screen.
    private var showsMusicInEars: Bool {
        appState.settings.showMusicInNotchEars && appState.media.hasActiveTrack
            && !appState.productivity.floatingPlayer.isShown
    }

    /// Breathing room between ear content and the camera housing.
    private static let cameraGap: CGFloat = 12

    private var targetWidth: CGFloat {
        if coordinator.isExpanded { return coordinator.expandedWidth(for: appState.settings.homeWidgets) }
        if hasPermission { return NotchCoordinator.permissionWidth }
        if hasHUD { return coordinator.closedWidth + 2 * NotchCoordinator.earWidth }
        if hasNotice { return NotchCoordinator.noticeWidth }
        if hasLiveClosedEars {
            return coordinator.closedWidth + 2 * NotchCoordinator.earWidth
        }
        return coordinator.closedWidth
    }

    /// Horizontal content inset of the open notch: generous 20 pt concave shoulders need clear breathing room.
    static let sideInset: CGFloat = 28

    /// header + content body + bottom breathing room (navigation floats in the Droppy capsule dock below!).
    static func expandedHeight(
        headerHeight: CGFloat,
        isIsland: Bool,
        bodyHeight: CGFloat = 154
    ) -> CGFloat {
        headerHeight + (isIsland ? 8 : 4) + bodyHeight + 16
    }

    private var targetHeight: CGFloat {
        if coordinator.isExpanded {
            return Self.expandedHeight(
                headerHeight: headerHeight,
                isIsland: isIsland,
                bodyHeight: coordinator.detail == nil ? coordinator.selectedTab.bodyHeight : 230
            ) + coordinator.extraExpandedHeight
        }
        if hasPermission { return coordinator.closedHeight + permissionCardHeight }
        if hasNotice { return coordinator.closedHeight + 60 }
        return coordinator.closedHeight
    }

    private var currentShape: NotchShape {
        NotchShape(
            topShoulderRadius: coordinator.isExpanded ? 20 : 9,
            bottomCornerRadius: coordinator.isExpanded ? 28 : (isIsland ? 15 : 12),
            isIsland: isIsland,
            closeTopEdge: true
        )
    }

    private var currentOutlineShape: NotchShape {
        NotchShape(
            topShoulderRadius: coordinator.isExpanded ? 20 : 9,
            bottomCornerRadius: coordinator.isExpanded ? 28 : (isIsland ? 15 : 12),
            isIsland: isIsland,
            closeTopEdge: isIsland
        )
    }

    var body: some View {
        let shape = currentShape
        let outlineShape = currentOutlineShape
        ZStack(alignment: .top) {
            Color.clear

            VStack(spacing: 10) {
                // Main Notch / Island Shell (top-to-bottom native Liquid Glass or deep jet black)
                VStack(spacing: 0) {
                    if coordinator.isExpanded {
                        expandedContent
                            .transition(.opacity.combined(with: .offset(y: -4)))
                    } else if let request = appState.agents.pending.first {
                        permissionContent(request)
                            .transition(.opacity)
                    } else if hasHUD, let hud = appState.hud.current {
                        NotchSystemHUDView(
                            event: hud,
                            earWidth: NotchCoordinator.earWidth,
                            sidePad: 23,
                            cameraGap: Self.cameraGap
                        )
                        .transition(.opacity)
                    } else if let notice = appState.activeNotice {
                        noticeContent(notice)
                            .transition(.opacity)
                    } else {
                        idleContent
                    }
                }
                .frame(width: targetWidth, height: targetHeight, alignment: .top)
                .background(
                    NotchSurfaceBackground(
                        shape: shape,
                        outlineShape: outlineShape,
                        surface: surface,
                        isExpanded: coordinator.isExpanded,
                        isIsland: isIsland,
                        hasToast: hasNotice || hasPermission,
                        hasHardwareNotch: coordinator.geometry.hasHardwareNotch,
                        ambientAccent: ambientAccent
                    )
                )
                .clipShape(shape)
                .onDrop(of: [.fileURL], isTargeted: Binding(
                    get: { appState.productivity.isDragOverNotch },
                    set: { targeting in
                        appState.productivity.isDragOverNotch = targeting
                        if targeting && !coordinator.isExpanded {
                            withAnimation(Mono.openingSpring) {
                                coordinator.selectedTab = .shelf
                                coordinator.productivitySubTab = .shelf
                                coordinator.isExpanded = true
                            }
                        }
                    }
                )) { providers in
                    handleNotchFileDrop(providers: providers)
                }

                // Droppy Detached Floating Native Liquid Glass Capsule Dock (Images 1 & 2!)
                if coordinator.isExpanded {
                    floatingCapsuleDock
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.88, anchor: .top)).combined(with: .offset(y: -8)),
                            removal: .opacity.combined(with: .offset(y: -6))
                        ))
                }
            }
            .animation(
                reduceMotion ? .none : (coordinator.isExpanded ? Mono.openingSpring : Mono.foldingSpring),
                value: coordinator.isExpanded
            )
            .animation(reduceMotion ? .none : Mono.openingSpring, value: coordinator.selectedTab)
            .animation(reduceMotion ? .none : Mono.openingSpring, value: coordinator.showLyricsTheater)
            .animation(reduceMotion ? .none : Mono.openingSpring, value: coordinator.isEditingWidgets)
            .animation(reduceMotion ? .none : Mono.openingSpring, value: appState.settings.homeWidgets)
            .animation(reduceMotion ? .none : Mono.betweenSpring, value: surface)
            .animation(reduceMotion ? .none : Mono.betweenSpring, value: isIsland)
            .animation(reduceMotion ? .none : Mono.betweenSpring, value: appState.activeNotice?.id)
            .animation(reduceMotion ? .none : Mono.betweenSpring, value: appState.hud.current == nil)
            .animation(reduceMotion ? .none : Mono.betweenSpring, value: appState.agents.pending.first?.id)
        }
        .frame(width: coordinator.stageWidth, height: coordinator.stageHeight, alignment: .top)
        .environment(\.colorScheme, .dark)
        .environment(\.notchSurface, surface)
        .onChange(of: coordinator.isExpanded) { _, expanded in
            // Opening while an agent waits lands on Home (where the Agents widget lives).
            if expanded && !appState.agents.pending.isEmpty { coordinator.selectedTab = .home }
        }
    }

    private func handleNotchFileDrop(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let direct = item as? URL {
                        url = direct
                    } else {
                        url = nil
                    }
                    if let url {
                        Task { @MainActor in
                            appState.productivity.addFiles([url])
                            withAnimation(Mono.openingSpring) {
                                coordinator.selectedTab = .shelf
                                coordinator.productivitySubTab = .shelf
                                coordinator.isExpanded = true
                            }
                        }
                    }
                }
            }
        }
        return accepted
    }

    // MARK: - Idle Hardware Ears (Music · Agents · Timer · Task; System Stats live in Menu Bar)

    private var idleContent: some View {
        let sidePad: CGFloat = 23 // +5 pt extra breathing room on each outer side
        return HStack(spacing: 0) {
            if hasLiveClosedEars {
                let stack = appState.agents.earStack
                let showMusic = showsMusicInEars

                // Left ear: CleanTrash active task → Music artwork + track title → Agent stack → Timer
                Group {
                    if appState.activityLabel != nil {
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.white)
                                .scaleEffect(0.7)
                                .frame(width: 10, height: 10)
                            Text(activityShort)
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        .transition(.opacity)
                    } else if showMusic, let track = appState.media.track {
                        let marqueeLabel = track.artist.isEmpty ? track.title : "\(track.title)  —  \(track.artist)"
                        HStack(spacing: 6) {
                            Group {
                                if let art = appState.media.artwork {
                                    Image(nsImage: art)
                                        .resizable()
                                        .interpolation(.high)
                                        .aspectRatio(contentMode: .fill)
                                } else {
                                    LinearGradient(
                                        colors: [appState.media.palette.primary, appState.media.palette.secondary],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                    .overlay {
                                        Image(systemName: "music.note")
                                            .font(.system(size: 8.5, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                            }
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                    .strokeBorder(.white.opacity(0.24), lineWidth: 0.6)
                            )

                            MarqueeText(
                                text: marqueeLabel,
                                font: .system(size: 10.5, weight: .semibold),
                                color: .white.opacity(0.92),
                                speed: 22
                            )

                            // If an Agent occupies the right ear, keep the animated waveform visible right here!
                            if !stack.isEmpty {
                                AudioVisualizerBars(
                                    isPlaying: appState.media.isPlaying,
                                    color: appState.media.palette.primary,
                                    secondaryColor: appState.media.palette.secondary,
                                    barCount: 3,
                                    maxHeight: 11,
                                    barWidth: 1.8
                                )
                            }
                        }
                        .transition(.opacity)
                    } else if !stack.isEmpty {
                        // No music: the agent logos move to the left ear, their live activity stays on the right.
                        NotchAgentsEar(stack: stack, part: .avatars)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .transition(.opacity)
                    } else if appState.productivity.isTimerRunning {
                        NotchTimerEar(
                            formatted: appState.productivity.timerFormatted,
                            label: appState.productivity.timerLabel
                        )
                        .transition(.opacity)
                    }
                }
                .padding(.trailing, Self.cameraGap)
                .frame(width: NotchCoordinator.earWidth - sidePad, alignment: .leading)
                .padding(.leading, sidePad)
                .animation(Mono.betweenSpring, value: appState.activityLabel)
                .animation(Mono.betweenSpring, value: showMusic)

                Spacer(minLength: 0)

                // Right ear: Agents live tool → Music live lyric + animated waveform → Focus Timer
                Group {
                    if !stack.isEmpty {
                        NotchAgentsEar(stack: stack, part: showMusic ? .both : .label)
                    } else if showMusic {
                        HStack(spacing: 6) {
                            if appState.settings.showLyricsInNotchEar, let lyric = appState.media.currentLyricLine {
                                MarqueeText(
                                    text: lyric,
                                    font: .system(size: 10, weight: .medium),
                                    color: .white.opacity(0.86),
                                    speed: 26,
                                    pauseDuration: 1.0
                                )
                            }
                            AudioVisualizerBars(
                                isPlaying: appState.media.isPlaying,
                                color: appState.media.palette.primary,
                                secondaryColor: appState.media.palette.secondary,
                                barCount: 5,
                                maxHeight: 13,
                                barWidth: 2.1
                            )
                        }
                        .transition(.opacity)
                    } else if appState.productivity.isTimerRunning {
                        Text(appState.productivity.timerLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.72))
                            .lineLimit(1)
                    }
                }
                // Starts right where the camera housing ends so labels get the whole ear.
                .padding(.leading, Self.cameraGap)
                .frame(width: NotchCoordinator.earWidth - sidePad, alignment: .leading)
                .padding(.trailing, sidePad)
                .animation(Mono.betweenSpring, value: showMusic)
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

    // MARK: - Agent Permission Toast

    private let permissionCardHeight: CGFloat = 138

    private func permissionContent(_ request: AgentPermissionRequest) -> some View {
        VStack(spacing: 0) {
            Spacer().frame(height: isIsland ? 10 : coordinator.closedHeight + 6)
            AgentPermissionCard(
                request: request,
                monitor: appState.agents,
                isToast: true,
                queueCount: appState.agents.pending.count
            )
            .padding(.horizontal, 26)
            .padding(.bottom, 12)
            .id(request.id)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(alignment: .bottom) {
            aurora([request.source.tint, Mono.caution, Color(hex: 0xF472B6)])
                .transition(.opacity)
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
                        .font(.system(size: 10.5).monospacedDigit())
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
                    .buttonStyle(NotchButtonStyle())
                }

                Button {
                    appState.dismissNotice()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(NotchButtonStyle(hoverScale: 1.1))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(alignment: .bottom) {
            noticeAurora(notice.kind)
                .id(notice.id)
                .transition(.opacity)
        }
    }

    /// Color wash that rises from the bottom edge of a notice, keyed to its kind.
    private func noticeAurora(_ kind: NotchNoticeKind) -> some View {
        aurora(noticeGradient(kind))
    }

    private func aurora(_ colors: [Color]) -> some View {
        ZStack {
            LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                .frame(height: 46)
                .blur(radius: 18)
                .offset(y: 16)
            LinearGradient(colors: colors.map { $0.opacity(0.9) }, startPoint: .leading, endPoint: .trailing)
                .frame(height: 1.5)
                .blur(radius: 1.5)
                .opacity(0.6)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 46)
        .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
        .opacity(0.55)
        .allowsHitTesting(false)
    }

    private func noticeGradient(_ kind: NotchNoticeKind) -> [Color] {
        switch kind {
        case .cleaned: return [Mono.healthy, Color(hex: 0x22D3EE), Mono.cpuAccent]
        case .warning, .highMemory: return [Mono.caution, Color(hex: 0xF97316), Color(hex: 0xF472B6)]
        case .heavyCPU: return [Color(hex: 0xF97316), Mono.dangerStrong, Color(hex: 0xA855F7)]
        case .failed: return [Mono.dangerStrong, Color(hex: 0xF43F5E), Color(hex: 0xA855F7)]
        case .devBloat: return [Mono.infoAccent, Mono.cpuAccent, Color(hex: 0xC084FC)]
        case .unusedApp: return [Color(hex: 0xC084FC), Color(hex: 0xF472B6), Mono.infoAccent]
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

    // MARK: - Expanded Droppy Control Shelf

    private var expandedContent: some View {
        VStack(spacing: 0) {
            expandedHeader
            if let detail = coordinator.detail {
                NotchDetailView(appState: appState, coordinator: coordinator, detail: detail)
                    .padding(.horizontal, Self.sideInset)
                    .padding(.top, 6)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                        removal: .opacity
                    ))
            } else {
                // Tab Body — ONLY 3 minimal Droppy spaces (Home Widgets · Bandeja · Limpiar)
                Group {
                    switch coordinator.selectedTab {
                    case .home:
                        NotchHomeWidgetsView(appState: appState, coordinator: coordinator)
                    case .shelf:
                        NotchProductivityView(
                            hub: appState.productivity,
                            vault: appState.vault,
                            subTab: $coordinator.productivitySubTab,
                            onCollapseNotch: {
                                withAnimation(Mono.foldingSpring) {
                                    coordinator.isExpanded = false
                                }
                            }
                        )
                    case .cleaner:
                        NotchCleanerView(appState: appState, coordinator: coordinator)
                    }
                }
                .id(coordinator.selectedTab)
                .transition(.opacity.combined(with: .offset(y: 3)))
                .padding(.horizontal, Self.sideInset)
                .padding(.top, 6)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .animation(reduceMotion ? .none : Mono.openingSpring, value: coordinator.detail)
    }

    // MARK: - Subtle & Refined Floating Liquid Glass Capsule Dock

    private var floatingCapsuleDock: some View {
        let tabs = NotchTab.allCases
        return NotchGlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(tabs) { tab in
                        let isSelected = coordinator.selectedTab == tab && coordinator.detail == nil
                        let isHovered = hoveredTab == tab
                        let badge = tabBadge(tab)

                        Button {
                            withAnimation(reduceMotion ? .none : Mono.betweenSpring) {
                                coordinator.detail = nil
                                coordinator.selectedTab = tab
                            }
                            AppKitHaptics.tap()
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                VStack(spacing: 2) {
                                    Icon3D(
                                        name: tab.glassIcon,
                                        size: 22,
                                        isActive: isSelected || (tab == .home && appState.media.isPlaying),
                                        externalHover: isHovered,
                                        interactive: false
                                    )
                                    .scaleEffect(isHovered && !reduceMotion ? 1.07 : 1.0)

                                    Circle()
                                        .fill(isSelected ? Color.white.opacity(0.9) : Color.clear)
                                        .frame(width: 3.5, height: 3.5)
                                        .scaleEffect(isSelected ? 1 : 0.2)
                                        .animation(Mono.betweenSpring, value: isSelected)
                                }
                                .frame(width: 36, height: 32)
                                .background {
                                    if isSelected {
                                        Capsule()
                                            .fill(Color.white.opacity(0.14))
                                            .matchedGeometryEffect(id: "droppyDockPill", in: dockNamespace)
                                    } else if isHovered {
                                        Capsule()
                                            .fill(Color.white.opacity(0.06))
                                            .transition(.opacity)
                                    }
                                }

                                if let badge {
                                    Text(badge)
                                        .font(.system(size: 8.5, weight: .bold).monospacedDigit())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4.5)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color(hex: 0xFF4B3A)))
                                        .overlay(Capsule().strokeBorder(Color(hex: 0x161822), lineWidth: 1))
                                        .offset(x: 1, y: -2)
                                }
                            }
                            .overlay(alignment: .top) {
                                if isHovered {
                                    GlassDockTooltipPill(text: tab.rawValue)
                                        .offset(y: -30)
                                        .transition(.opacity.combined(with: .offset(y: 3)))
                                }
                            }
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .animation(reduceMotion ? .none : Mono.fast, value: isHovered)
                        .onHover { inside in
                            withAnimation(Mono.fast) {
                                if inside { hoveredTab = tab } else if hoveredTab == tab { hoveredTab = nil }
                            }
                        }
                        .pointingHandCursor()
                        .help(tab.rawValue)
                    }

                    // Hairline divider
                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 1, height: 16)
                        .padding(.horizontal, 3)

                    // Quick Vault AutoFill button
                    dockUtilityGlassButton(
                        id: "vault",
                        label: "Bóveda (⌥⇧P)",
                        icon: .vault,
                        isActive: coordinator.selectedTab == .shelf && coordinator.productivitySubTab == .vault
                    ) {
                        withAnimation(reduceMotion ? .none : Mono.openingSpring) {
                            coordinator.detail = nil
                            coordinator.selectedTab = .shelf
                            coordinator.productivitySubTab = .vault
                        }
                        appState.vault.refreshFrontmostContext()
                        AppKitHaptics.tap()
                    }

                    // Customize Home Widgets button
                    dockUtilitySymbolButton(
                        id: "widgets",
                        label: "Widgets",
                        symbol: "square.grid.2x2",
                        tint: coordinator.isEditingWidgets ? Mono.infoAccent : Color.white.opacity(0.74),
                        isActive: coordinator.isEditingWidgets
                    ) {
                        withAnimation(reduceMotion ? .none : Mono.openingSpring) {
                            coordinator.detail = nil
                            coordinator.showLyricsTheater = false
                            if coordinator.selectedTab != .home {
                                coordinator.selectedTab = .home
                                coordinator.isEditingWidgets = true
                            } else {
                                coordinator.isEditingWidgets.toggle()
                            }
                        }
                        AppKitHaptics.tap()
                    }

                    // 1-click Notch ↔ Floating Island switch
                    dockUtilitySymbolButton(
                        id: "style",
                        label: isIsland ? "Modo Notch" : "Modo Isla",
                        symbol: isIsland ? "rectangle.topthird.inset.filled" : "capsule.fill",
                        tint: Color.white.opacity(0.74),
                        isActive: isIsland
                    ) {
                        withAnimation(reduceMotion ? .none : Mono.openingSpring) {
                            appState.settings.notchStyle = isIsland ? .notch : .island
                        }
                        AppKitHaptics.tap()
                    }

                    // 1-click Dynamic Glass / Liquid Glass / Negro switch
                    dockUtilitySymbolButton(
                        id: "surface",
                        label: surface.label,
                        symbol: surface.symbol,
                        tint: surface.isGlass ? Color.white : Color.white.opacity(0.66),
                        isActive: surface.isGlass
                    ) {
                        withAnimation(reduceMotion ? .none : Mono.betweenSpring) {
                            appState.settings.notchSurface = appState.settings.notchSurface.next
                        }
                        AppKitHaptics.tap()
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4.5)
                .floatingDockGlass(in: Capsule(), surface: surface)

                // Detached circular [×] close button
                Button {
                    withAnimation(reduceMotion ? .none : Mono.foldingSpring) {
                        coordinator.isExpanded = false
                    }
                    AppKitHaptics.tap()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(NotchButtonStyle(hoverScale: 1.06))
                .floatingDockGlass(in: Circle(), surface: surface)
                .help("Cerrar Notch (Esc)")
            }
        }
    }

    private func dockUtilityGlassButton(
        id: String,
        label: String,
        icon: Icon3DName,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredUtility == id

        return Button(action: action) {
            VStack(spacing: 2) {
                Icon3D(
                    name: icon,
                    size: 21,
                    isActive: isActive || appState.vault.isUnlocked,
                    externalHover: isHovered,
                    interactive: false
                )
                .scaleEffect(isHovered && !reduceMotion ? 1.07 : 1.0)

                Circle()
                    .fill(isActive ? Mono.ramAccent : Color.clear)
                    .frame(width: 3.5, height: 3.5)
            }
            .frame(width: 32, height: 32)
            .background(Capsule().fill(isActive ? Mono.ramAccent.opacity(0.14) : (isHovered ? Color.white.opacity(0.06) : .clear)))
            .overlay(alignment: .top) {
                if isHovered {
                    GlassDockTooltipPill(text: label)
                        .offset(y: -30)
                        .transition(.opacity.combined(with: .offset(y: 3)))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? .none : Mono.fast, value: isHovered)
        .onHover { inside in
            withAnimation(Mono.fast) {
                if inside { hoveredUtility = id } else if hoveredUtility == id { hoveredUtility = nil }
            }
        }
        .pointingHandCursor()
        .help(label)
    }

    private func dockUtilitySymbolButton(
        id: String,
        label: String,
        symbol: String,
        tint: Color,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredUtility == id

        return Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .scaleEffect(isHovered && !reduceMotion ? 1.07 : 1.0)
                Circle()
                    .fill(isActive ? tint.opacity(0.85) : Color.clear)
                    .frame(width: 3, height: 3)
            }
            .frame(width: 28, height: 32)
            .background(Capsule().fill(isActive ? Color.white.opacity(0.11) : (isHovered ? Color.white.opacity(0.06) : .clear)))
            .overlay(alignment: .top) {
                if isHovered {
                    GlassDockTooltipPill(text: label)
                        .offset(y: -30)
                        .transition(.opacity.combined(with: .offset(y: 3)))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? .none : Mono.fast, value: isHovered)
        .onHover { inside in
            withAnimation(Mono.fast) {
                if inside { hoveredUtility = id } else if hoveredUtility == id { hoveredUtility = nil }
            }
        }
        .pointingHandCursor()
        .help(label)
    }

    /// On a real notch the header sits in the two "wings" beside the camera housing (like the Dynamic
    /// Island), so the camera never eats a row of content. Island mode uses a normal single row.
    private var usesCameraWings: Bool { coordinator.geometry.hasHardwareNotch && !isIsland }

    private var headerHeight: CGFloat { usesCameraWings ? max(coordinator.closedHeight, 28) : 34 }

    private var expandedHeader: some View {
        HStack(spacing: 0) {
            // Left wing: brand + live Focus timer pill when running
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: appState.activityLabel != nil && !reduceMotion)
                Text("CleanTrash")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.82))
                    .lineLimit(1)
                    .fixedSize()

                if appState.productivity.isTimerRunning {
                    Button {
                        withAnimation(Mono.betweenSpring) {
                            coordinator.detail = nil
                            coordinator.selectedTab = .shelf
                            coordinator.productivitySubTab = .focus
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Circle().fill(Mono.healthy).frame(width: 5, height: 5)
                            Text(appState.productivity.timerFormatted)
                                .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .contentTransition(.numericText(countsDown: true))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(Mono.healthy.opacity(0.18)))
                    }
                    .buttonStyle(NotchButtonStyle(hoverScale: 1.06))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if usesCameraWings {
                Color.clear.frame(width: coordinator.closedWidth + 8)
            }

            // Right wing: live status + surface badge + open dashboard
            HStack(spacing: 6) {
                if appState.activityLabel != nil {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini).tint(.white).scaleEffect(0.65).frame(width: 10, height: 10)
                        Text(activityShort)
                            .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
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
                        .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(Mono.healthy)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Mono.healthy.opacity(0.16)))
                        .help("Liberado en esta sesión")
                        .transition(.opacity)
                }

                Text(coordinator.selectedTab.rawValue)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)

                Button {
                    coordinator.isExpanded = false
                    appState.productivity.standBy.toggle(appState: appState)
                    AppKitHaptics.tap()
                } label: {
                    Image(systemName: "sparkles.tv")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                        .contentShape(Circle())
                }
                .buttonStyle(NotchButtonStyle(hoverScale: 1.1))
                .help("Modo StandBy / Spotify Pantalla Completa (⌥⇧L)")

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
                .buttonStyle(NotchButtonStyle(hoverScale: 1.1))
                .help("Abrir el panel de CleanTrash")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .animation(Mono.betweenSpring, value: appState.activityLabel)
        }
        .frame(height: headerHeight)
        .padding(.horizontal, Self.sideInset + 2)
        .padding(.top, isIsland ? 6 : 0)
    }

    private func tabBadge(_ tab: NotchTab) -> String? {
        switch tab {
        case .shelf:
            let count = appState.productivity.shelfItems.count
            return count > 0 ? "\(count)" : nil
        case .cleaner:
            let count = appState.devArtifacts.filter { !$0.isActiveBuild }.count
            return count > 0 ? "\(count)" : nil
        case .home:
            let pending = appState.agents.pending.count
            return pending > 0 ? "\(pending)" : nil
        }
    }
}
