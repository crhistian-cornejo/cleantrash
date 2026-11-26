import AppKit
import CleanTrashCore
import Foundation
import SwiftUI

/// Native Full-Screen Ambient / StandBy Canvas (`⌥⇧L`) built with 100% documented AppKit/SwiftUI APIs:
/// - **Spotify / Música Full-Screen**: lush artwork-colored ambient backdrop, Lock-Screen-style clock,
///   large glowing album cover, transport controls, scrubber, and live synced Karaoke lyrics.
/// - **Widgets Arrastrables**: freely positionable frosted glass cards mirroring your live Notch widgets
///   (Clock, Music, CPU/RAM/GPU, Weather, Batteries, Pomodoro, Breather, Agents) with persistent positions.
@MainActor
final class AmbientStandByController {
    private var window: NSWindow?
    private var keyMonitor: Any?

    var isVisible: Bool { window?.isVisible ?? false }

    func toggle(appState: AppState) {
        if isVisible {
            close()
        } else {
            show(appState: appState)
        }
    }

    func show(appState: AppState) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let w = StandByKeyWindow(
            contentRect: frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = true
        w.backgroundColor = NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.07, alpha: 1.0)
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)

        let root = AmbientStandByView(
            appState: appState,
            screenSize: frame.size,
            onClose: { [weak self] in self?.close() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        w.contentView = hosting

        w.alphaValue = 0
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            w.animator().alphaValue = 1.0
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                Task { @MainActor [weak self] in self?.close() }
                return nil
            }
            if event.keyCode == 49 { // Space: play/pause in StandBy
                Task { @MainActor in appState.media.togglePlayPause() }
                return nil
            }
            return event
        }

        self.window = w
    }

    func close() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
        guard let w = window else { return }
        window = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.20
            w.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                w.orderOut(nil)
            }
        })
    }
}

/// Borderless window subclass that can become key so `Esc` and `Space` work seamlessly.
private final class StandByKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private enum StandByMode: String, CaseIterable {
    case music = "Música"
    case widgets = "Widgets"
}

private struct AmbientStandByView: View {
    @Bindable var appState: AppState
    let screenSize: CGSize
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mode: StandByMode
    @State private var hoverScrubFraction: Double?
    @State private var widgetPositions: [String: CGPoint] = [:]
    @State private var activeDragStart: [String: CGPoint] = [:]

    private static let positionsKey = "CleanTrash.StandByWidgetPositions.v1"

    init(appState: AppState, screenSize: CGSize, onClose: @escaping () -> Void) {
        self.appState = appState
        self.screenSize = screenSize
        self.onClose = onClose
        _mode = State(initialValue: appState.media.hasActiveTrack ? .music : .widgets)
    }

    private var media: MediaPlayerController { appState.media }
    private var accent: Color { media.hasActiveTrack ? media.palette.primary : Color(hex: 0x6366F1) }
    private var secondary: Color { media.hasActiveTrack ? media.palette.secondary : Mono.gpuAccent }

