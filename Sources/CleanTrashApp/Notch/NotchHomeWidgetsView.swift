import AppKit
import Charts
import CleanTrashCore
import SwiftUI
import UniformTypeIdentifiers

/// Droppy-style Customizable Home Widget Shelf:
/// Displays the user's chosen widgets side-by-side separated by crisp vertical dividers
/// (Música + [L] Lyrics + Floating Pop-out, Sistema with 3D CPU/RAM/GPU Icons + Sparklines,
/// Agentes, Pomodoro, Clima, Baterías, Agenda/Calendario, Devly, Portapapeles, Audio, Notas, Despierto),
/// with live drag-and-drop reordering and a Droppy icon picker drawer.
struct NotchHomeWidgetsView: View {
    @Bindable var appState: AppState
    @Bindable var coordinator: NotchCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.notchSurface) private var surface
    @State private var draggedWidget: NotchWidgetID?
    @State private var hoverScrubFraction: Double?
    @State private var isScrubHovering = false

    // Devly widget inline state
    @State private var devlyMode: DevlyMode = .base64
    @State private var devlyInput: String = ""
    @State private var devlyOutput: String = ""
    @State private var devlyCopied = false

    private var widgets: [NotchWidgetID] {
        let active = appState.settings.homeWidgets
        return active.isEmpty ? NotchWidgetID.defaultLayout : active
    }

    var body: some View {
        VStack(spacing: 10) {
            if coordinator.showLyricsTheater, appState.media.hasActiveTrack {
                NotchMusicView(
                    media: appState.media,
                    showLyricsTheater: $coordinator.showLyricsTheater
                )
                .transition(.opacity.combined(with: .offset(y: 4)))
            } else {
                // Active Widgets Horizontal Strip (side-by-side, drag-reorderable!)
                HStack(spacing: 0) {
                    ForEach(Array(widgets.enumerated()), id: \.element) { idx, widget in
                        if idx > 0 {
                            Rectangle()
                                .fill(Color.white.opacity(0.11))
                                .frame(width: 1)
                                .padding(.vertical, 10)
                                .padding(.horizontal, 10)
                        }

                        widgetSlot(widget, index: idx)
                            .onDrag {
                                draggedWidget = widget
                                return NSItemProvider(object: widget.rawValue as NSString)
                            }
                            .onDrop(of: [.plainText], delegate: WidgetReorderDropDelegate(
                                target: widget,
                                dragged: $draggedWidget,
                                widgets: Binding(
                                    get: { appState.settings.homeWidgets },
                                    set: { appState.settings.homeWidgets = $0 }
                                )
                            ))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(reduceMotion ? .none : Mono.betweenSpring, value: widgets)

                // Droppy Edit Mode Widget Picker Drawer
                if coordinator.isEditingWidgets {
                    widgetPickerDrawer
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 8)),
                            removal: .opacity
                        ))
                }
            }
        }
        .animation(reduceMotion ? .none : Mono.openingSpring, value: coordinator.isEditingWidgets)
        .animation(reduceMotion ? .none : Mono.openingSpring, value: coordinator.showLyricsTheater)
    }

    // MARK: - Widget Slot Wrapper (Drag + Edit Chrome)

    private func widgetSlot(_ widget: NotchWidgetID, index: Int) -> some View {
        let editing = coordinator.isEditingWidgets
        return ZStack(alignment: .topTrailing) {
            widgetContent(widget)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(editing ? 7 : 2)
                .background {
                    if editing {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                Color.white.opacity(draggedWidget == widget ? 0.55 : 0.22),
                                style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                            )
                    }
                }

            if editing {
                HStack(spacing: 4) {
                    if index > 0 {
                        miniMoveButton("chevron.left") { moveWidget(at: index, by: -1) }
                    }
                    if index < widgets.count - 1 {
                        miniMoveButton("chevron.right") { moveWidget(at: index, by: 1) }
                    }
                    if widgets.count > 1 {
                        Button {
                            toggleWidget(widget)
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 8.5, weight: .black))
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(Mono.dangerStrong))
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .help("Quitar \(widget.title)")
                    }
                }
                .offset(x: 4, y: -4)
            }
        }
    }

    private func miniMoveButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(0.22)))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    @ViewBuilder
    private func widgetContent(_ widget: NotchWidgetID) -> some View {
        switch widget {
        case .nowPlaying:
            compactMusicWidget
        case .systemStats:
            systemStatsRingsWidget
        case .agents:
            agentsLiveWidget
        case .pomodoro:
            pomodoroCompactWidget
        case .weather:
            weatherCardWidget
        case .batteries:
            batteriesWidget
        case .calendar:
            calendarWidget
        case .devly:
            devlyWidget
        case .clipboard:
            compactClipboardWidget
        case .audio:
            audioWidget
        case .notes:
            quickNotesWidget
        case .stayAwake:
            stayAwakeWidget
        case .translate:
            quickTranslateWidget
        case .breather:
            breatherWidget
        }
    }

    // MARK: - 1. Now Playing Widget (Spotify / Apple Music + [L] Lyrics + Floating Mini-Player Pop-out)

    private var compactMusicWidget: some View {
        let media = appState.media
        return Group {
            if let track = media.track {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 11) {
                        Button { media.openPlayerApp() } label: {
                            ZStack {
                                if let art = media.artwork {
                                    Image(nsImage: art)
                                        .resizable()
                                        .interpolation(.high)
                                        .aspectRatio(contentMode: .fill)
                                } else {
                                    LinearGradient(
                                        colors: [media.palette.primary, media.palette.secondary],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                    .overlay {
                                        Image(systemName: "music.note")
                                            .font(.system(size: 17, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                            }
                            .frame(width: 50, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.75))
                            // Artwork glows in its own color and settles back when paused (Music-app style).
                            .shadow(color: media.palette.primary.opacity(media.isPlaying ? 0.45 : 0.15), radius: media.isPlaying ? 10 : 4, y: 3)
                            .scaleEffect(media.isPlaying ? 1 : 0.92)
                            .animation(reduceMotion ? .none : .spring(response: 0.45, dampingFraction: 0.72), value: media.isPlaying)
                            .id(track.trackKey)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()

                        VStack(alignment: .leading, spacing: 2) {
                            Button { media.openTrackInPlayer() } label: {
                                Text(track.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                            .help("Abrir canción en \(track.source.rawValue)")

                            Button { media.openArtistInPlayer() } label: {
                                Text(track.artist)
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(Color.white.opacity(0.55))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                            .help("Ver perfil de \(track.artist) en \(track.source.rawValue)")
                        }
                        .id(track.trackKey)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 6)),
                            removal: .opacity.combined(with: .offset(y: -6))
                        ))

                        Spacer(minLength: 2)

                        AudioVisualizerBars(
                            isPlaying: media.isPlaying,
                            color: media.palette.primary,
                            secondaryColor: media.palette.secondary,
                            barCount: 4,
                            maxHeight: 14,
                            barWidth: 2.2
                        )
                    }
                    .animation(reduceMotion ? .none : Mono.betweenSpring, value: track.trackKey)

                    compactScrubber(track)

                    HStack(spacing: 0) {
                        lyricsButton(media)

                        Spacer()

                        HStack(spacing: 18) {
                            Button { media.previousTrack() } label: {
                                Image(systemName: "backward.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(0.9))
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(NotchButtonStyle(hoverScale: 1.1))

                            Button { media.togglePlayPause() } label: {
                                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.black)
                                    .contentTransition(.symbolEffect(.replace))
                                    .frame(width: 32, height: 32)
                                    .background(Circle().fill(.white))
                            }
                            .buttonStyle(NotchButtonStyle(hoverScale: 1.08))
                            .help(media.isPlaying ? "Pausar" : "Reproducir")

                            Button { media.nextTrack() } label: {
                                Image(systemName: "forward.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(0.9))
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(NotchButtonStyle(hoverScale: 1.1))
                        }

                        Spacer()

                        Button {
                            appState.productivity.floatingPlayer.toggle(media: media, surface: surface)
                        } label: {
                            Image(systemName: "pip.enter")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.55))
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(NotchButtonStyle(hoverScale: 1.1))
                        .help("Abrir reproductor flotante")
                    }
                }
                .padding(.vertical, 4)
            } else if media.automationDenied {
                VStack(spacing: 7) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 18))
                        .foregroundStyle(Mono.caution)
                    Text("Permiso de Spotify")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Button("Autorizar en Ajustes") {
                        media.openAutomationSettings()
                    }
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.white))
                    .buttonStyle(NotchButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.55))
                    Text("Sin reproducción")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Button {
                        media.openSpotify()
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(Color(hex: 0x1ED760)).frame(width: 6, height: 6)
                            Text("Abrir Spotify")
                                .font(.system(size: 10.5, weight: .bold))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.white))
                    }
                    .buttonStyle(NotchButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Lyrics live in their own theater; here it's just a button that lights up when synced lyrics exist.
    private func lyricsButton(_ media: MediaPlayerController) -> some View {
        let synced = media.lyrics?.isSynced == true
        let available = media.lyrics.map { !$0.isEmpty } ?? false
        return Button {
            withAnimation(Mono.openingSpring) { coordinator.showLyricsTheater = true }
        } label: {
            Image(systemName: available ? "quote.bubble.fill" : "quote.bubble")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(available ? media.palette.primary.opacity(0.95) : Color.white.opacity(0.4))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26, height: 26)
                .background(Circle().fill(available ? media.palette.primary.opacity(0.14) : .clear))
        }
        .buttonStyle(NotchButtonStyle(hoverScale: 1.1))
        .disabled(!available)
        .help(synced ? "Letras sincronizadas" : available ? "Letras" : "Sin letras para esta canción")
        .animation(Mono.betweenSpring, value: available)
    }

    private func compactScrubber(_ track: NowPlayingTrack) -> some View {
        let media = appState.media
        let frac = hoverScrubFraction ?? media.progress
        let elapsed = media.isScrubbing ? media.scrubPreviewPosition : media.effectivePosition
        let remaining = max(0, track.duration - elapsed)

        return HStack(spacing: 6) {
            Text(Self.formatTime(elapsed))
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.52))
            GeometryReader { geo in
                let w = max(1, geo.size.width)
                let thick: CGFloat = isScrubHovering || media.isScrubbing ? 6 : 3.5
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14)).frame(height: thick)
                    Capsule().fill(Color.white.opacity(isScrubHovering ? 0.95 : 0.75)).frame(width: max(thick, w * frac), height: thick)
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: thick)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let p = min(1, max(0, v.location.x / w))
                            media.isScrubbing = true
                            media.scrubPreviewPosition = p * track.duration
                            hoverScrubFraction = p
                        }
                        .onEnded { v in
                            let p = min(1, max(0, v.location.x / w))
                            hoverScrubFraction = nil
                            media.seek(to: p * track.duration)
                        }
                )
            }
            .frame(height: 12)
            .onHover { isScrubHovering = $0 }
            .pointingHandCursor()
            Text("-\(Self.formatTime(remaining))")
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.52))
        }
    }

    // MARK: - 2. System Stats Widget (Custom 3D Icons for CPU · RAM · GPU + Circular Rings + Live Sparklines!)

    private var systemStatsRingsWidget: some View {
        let cpu = appState.telemetry.cpuTotalPercent
        let ram = appState.telemetry.memory.usedPercent
        let gpu = appState.telemetry.gpu.deviceUtilizationPercent
        let cpuColor = Mono.cpuAccent
        let ramColor = Mono.ramAccent
        let gpuColor = Mono.gpuAccent

        return VStack(spacing: 8) {
            // Top Row: 3 Glowing Rings with our Custom 3D Glass Icons centered inside!
            HStack(spacing: 6) {
                ring3DButton(
                    icon: .cpu,
                    label: "CPU",
                    percent: cpu,
                    tint: cpu >= 90 ? Mono.danger : cpuColor,
                    help: "Ver procesos de CPU"
                ) {
                    withAnimation(Mono.openingSpring) { coordinator.detail = .cpu }
                }

                ring3DButton(
                    icon: .memory,
                    label: "RAM",
                    percent: ram,
                    tint: ram >= 88 ? Mono.caution : ramColor,
                    help: "Ver memoria y optimizar RAM"
                ) {
                    withAnimation(Mono.openingSpring) { coordinator.detail = .memory }
                }

                ring3DButton(
                    icon: .gpu,
                    label: "GPU",
                    percent: gpu,
                    tint: gpu >= 90 ? Mono.caution : gpuColor,
                    help: "Ver GPU y limpiar cachés"
                ) {
                    withAnimation(Mono.openingSpring) { coordinator.detail = .gpu }
                }
            }

            // Bottom Row: Live Rolling Sparklines for CPU, RAM & GPU
            HStack(spacing: 6) {
                liveSparkline(\.cpu, tint: cpuColor)
                liveSparkline(\.memory, tint: ramColor)
                liveSparkline(\.gpu, tint: gpuColor)
            }
            .frame(height: 36)
        }
        .padding(.vertical, 4)
    }

    private func ring3DButton(
        icon: Icon3DName,
        label: String,
        percent: Double,
        tint: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.13), lineWidth: 3.2)
                    Circle()
                        .trim(from: 0, to: min(1, max(0.03, percent / 100.0)))
                        .stroke(tint, style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(Mono.betweenSpring, value: percent)
                    Icon3D(name: icon, size: 20)
                }
                .frame(width: 36, height: 36)

                VStack(spacing: 0) {
                    Text("\(Int(percent.rounded()))%")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .contentTransition(.numericText())
                    Text(label)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(tint.opacity(0.9))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchButtonStyle(hoverScale: 1.04))
        .help(help)
    }

    private func liveSparkline(_ keyPath: KeyPath<TelemetryPoint, Double>, tint: Color) -> some View {
        Chart(appState.history) { point in
            AreaMark(
                x: .value("t", point.timestamp),
                y: .value("%", min(100, point[keyPath: keyPath]))
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [tint.opacity(0.30), tint.opacity(0.01)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("t", point.timestamp),
                y: .value("%", min(100, point[keyPath: keyPath]))
            )
            .foregroundStyle(tint)
            .lineStyle(StrokeStyle(lineWidth: 1.4, lineCap: .round))
            .interpolationMethod(.catmullRom)
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }

    // MARK: - 3. Agents Live Widget (Claude / Codex / Antigravity)

    private var agentsLiveWidget: some View {
        let monitor = appState.agents
        let pending = monitor.pending.first
        let lead = monitor.earStack.first ?? monitor.visibleSessions.first

        return VStack(spacing: 8) {
            HStack(spacing: 6) {
                if let lead {
                    ProviderLogo(source: lead.source, size: 18)
                    Text(lead.source.shortName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                    Text("•")
                        .foregroundStyle(lead.source.tint)
                    Text(lead.phase.isWorking ? "Activo" : (lead.phase == .needsPermission ? "Permiso" : "Listo"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(lead.phase == .needsPermission ? Mono.caution : lead.source.tint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: 0xF0A27A))
                    Text("Agentes")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                }

                Spacer(minLength: 4)

                if let lead {
                    Button { monitor.focus(lead) } label: {
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Mono.ramAccent)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color(hex: 0x10B981).opacity(0.22)))
                    }
                    .buttonStyle(NotchButtonStyle(hoverScale: 1.08))
                    .help("Abrir \(lead.originLabel)")
                }
            }

            Spacer(minLength: 0)

            if let pending {
                VStack(spacing: 6) {
                    Text(pending.detail ?? AgentToolLabel.label(for: pending.tool))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))

                    HStack(spacing: 6) {
                        Button("Denegar") { monitor.respond(pending, decision: .deny) }
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(hex: 0xFCA5A5))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Mono.danger.opacity(0.18)))
                            .buttonStyle(NotchButtonStyle())

                        Button("Permitir") { monitor.respond(pending, decision: .allow) }
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.white))
                            .buttonStyle(NotchButtonStyle())
                    }
                }
            } else if let lead {
                Button { monitor.focus(lead) } label: {
                    VStack(spacing: 6) {
                        Image(systemName: agentToolSymbol(lead))
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(lead.source.tint)
                        Text(NotchAgentsEar.liveActivity(lead))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(lead.originLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            } else {
                VStack(spacing: 5) {
                    HStack(spacing: -5) {
                        ForEach(AgentSource.allCases) { src in
                            ProviderLogo(source: src, size: 22)
                        }
                    }
                    Text("Sin sesiones activas")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private func agentToolSymbol(_ session: AgentSession) -> String {
        switch AgentToolLabel.label(for: session.tool) {
        case "Editar", "Escribir": return "square.and.pencil"
        case "Terminal": return "terminal"
        case "Leer": return "doc.text.magnifyingglass"
        case "Buscar": return "magnifyingglass"
        case "Web": return "globe"
        default: return session.phase.isWorking ? "sparkles" : "checkmark.circle"
        }
    }

    // MARK: - 4. Pomodoro Widget

    private var pomodoroCompactWidget: some View {
        let hub = appState.productivity
        let amber = Mono.junkAccent

        return VStack(spacing: 10) {
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button { hub.toggleTimer() } label: {
                    Image(systemName: hub.isTimerRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(amber)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(amber.opacity(0.24)))
                        .overlay(Circle().strokeBorder(amber.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(NotchButtonStyle(hoverScale: 1.08))

                Button { hub.resetTimer() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.white.opacity(0.13)))
                }
                .buttonStyle(NotchButtonStyle(hoverScale: 1.08))

                Text(hub.timerFormatted)
                    .font(.system(size: 25, weight: .semibold).monospacedDigit())
                    .foregroundStyle(amber)
                    .contentTransition(.numericText(countsDown: true))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            HStack(spacing: 5) {
                ForEach(FocusPreset.defaults.prefix(3)) { preset in
                    let active = hub.timerLabel == preset.label && hub.timerTotalSeconds == preset.minutes * 60
                    Button {
                        hub.startPreset(preset)
                    } label: {
                        Text("\(preset.minutes)m")
                            .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(active ? .black : .white.opacity(0.7))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(active ? amber : Color.white.opacity(0.09)))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 5. Weather Card Widget

    private var weatherCardWidget: some View {
        let w = appState.productivity.weather
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text(w?.city ?? "Clima")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Image(systemName: "location.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Text(w.map { "\($0.tempC)°" } ?? "--°")
                        .font(.system(size: 28, weight: .light).monospacedDigit())
                        .foregroundStyle(.white)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 2) {
                    Image(systemName: w?.symbol ?? "sun.max.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                    Text(w?.condition ?? "Cargando…")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    if let w {
                        Text("H:\(w.highC)° L:\(w.lowC)°")
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.82))
                    }
                }
            }

            Spacer(minLength: 0)

            if let hourly = w?.hourly, !hourly.isEmpty {
                HStack(spacing: 0) {
                    ForEach(hourly) { point in
                        VStack(spacing: 3) {
                            Text(point.hourLabel)
                                .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.75))
                            Image(systemName: point.symbol)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.white)
                            Text("\(point.tempC)°")
                                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x4A80D4), Color(hex: 0x6AA3F0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .onTapGesture {
            Task { await appState.productivity.refreshWeather() }
        }
        .pointingHandCursor()
        .help("Toca para actualizar el clima")
    }

    // MARK: - 6. Batteries Widget (Droppy Image 7: Glowing Device Rings!)

    private var batteriesWidget: some View {
        var devices: [DeviceBatteryInfo] = []
        let macBat = appState.telemetry.battery
        if macBat.present {
            devices.append(DeviceBatteryInfo(
                id: "mac",
                name: "MacBook",
                percent: Int(macBat.percent.rounded()),
                symbol: "laptopcomputer",
                isCharging: macBat.isCharging
            ))
        }
        devices.append(contentsOf: appState.productivity.bluetoothBatteries)

        return VStack(spacing: 8) {
            Spacer(minLength: 0)
            if devices.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "battery.100percent.bolt")
                        .font(.system(size: 20))
                        .foregroundStyle(Mono.healthy)
                    Text("Conectado a corriente")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            } else {
                HStack(spacing: 10) {
                    ForEach(devices.prefix(5)) { dev in
                        batteryRingTile(dev)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func batteryRingTile(_ dev: DeviceBatteryInfo) -> some View {
        let tint: Color = dev.percent <= 20 ? Mono.danger : (dev.percent <= 40 ? Mono.caution : Color(hex: 0x22C55E))
        return VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.14), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: min(1, max(0.04, Double(dev.percent) / 100.0)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if dev.id == "mac" {
                    Icon3D(name: .mac, size: 20)
                } else {
                    Image(systemName: dev.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 40, height: 40)

            VStack(spacing: 0.5) {
                HStack(spacing: 2) {
                    Text("\(dev.percent)%")
                        .font(.system(size: 11.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                    if dev.isCharging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Mono.healthy)
                    }
                }
                Text(dev.name)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 7. Calendar / Agenda Widget (Droppy Image 5 & 8!)

    private var calendarWidget: some View {
        let hub = appState.productivity
        let cal = Calendar.current
        let now = Date.now
        let dayNum = cal.component(.day, from: now)
        let monthTitle = now.formatted(.dateTime.month(.abbreviated)).uppercased()
        let weekdayTitle = now.formatted(.dateTime.weekday(.abbreviated)).uppercased()

        return HStack(spacing: 10) {
            // Left: Today's Agenda
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text("\(weekdayTitle) \(dayNum)")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Mono.dangerStrong)
                    Text(monthTitle)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.45))
                }

                if !hub.calendarAuthorized {
                    Spacer(minLength: 0)
                    Button("Conectar Agenda") {
                        Task { await hub.requestCalendarAccess() }
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.white))
                    .buttonStyle(NotchButtonStyle())
                    Spacer(minLength: 0)
                } else if hub.calendarEvents.isEmpty {
                    Spacer(minLength: 0)
                    Text("Día despejado")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.5))
                    Spacer(minLength: 0)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(hub.calendarEvents.prefix(3)) { ev in
                            HStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color(hex: ev.colorHex))
                                    .frame(width: 3, height: 22)
                                VStack(alignment: .leading, spacing: 0.5) {
                                    Text(ev.title)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text(ev.timeRange)
                                        .font(.system(size: 8.5).monospacedDigit())
                                        .foregroundStyle(Color.white.opacity(0.55))
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: ev.colorHex).opacity(0.16)))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right: Compact Mini Month Grid (today highlighted in red circle!)
            miniMonthGrid(for: now)
                .frame(width: 104)
        }
        .padding(.vertical, 4)
    }

    private func miniMonthGrid(for date: Date) -> some View {
        let cal = Calendar.current
        let today = cal.component(.day, from: date)
        let range = cal.range(of: .day, in: .month, for: date) ?? 1..<31
        let comps = cal.dateComponents([.year, .month], from: date)
        let firstOfMonth = cal.date(from: comps) ?? date
        let firstWeekday = (cal.component(.weekday, from: firstOfMonth) - 1) // 0 = Sun
        let headers = ["D", "L", "M", "M", "J", "V", "S"]
        let totalCells = firstWeekday + range.count

        return VStack(spacing: 2.5) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(headers[i])
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.42))
                        .frame(maxWidth: .infinity)
                }
            }
            let rows = (totalCells + 6) / 7
            ForEach(0..<min(6, rows), id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        let idx = row * 7 + col - firstWeekday + 1
                        if idx >= 1 && idx <= range.count {
                            Text("\(idx)")
                                .font(.system(size: 8, weight: idx == today ? .bold : .medium).monospacedDigit())
                                .foregroundStyle(idx == today ? .white : Color.white.opacity(0.75))
                                .frame(width: 14, height: 14)
                                .background(Circle().fill(idx == today ? Mono.dangerStrong : .clear))
                                .frame(maxWidth: .infinity)
                        } else {
                            Color.clear.frame(height: 14).frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 8. Devly Developer Tools Widget (Droppy Image 8!)

    private var devlyWidget: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Mode pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(DevlyMode.allCases) { m in
                        let active = devlyMode == m
                        Button {
                            devlyMode = m
                            if m == .uuid {
                                devlyOutput = DevlyTools.encode("", mode: .uuid)
                            } else if !devlyInput.isEmpty {
                                devlyOutput = DevlyTools.encode(devlyInput, mode: m)
                            }
                        } label: {
                            Text(m.rawValue)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(active ? .black : .white.opacity(0.72))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(active ? .white : Color.white.opacity(0.10)))
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                }
            }

            // Input bar + Paste + Encode/Decode
            HStack(spacing: 4) {
                TextField("Pega texto, JSON o JWT…", text: $devlyInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4.5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))

                Button {
                    if let clip = NSPasteboard.general.string(forType: .string) {
                        devlyInput = clip
                        devlyOutput = DevlyTools.encode(clip, mode: devlyMode)
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 24, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Pegar del portapapeles")

                Button(devlyMode == .jwt || devlyMode == .uuid ? "Run" : "Enc") {
                    devlyOutput = DevlyTools.encode(devlyInput, mode: devlyMode)
                }
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule().fill(.white))
                .buttonStyle(.plain)
                .pointingHandCursor()

                if devlyMode == .base64 || devlyMode == .json || devlyMode == .url {
                    Button(devlyMode == .json ? "Min" : "Dec") {
                        devlyOutput = DevlyTools.decode(devlyInput, mode: devlyMode)
                    }
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }

            // Output preview + Copy button
            HStack(spacing: 6) {
                Text(devlyOutput.isEmpty ? "Resultado aparecerá aquí…" : devlyOutput)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(devlyOutput.isEmpty ? Color.white.opacity(0.35) : Mono.ramAccent)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !devlyOutput.isEmpty {
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(devlyOutput, forType: .string)
                        AppKitHaptics.tap()
                        devlyCopied = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(1100))
                            devlyCopied = false
                        }
                    } label: {
                        Image(systemName: devlyCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(devlyCopied ? Mono.healthy : .white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Copiar resultado")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
        }
        .padding(.vertical, 4)
    }

    // MARK: - 9. Audio Control Widget (Droppy Image 4: CoreAudio Master + Spotify Slider!)

    private var audioWidget: some View {
        let hub = appState.productivity
        let media = appState.media
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Mono.junkAccent)
                Text(hub.audioOutputName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Button {
                    hub.toggleMasterMute()
                } label: {
                    Image(systemName: hub.isMasterMuted ? "speaker.slash.fill" : "speaker.wave.3.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hub.isMasterMuted ? Mono.danger : .white.opacity(0.75))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            // Master Volume Bar
            audioSliderRow(
                icon: "laptopcomputer",
                label: "Sistema",
                percent: hub.isMasterMuted ? 0 : hub.masterVolume,
                tint: .white
            ) { val in
                hub.setMasterVolume(val)
            }

            // Spotify / Apple Music App Volume Bar
            if let track = media.track {
                audioSliderRow(
                    icon: "music.note",
                    label: track.source.rawValue,
                    percent: media.volume,
                    tint: track.source.accentColor
                ) { val in
                    media.setVolume(val)
                }
            } else {
                Text("Abre Spotify o Música para volumen por app")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.white.opacity(0.42))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .onAppear { hub.refreshAudioState() }
    }

    private func audioSliderRow(icon: String, label: String, percent: Int, tint: Color, onChange: @escaping (Int) -> Void) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(tint)
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                Spacer()
                Text("\(percent)%")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
            }
            Slider(
                value: Binding(get: { Double(percent) }, set: { onChange(Int($0.rounded())) }),
                in: 0...100
            )
            .tint(tint)
            .controlSize(.mini)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
    }

    // MARK: - 10. Clipboard Compact Widget (Droppy Cards)

    private var compactClipboardWidget: some View {
        let entries = Array(appState.productivity.sortedClipboardEntries.prefix(4))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Portapapeles", systemImage: "doc.on.clipboard")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Mono.infoAccent)
                Spacer()
                Button("Ver todo") {
                    withAnimation(Mono.betweenSpring) {
                        coordinator.selectedTab = .shelf
                        coordinator.productivitySubTab = .clipboard
                    }
                }
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.55))
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            if entries.isEmpty {
                Text("Copia texto, links o colores HEX")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(entries) { entry in
                            miniClipCard(entry)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func miniClipCard(_ entry: ClipboardEntry) -> some View {
        let isColor = entry.kind == .color
        let hexVal = entry.hexColor.flatMap { UInt32($0.replacingOccurrences(of: "#", with: ""), radix: 16) }
        let bg = isColor ? Color(hex: hexVal ?? 0x6E7BF2) : Color(hex: 0x17171B)
        let copied = appState.productivity.lastCopiedEntryID == entry.id

        return VStack(alignment: .leading, spacing: 5) {
            Text(entry.kind.rawValue.capitalized)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.white))

            Text(isColor ? (entry.hexColor ?? entry.previewText) : entry.previewText)
                .font(.system(size: isColor ? 12 : 10, weight: isColor ? .bold : .medium, design: isColor ? .monospaced : .default))
                .foregroundStyle(.white)
                .lineLimit(3)

            Spacer(minLength: 0)

            if copied {
                Text("✓ Copiado")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Mono.healthy)
            }
        }
        .padding(8)
        .frame(width: 112, height: 92, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(bg))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8))
        .onTapGesture { appState.productivity.copyBack(entry) }
        .pointingHandCursor()
    }

    // MARK: - 11. Multi-Notes Widget (Droppy Image 5!)

    private var quickNotesWidget: some View {
        let hub = appState.productivity
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                if hub.selectedNoteID != nil {
                    Button {
                        withAnimation(Mono.betweenSpring) { hub.selectedNoteID = nil }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
                Text("Notas")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Mono.caution)
                Spacer()
                Button {
                    _ = hub.createNote()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Nueva nota")
            }

            if let selID = hub.selectedNoteID,
               let note = hub.quickNotes.first(where: { $0.id == selID }) {
                TextEditor(text: Binding(
                    get: { note.body },
                    set: { hub.updateNote(id: selID, body: $0) }
                ))
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.92))
                .scrollContentBackground(.hidden)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(hub.quickNotes.prefix(4)) { note in
                            Button {
                                withAnimation(Mono.betweenSpring) { hub.selectedNoteID = note.id }
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(note.title)
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text(note.body.isEmpty ? "Toca para escribir…" : note.body.replacingOccurrences(of: "\n", with: " "))
                                        .font(.system(size: 9))
                                        .foregroundStyle(Color.white.opacity(0.48))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 12. Stay Awake Widget

    private var stayAwakeWidget: some View {
        let on = appState.productivity.isStayAwakeEnabled
        return Button {
            appState.productivity.toggleStayAwake()
        } label: {
            VStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(on ? Mono.junkAccent.opacity(0.24) : Color.white.opacity(0.08))
                        .frame(width: 44, height: 44)
                    Image(systemName: on ? "cup.and.saucer.fill" : "moon.zzz.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(on ? Mono.caution : Color.white.opacity(0.65))
                }
                Text("Despierto")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(on ? "Pantalla activa" : "Toca para activar")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(on ? Mono.caution : Color.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: - 13. Quick Translate Widget (On-Device Apple Translation)

    private var quickTranslateWidget: some View {
        let tr = appState.productivity.quickTranslate.state
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "translate")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Mono.gpuAccent)
                Text("\(tr.sourceLanguage.code.uppercased()) → \(tr.targetLanguage.code.uppercased())")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white)
                Text("En Mac")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.white.opacity(0.11)))
                Spacer(minLength: 2)
                Button { tr.swapLanguages() } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.09)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            Text(tr.translatedText.isEmpty ? "Traduce texto seleccionado o del portapapeles sin salir de tu app." : tr.translatedText)
                .font(.system(size: 11.5, weight: tr.translatedText.isEmpty ? .regular : .medium))
                .foregroundStyle(.white.opacity(tr.translatedText.isEmpty ? 0.55 : 0.92))
                .lineLimit(3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack(spacing: 6) {
                Button {
                    appState.productivity.quickTranslate.show(surface: appState.settings.notchSurface, seedFromClipboard: true)
                } label: {
                    Label("Traducir clip", systemImage: "doc.on.clipboard")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4.5)
                        .background(Capsule().fill(Color(hex: 0x2563EB).opacity(0.88)))
                }
                .buttonStyle(NotchButtonStyle())

                if !tr.translatedText.isEmpty {
                    Button(tr.copiedFeedback ? "✓" : "Copiar") {
                        tr.copyTranslated()
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4.5)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                    .buttonStyle(NotchButtonStyle())
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 14. Breather Widget (Droppy Image 2: 20-20-20 Eye Rest · Stretch · Water + Call Silencing)

    private var breatherWidget: some View {
        let br = appState.productivity.breather
        let dayLetters = ["L", "M", "X", "J", "V", "S", "D"]
        let todayISO = BreatherEngine.currentISOWeekday()

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(BreatherBreakKind.eyes.tint)
                    Text("Breather")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white)
                }

                HStack(spacing: 3) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Color(hex: 0xFB923C))
                    Text("\(br.streakDays)d")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color(hex: 0xFDBA74))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color(hex: 0xEA580C).opacity(0.22)))

                Spacer(minLength: 2)

                if br.isSilencedByCall {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Mono.caution)
                        .help("Silenciado automáticamente durante llamada")
                }

                Button { br.togglePause() } label: {
                    Image(systemName: br.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            HStack(spacing: 10) {
                BreatherConcentricRings(
                    eyesProgress: br.eyesProgress,
                    stretchProgress: br.stretchProgress,
                    waterProgress: br.waterProgress,
                    centerText: br.isBreakActive ? "\(br.activeBreakSecondsLeft)s" : "\(br.totalDoneToday)",
                    size: 52
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(br.isBreakActive ? br.nextBreakKind.rawValue : "Siguiente pausa")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(br.isBreakActive ? br.nextBreakKind.subtitle : "\(br.nextBreakKind.shortLabel) en \(br.minutesUntilNextBreak)m")
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(br.totalDoneToday)/\(br.totalGoalToday) hoy")
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }

                Spacer(minLength: 2)

                Button(br.isBreakActive ? "Listo" : "Pausa") {
                    if br.isBreakActive {
                        br.completeBreak()
                    } else {
                        br.startBreakNow()
                    }
                }
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(br.isBreakActive ? 0.24 : 0.13)))
                .buttonStyle(NotchButtonStyle())
            }

            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { day in
                        let done = br.completedWeekdays.contains(day)
                        let isToday = day == todayISO
                        Text(dayLetters[day - 1])
                            .font(.system(size: 8.5, weight: isToday || done ? .bold : .medium))
                            .foregroundStyle(done ? BreatherBreakKind.eyes.tint : (isToday ? .white : .white.opacity(0.35)))
                    }
                }
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    breatherDot("\(br.eyesDone)/6", tint: BreatherBreakKind.eyes.tint)
                    breatherDot("\(br.stretchDone)/3", tint: BreatherBreakKind.stretch.tint)
                    breatherDot("\(br.waterDone)/4", tint: BreatherBreakKind.water.tint)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func breatherDot(_ text: String, tint: Color) -> some View {
        HStack(spacing: 2.5) {
            Circle().fill(tint).frame(width: 4.5, height: 4.5)
            Text(text)
                .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.62))
        }
    }

    // MARK: - Droppy Widget Picker Drawer (with Custom 3D Icons!)

    private var widgetPickerDrawer: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(NotchWidgetID.allCases) { widget in
                        let isActive = widgets.contains(widget)
                        Button {
                            toggleWidget(widget)
                        } label: {
                            VStack(spacing: 4) {
                                ZStack(alignment: .bottomTrailing) {
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .fill(widgetBadgeGradient(widget))
                                        .frame(width: 36, height: 36)
                                        .overlay {
                                            if let icon3D = widgetIcon3D(widget) {
                                                Icon3D(name: icon3D, size: 24)
                                            } else {
                                                Image(systemName: widget.symbol)
                                                    .font(.system(size: 15, weight: .semibold))
                                                    .foregroundStyle(.white)
                                            }
                                        }
                                        .opacity(isActive ? 1.0 : 0.62)

                                    if isActive {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(.white, Mono.appsAccent)
                                            .offset(x: 3, y: 3)
                                    }
                                }
                                Text(widget.title)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(isActive ? .white : Color.white.opacity(0.6))
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            .frame(width: 52, height: 52)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity, minHeight: 54, maxHeight: 54)

            Button {
                withAnimation(Mono.openingSpring) {
                    coordinator.isEditingWidgets = false
                }
                AppKitHaptics.confirm()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color(hex: 0x2563EB)))
            }
            .buttonStyle(NotchButtonStyle(hoverScale: 1.08))
            .help("Guardar widgets")
        }
        .frame(height: 58)
        .padding(.top, 4)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1)
        }
    }

    private func widgetIcon3D(_ widget: NotchWidgetID) -> Icon3DName? {
        switch widget {
        case .systemStats: return .cpu
        case .devly: return .dev
        case .batteries: return .mac
        default: return nil
        }
    }

    private func widgetBadgeGradient(_ widget: NotchWidgetID) -> LinearGradient {
        let colors: [Color]
        switch widget {
        case .nowPlaying: colors = [Color(hex: 0x1ED760), Color(hex: 0x15803D)]
        case .systemStats: colors = [Color(hex: 0x1E1B4B), Color(hex: 0x064E3B)]
        case .agents: colors = [Color(hex: 0xF97316), Color(hex: 0xEA580C)]
        case .pomodoro: colors = [Mono.junkAccent, Color(hex: 0xB45309)]
        case .weather: colors = [Mono.gpuAccent, Color(hex: 0x2563EB)]
        case .batteries: colors = [Color(hex: 0x166534), Color(hex: 0x14532D)]
        case .calendar: colors = [Mono.dangerStrong, Color(hex: 0xB91C1C)]
        case .devly: colors = [Color(hex: 0x1D4ED8), Color(hex: 0x1E3A8A)]
        case .clipboard: colors = [Color(hex: 0x8B5CF6), Color(hex: 0x6D28D9)]
        case .audio: colors = [Color(hex: 0x3F3F46), Color(hex: 0x18181B)]
        case .notes: colors = [Color(hex: 0xEAB308), Color(hex: 0xCA8A04)]
        case .stayAwake: colors = [Color(hex: 0xEC4899), Color(hex: 0x9333EA)]
        case .translate: colors = [Mono.gpuAccent, Color(hex: 0x0284C7)]
        case .breather: colors = [Mono.healthy, Color(hex: 0x0D9488)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - Reorder & Toggle Helpers

    private func toggleWidget(_ widget: NotchWidgetID) {
        appState.toggleHomeWidget(widget)
    }

    private func moveWidget(at index: Int, by delta: Int) {
        var current = appState.settings.homeWidgets
        let target = index + delta
        guard current.indices.contains(index), current.indices.contains(target) else { return }
        withAnimation(Mono.betweenSpring) {
            current.swapAt(index, target)
            appState.settings.homeWidgets = current
        }
        AppKitHaptics.tap()
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        TimeFormat.clock(seconds)
    }
}

private struct WidgetReorderDropDelegate: DropDelegate {
    let target: NotchWidgetID
    @Binding var dragged: NotchWidgetID?
    @Binding var widgets: [NotchWidgetID]

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target,
              let from = widgets.firstIndex(of: dragged),
              let to = widgets.firstIndex(of: target) else { return }
        withAnimation(Mono.betweenSpring) {
            widgets.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