    var body: some View {
        ZStack {
            // Ambient track-tinted full-screen backdrop
            ambientBackdrop

            VStack(spacing: 0) {
                if mode == .music {
                    musicFullScreenCanvas
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    draggableWidgetsCanvas
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Discreet bottom floating control pill
            VStack {
                Spacer()
                bottomToolbar
                    .padding(.bottom, 28)
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .environment(\.colorScheme, .dark)
        .onAppear {
            loadSavedPositions()
        }
    }

    // MARK: - Ambient Artwork Backdrop

    private var ambientBackdrop: some View {
        ZStack {
            Color(hex: 0x05060A)

            LinearGradient(
                colors: [
                    accent.opacity(0.42),
                    secondary.opacity(0.24),
                    Color(hex: 0x06070C).opacity(0.92)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [accent.opacity(0.36), .clear],
                center: UnitPoint(x: 0.24, y: 0.36),
                startRadius: 20,
                endRadius: max(420, screenSize.width * 0.45)
            )

            RadialGradient(
                colors: [secondary.opacity(0.26), .clear],
                center: UnitPoint(x: 0.78, y: 0.68),
                startRadius: 20,
                endRadius: max(380, screenSize.width * 0.42)
            )
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: media.track?.id)
    }

    // MARK: - 1. Spotify / Music Full-Screen Karaoke Mode

    private var musicFullScreenCanvas: some View {
        let hasLyrics = media.lyrics?.syncedLines.isEmpty == false
        return VStack(spacing: 28) {
            // Lock-Screen-style large thin clock & date
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                VStack(spacing: 4) {
                    Text(Self.formattedDate(context.date))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                    Text(Self.formattedTime(context.date))
                        .font(.system(size: 64, weight: .thin).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.94))
                }
            }
            .padding(.top, 46)

            Spacer(minLength: 10)

            if let track = media.track {
                HStack(alignment: .center, spacing: 56) {
                    // Left / Center Player Column
                    VStack(spacing: 18) {
                        Button { media.openTrackInPlayer() } label: {
                            ZStack {
                                if let art = media.artwork {
                                    Image(nsImage: art)
                                        .resizable()
                                        .interpolation(.high)
                                        .aspectRatio(contentMode: .fill)
                                } else {
                                    LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
                                        .overlay {
                                            Image(systemName: "music.note")
                                                .font(.system(size: 64, weight: .bold))
                                                .foregroundStyle(.white.opacity(0.9))
                                        }
                                }
                            }
                            .frame(width: 240, height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 26, style: .continuous)
                                    .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                            )
                            .shadow(color: accent.opacity(0.45), radius: 36, y: 14)
                            .shadow(color: .black.opacity(0.5), radius: 22, y: 12)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()

                        VStack(spacing: 5) {
                            Button { media.openTrackInPlayer() } label: {
                                Text(track.title)
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()

                            HStack(spacing: 8) {
                                Button { media.openArtistInPlayer() } label: {
                                    Text(track.artist)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.72))
                                        .lineLimit(1)
                                }
                                .buttonStyle(.plain)
                                .pointingHandCursor()

                                AudioVisualizerBars(
                                    isPlaying: media.isPlaying,
                                    color: accent,
                                    secondaryColor: secondary,
                                    barCount: 4,
                                    maxHeight: 14,
                                    barWidth: 2.4
                                )
                            }
                        }
                        .frame(maxWidth: 360)

                        standByScrubber(track)
                            .frame(width: 340)

                        HStack(spacing: 28) {
                            Button { media.toggleShuffle() } label: {
                                Image(systemName: "shuffle")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(media.isShuffling ? accent : .white.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()

                            Button { media.previousTrack() } label: {
                                Image(systemName: "backward.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()

                            Button { media.togglePlayPause() } label: {
                                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundStyle(.black)
                                    .offset(x: media.isPlaying ? 0 : 2)
                                    .frame(width: 58, height: 58)
                                    .background(Circle().fill(.white))
                                    .shadow(color: accent.opacity(0.42), radius: 14, y: 4)
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()

                            Button { media.nextTrack() } label: {
                                Image(systemName: "forward.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()

                            Button { media.toggleRepeat() } label: {
                                Image(systemName: "repeat")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(media.isRepeating ? accent : .white.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                        }
                    }

                    // Right Karaoke Lyrics Column (when synced lyrics exist)
                    if hasLyrics, let doc = media.lyrics {
                        let activeIdx = media.activeLyricIndex
                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: false) {
                                LazyVStack(alignment: .leading, spacing: 18) {
                                    Spacer().frame(height: 60)
                                    ForEach(Array(doc.syncedLines.enumerated()), id: \.offset) { idx, line in
                                        let isActive = idx == activeIdx
                                        Button { media.seek(to: line.time) } label: {
                                            Text(line.text)
                                                .font(.system(size: isActive ? 28 : 20, weight: isActive ? .bold : .semibold))
                                                .foregroundStyle(isActive ? .white : .white.opacity(0.32))
                                                .shadow(color: isActive ? accent.opacity(0.55) : .clear, radius: 14)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .multilineTextAlignment(.leading)
                                                .animation(Mono.betweenSpring, value: isActive)
                                        }
                                        .buttonStyle(.plain)
                                        .pointingHandCursor()
                                        .id(idx)
                                    }
                                    Spacer().frame(height: 120)
                                }
                                .padding(.horizontal, 12)
                            }
                            .mask(
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0.0),
                                        .init(color: .black, location: 0.14),
                                        .init(color: .black, location: 0.84),
                                        .init(color: .clear, location: 1.0)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: min(500, screenSize.width * 0.42), height: min(460, screenSize.height * 0.56))
                            .onChange(of: activeIdx) { _, newIdx in
                                guard let newIdx else { return }
                                withAnimation(Mono.betweenSpring) {
                                    proxy.scrollTo(newIdx, anchor: .center)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 56)
            } else {
                VStack(spacing: 12) {
                    Icon3D(name: .notch, size: 78, isActive: true)
                    Text("Abre Spotify o Apple Music para ver el modo pantalla completa")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.74))
                    Button("Cambiar a Widgets arrastrables") {
                        withAnimation(Mono.openingSpring) { mode = .widgets }
                    }
                    .buttonStyle(MonoPrimaryButtonStyle())
                }
            }

            Spacer(minLength: 64)
        }
    }

    private func standByScrubber(_ track: NowPlayingTrack) -> some View {
        let frac = hoverScrubFraction ?? media.progress
        let elapsed = media.isScrubbing ? media.scrubPreviewPosition : media.effectivePosition
        let remaining = max(0, track.duration - elapsed)

        return HStack(spacing: 10) {
            Text(Self.formatTrackTime(elapsed))
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 38, alignment: .leading)

            GeometryReader { geo in
                let w = max(1, geo.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.20)).frame(height: 6)
                    Capsule().fill(Color.white.opacity(0.92)).frame(width: max(6, w * frac), height: 6)
                }
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
            .frame(height: 16)
            .pointingHandCursor()

            Text("-\(Self.formatTrackTime(remaining))")
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 42, alignment: .trailing)
        }
    }

    // MARK: - 2. Draggable Freeform Widgets Canvas (Notch Widgets Positioned Anywhere)

    private var draggableWidgetsCanvas: some View {
        ZStack {
            // Subtle hint at top
            VStack {
                Text("Arrastra cualquier widget a donde prefieras · las posiciones se guardan automáticamente")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 24)
                Spacer()
            }
            .allowsHitTesting(false)

            // 1. Clock Card
            draggableCard(id: "clock", defaultPosition: CGPoint(x: screenSize.width * 0.50, y: screenSize.height * 0.22)) {
                TimelineView(.periodic(from: .now, by: 1.0)) { context in
                    VStack(spacing: 4) {
                        Text(Self.formattedDate(context.date))
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.65))
                        Text(Self.formattedTime(context.date))
                            .font(.system(size: 56, weight: .thin).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 16)
                }
            }

            // 2. Music Card
            draggableCard(id: "music", defaultPosition: CGPoint(x: screenSize.width * 0.26, y: screenSize.height * 0.54)) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Group {
                            if let art = media.artwork {
                                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
                                    .overlay { Image(systemName: "music.note").foregroundStyle(.white) }
                            }
                        }
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(media.track?.title ?? "Sin reproducción")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(media.currentLyricLine ?? media.track?.artist ?? "Spotify / Apple Music")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(0.66))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        AudioVisualizerBars(isPlaying: media.isPlaying, color: accent, secondaryColor: secondary, barCount: 4, maxHeight: 14, barWidth: 2)
                    }

                    HStack(spacing: 22) {
                        Spacer()
                        Button { media.previousTrack() } label: { Image(systemName: "backward.fill").font(.system(size: 15)).foregroundStyle(.white) }.buttonStyle(.plain)
                        Button { media.togglePlayPause() } label: {
                            Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(.white))
                        }.buttonStyle(.plain)
                        Button { media.nextTrack() } label: { Image(systemName: "forward.fill").font(.system(size: 15)).foregroundStyle(.white) }.buttonStyle(.plain)
                        Spacer()
                    }
                }
                .padding(16)
                .frame(width: 300)
            }

            // 3. System Vitals Card (CPU · RAM · GPU)
            draggableCard(id: "system", defaultPosition: CGPoint(x: screenSize.width * 0.52, y: screenSize.height * 0.54)) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sistema en vivo")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.56))
                    HStack(spacing: 18) {
                        vitalRing("CPU", pct: appState.telemetry.cpuTotalPercent, icon: .cpu, tint: Mono.cpuAccent)
                        vitalRing("RAM", pct: appState.telemetry.memory.usedPercent, icon: .memory, tint: Mono.ramAccent)
                        vitalRing("GPU", pct: appState.telemetry.gpu.deviceUtilizationPercent, icon: .gpu, tint: Mono.gpuAccent)
                    }
                }
                .padding(16)
                .frame(width: 266)
            }

            // 4. Weather / Breather Card
            draggableCard(id: "weather", defaultPosition: CGPoint(x: screenSize.width * 0.76, y: screenSize.height * 0.54)) {
                if let w = appState.productivity.weather {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(w.city)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.78))
                            Spacer()
                            Image(systemName: w.symbol)
                                .font(.system(size: 18))
                                .foregroundStyle(.white)
                        }
                        Text("\(w.tempC)°")
                            .font(.system(size: 36, weight: .light).monospacedDigit())
                            .foregroundStyle(.white)
                        Text("\(w.condition) · H:\(w.highC)° L:\(w.lowC)°")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.68))
                    }
                    .padding(16)
                    .frame(width: 230)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Breather · 20-20-20")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Mono.ramAccent)
                        Text("Descanso en \(appState.productivity.breather.minutesUntilNextBreak) min")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                        Text("\(appState.productivity.breather.totalDoneToday)/\(appState.productivity.breather.totalGoalToday) pausas hoy")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .padding(16)
                    .frame(width: 230)
                }
            }

            // 5. Batteries / Focus Card
            draggableCard(id: "focus", defaultPosition: CGPoint(x: screenSize.width * 0.50, y: screenSize.height * 0.77)) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Focus · \(appState.productivity.timerLabel)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(appState.productivity.timerFormatted)
                            .font(.system(size: 24, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                    Button(appState.productivity.isTimerRunning ? "Pausar" : "Iniciar") {
                        appState.productivity.toggleTimer()
                    }
                    .buttonStyle(MonoPrimaryButtonStyle())

                    Divider().frame(height: 28).overlay(Color.white.opacity(0.16))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Batería Mac")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text("\(Int(appState.telemetry.battery.percent))%")
                            .font(.system(size: 20, weight: .bold).monospacedDigit())
                            .foregroundStyle(Mono.healthy)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func vitalRing(_ label: String, pct: Double, icon: Icon3DName, tint: Color) -> some View {
        VStack(spacing: 4) {
            MetricRing3D(icon: icon, percent: pct, tint: tint, size: 46)
            Text("\(Int(pct))%")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(tint)
        }
    }

    private func draggableCard<Content: View>(
        id: String,
        defaultPosition: CGPoint,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let pos = widgetPositions[id] ?? defaultPosition
        return content()
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(hex: 0x10131C).opacity(0.68))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.36), radius: 18, y: 10)
            .position(pos)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let start = activeDragStart[id] ?? pos
                        if activeDragStart[id] == nil { activeDragStart[id] = start }
                        let nx = min(max(80, start.x + value.translation.width), screenSize.width - 80)
                        let ny = min(max(60, start.y + value.translation.height), screenSize.height - 90)
                        widgetPositions[id] = CGPoint(x: nx, y: ny)
                    }
                    .onEnded { _ in
                        activeDragStart[id] = nil
                        savePositions()
                    }
            )
    }

    // MARK: - Bottom Control Pill

    private var bottomToolbar: some View {
        HStack(spacing: 8) {
            ForEach(StandByMode.allCases, id: \.self) { m in
                let selected = mode == m
                Button {
                    withAnimation(Mono.betweenSpring) { mode = m }
                    AppKitHaptics.tap()
                } label: {
                    Label(m.rawValue, systemImage: m == .music ? "music.note" : "square.grid.2x2")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? .black : .white.opacity(0.84))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(selected ? Color.white : Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            if mode == .widgets {
                Button {
                    withAnimation(Mono.openingSpring) {
                        widgetPositions.removeAll()
                        UserDefaults.standard.removeObject(forKey: Self.positionsKey)
                    }
                    AppKitHaptics.tap()
                } label: {
                    Label("Ordenar", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            Button(action: onClose) {
                Label("Salir (Esc)", systemImage: "xmark")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color(hex: 0x0E1017).opacity(0.82)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.9))
        .shadow(color: .black.opacity(0.42), radius: 14, y: 6)
    }

    // MARK: - Persistence & Formatters

    private func loadSavedPositions() {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: [Double]] else { return }
        var loaded: [String: CGPoint] = [:]
        for (k, coords) in dict where coords.count == 2 {
            loaded[k] = CGPoint(x: coords[0], y: coords[1])
        }
        widgetPositions = loaded
    }

    private func savePositions() {
        var dict: [String: [Double]] = [:]
        for (k, pt) in widgetPositions {
            dict[k] = [Double(pt.x), Double(pt.y)]
        }
        UserDefaults.standard.set(dict, forKey: Self.positionsKey)
    }

    private static func formattedTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private static func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "EEEE, d 'de' MMMM"
        return f.string(from: date).capitalized
    }

    private static func formatTrackTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
