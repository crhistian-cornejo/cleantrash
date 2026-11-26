import AppKit
import CleanTrashCore
import SwiftUI
import UniformTypeIdentifiers

private enum HubClipboardFilter: String, CaseIterable, Identifiable {
    case all = "Todos"
    case pinned = "Fijados"
    case colors = "Colores"

    var id: String { rawValue }
}

/// Full desktop workspace mirroring the new Dynamic Glass Notch & Droppy suite:
/// Spotify/Apple Music + Synced Karaoke Lyrics + Floating Mini-Player, Drag-in/out File Shelf
/// (Zip, AirDrop, PNG↔JPG, Vision OCR), Rich Clipboard Cards, Focus Pomodoro, Stay Awake,
/// Devly Tools, Quick Notes, Weather, Bluetooth Batteries, Calendar, Master Audio & Live AI Agents.
struct NotchHubView: View {
    @Bindable var appState: AppState
    let onToggleNotch: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isDropTargeted = false
    @State private var isZipping = false
    @State private var clipFilter: HubClipboardFilter = .all
    @State private var hoverScrubFraction: Double?
    @State private var devlyMode: DevlyMode = .base64
    @State private var devlyInput: String = ""
    @State private var devlyOutput: String = ""
    @State private var devlyCopied = false

    private var hub: ProductivityHub { appState.productivity }
    private var media: MediaPlayerController { appState.media }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerRow
                musicAndLyricsRow
                shelfAndClipboardRow
                breatherAndTranslateRow
                modulesBentoRow
                environmentStrip
            }
            .padding(20)
        }
        .onAppear { hub.isHubVisible = true }
        .onDisappear { hub.isHubVisible = false }
    }

    // MARK: - Header + Quick Notch Surface Controls

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Icon3D(name: .notch, size: 54)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Notch")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Mono.ink(scheme))
                    MonoTag(text: appState.settings.notchSurface.label, tint: Mono.gpuAccent)
                }
                Text("Música, bandeja, notas y herramientas del Notch.")
                    .font(.system(size: 13))
                    .foregroundStyle(Mono.muted(scheme))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // Quick Translate pill
            Button {
                hub.quickTranslate.toggle(surface: appState.settings.notchSurface)
                AppKitHaptics.tap()
            } label: {
                Label("Traducir", systemImage: "translate")
            }
            .buttonStyle(MonoGhostButtonStyle())
            .help("Abrir traductor rápido en este Mac (⌥⇧T)")

            // Floating Mini-Player pop-out
            Button {
                hub.floatingPlayer.toggle(media: media, surface: appState.settings.notchSurface)
                AppKitHaptics.tap()
            } label: {
                Label("Mini flotante", systemImage: "pip.enter")
            }
            .buttonStyle(MonoGhostButtonStyle())
            .help("Mostrar u ocultar el mini-reproductor flotante (3 tamaños)")

            // Full-Screen StandBy / Spotify Ambient Mode
            Button {
                hub.standBy.toggle(appState: appState)
                AppKitHaptics.tap()
            } label: {
                Label("StandBy", systemImage: "sparkles.tv")
            }
            .buttonStyle(MonoGhostButtonStyle())
            .help("Pantalla completa Spotify Karaoke y Widgets arrastrables (⌥⇧L)")

            Button {
                appState.settingsPane = .notch
                appState.selectedSection = .settings
            } label: {
                Label("Personalizar", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(MonoGhostButtonStyle())
            .help("Estilo, widgets y lo que se ve junto a la cámara")

            Button {
                onToggleNotch()
                AppKitHaptics.tap()
            } label: {
                Label("Abrir Notch", systemImage: "rectangle.topthird.inset.filled")
            }
            .buttonStyle(MonoPrimaryButtonStyle())
        }
    }

    // MARK: - Breather + Quick Translate Interactive Row

    private var breatherAndTranslateRow: some View {
        let br = hub.breather
        let tr = hub.quickTranslate.state
        return HStack(spacing: 14) {
            // Breather 20-20-20 Card
            HStack(spacing: 14) {
                BreatherConcentricRings(
                    eyesProgress: br.eyesProgress,
                    stretchProgress: br.stretchProgress,
                    waterProgress: br.waterProgress,
                    centerText: br.isBreakActive ? "\(br.activeBreakSecondsLeft)s" : "\(br.totalDoneToday)",
                    size: 62
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Breather · 20-20-20")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Mono.ink(scheme))
                        MonoTag(text: "🔥 \(br.streakDays)d", tint: Mono.junkAccent)
                        if br.isSilencedByCall {
                            MonoTag(text: "EN LLAMADA", tint: Mono.caution)
                        }
                    }
                    Text(br.isBreakActive
                         ? "\(br.nextBreakKind.rawValue) — \(br.nextBreakKind.subtitle)"
                         : "Siguiente: \(br.nextBreakKind.rawValue) en \(br.minutesUntilNextBreak) min")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Mono.muted(scheme))
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        Text("Ojos \(br.eyesDone)/6").foregroundStyle(BreatherBreakKind.eyes.tint)
                        Text("Estirar \(br.stretchDone)/3").foregroundStyle(BreatherBreakKind.stretch.tint)
                        Text("Agua \(br.waterDone)/4").foregroundStyle(BreatherBreakKind.water.tint)
                    }
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                }

                Spacer(minLength: 4)

                VStack(spacing: 6) {
                    Button(br.isBreakActive ? "Completar" : "Pausar ahora") {
                        if br.isBreakActive { br.completeBreak() } else { br.startBreakNow() }
                    }
                    .buttonStyle(MonoPrimaryButtonStyle())

                    Button(br.isPaused ? "Reanudar" : "Pausar timer") {
                        br.togglePause()
                    }
                    .buttonStyle(MonoGhostButtonStyle())
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 112)
            .monoCard(radius: 16)

            // Quick Translate On-Device Card
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Mono.gpuAccent.opacity(0.16)).frame(width: 48, height: 48)
                    Image(systemName: "translate")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Mono.gpuAccent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Traductor rápido")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Mono.ink(scheme))
                        MonoTag(text: "EN ESTE MAC", tint: Mono.gpuAccent)
                    }
                    Text("\(tr.sourceLanguage.label) → \(tr.targetLanguage.label) · 100% local con Apple Translation")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Mono.muted(scheme))
                        .lineLimit(1)
                    Text("Atajo: ⌥⇧T · Copia o reemplaza directo en tu app.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Mono.subtle(scheme))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button("Abrir traductor") {
                    hub.quickTranslate.show(surface: appState.settings.notchSurface, seedFromClipboard: true)
                }
                .buttonStyle(MonoPrimaryButtonStyle())
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 112)
            .monoCard(radius: 16)
        }
    }

    // MARK: - Row 1: Droppy Music Player + Synced Karaoke Lyrics Theater

    private var musicAndLyricsRow: some View {
        HStack(alignment: .top, spacing: 14) {
            musicPlayerCard
                .frame(maxWidth: .infinity)
            lyricsTheaterCard
                .frame(maxWidth: .infinity)
        }
    }

    private var musicPlayerCard: some View {
        let accent = media.hasActiveTrack ? media.palette.primary : Mono.cpuAccent
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(media.isPlaying ? Mono.healthy : Mono.subtle(scheme)).frame(width: 7, height: 7)
                    Text(media.track?.source.rawValue ?? "Música")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(Mono.muted(scheme))
                }
                Spacer()
                if media.hasActiveTrack {
                    AudioVisualizerBars(
                        isPlaying: media.isPlaying,
                        color: accent,
                        secondaryColor: media.palette.secondary,
                        barCount: 5,
                        maxHeight: 14,
                        barWidth: 2.4
                    )
                }
            }

            if let track = media.track {
                HStack(spacing: 14) {
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
                                        .font(.system(size: 24, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                        )
                        .shadow(color: accent.opacity(0.28), radius: 14, y: 6)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Button { media.openTrackInPlayer() } label: {
                                Text(track.title)
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(Mono.ink(scheme))
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                            .help("Abrir canción en \(track.source.rawValue)")
                        }
                        Button { media.openArtistInPlayer() } label: {
                            Text(track.artist)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Mono.muted(scheme))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .help("Ver perfil de \(track.artist) en \(track.source.rawValue)")
                        if !track.album.isEmpty {
                            Text(track.album)
                                .font(.system(size: 11))
                                .foregroundStyle(Mono.subtle(scheme))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                }

                // Interactive Thick Pill Scrubber
                scrubberRow(track, accent: accent)

                // Transport Controls
                HStack(spacing: 0) {
                    Button { media.toggleShuffle() } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(media.isShuffling ? accent : Mono.muted(scheme))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()

                    Spacer()

                    HStack(spacing: 22) {
                        Button { media.previousTrack() } label: {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Mono.ink(scheme))
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()

                        Button { media.togglePlayPause() } label: {
                            Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Mono.primaryInk(scheme))
                                .offset(x: media.isPlaying ? 0 : 1.5)
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(Mono.primaryFill(scheme)))
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()

                        Button { media.nextTrack() } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Mono.ink(scheme))
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }

                    Spacer()

                    Button { media.toggleRepeat() } label: {
                        Image(systemName: "repeat")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(media.isRepeating ? accent : Mono.muted(scheme))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            } else if media.automationDenied {
                VStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Image(systemName: "lock.shield")
                        .font(.system(size: 24))
                        .foregroundStyle(Mono.caution)
                    Text("Autoriza el control de Spotify / Música")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Mono.ink(scheme))
                    Text("macOS necesita permiso de Automatización para leer la canción y letras.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Mono.muted(scheme))
                        .multilineTextAlignment(.center)
                    Button("Abrir Automatización") { media.openAutomationSettings() }
                        .buttonStyle(MonoPrimaryButtonStyle())
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Image(systemName: "music.note.list")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Mono.muted(scheme))
                    Text("Reproduce música en Spotify o Apple Music")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Mono.ink(scheme))
                    HStack(spacing: 8) {
                        Button("Abrir Spotify") { media.openSpotify() }
                            .buttonStyle(MonoPrimaryButtonStyle())
                        Button("Abrir Música") { media.openAppleMusic() }
                            .buttonStyle(MonoGhostButtonStyle())
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(18)
        .frame(height: 236, alignment: .topLeading)
        .monoCard(radius: 18, glass: true)
    }

    private func scrubberRow(_ track: NowPlayingTrack, accent: Color) -> some View {
        let frac = hoverScrubFraction ?? media.progress
        let elapsed = media.isScrubbing ? media.scrubPreviewPosition : media.effectivePosition
        let remaining = max(0, track.duration - elapsed)
        return HStack(spacing: 8) {
            Text(formatTime(elapsed))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(Mono.muted(scheme))
                .frame(width: 34, alignment: .leading)
            GeometryReader { geo in
                let w = max(1, geo.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(Mono.ink(scheme).opacity(0.14)).frame(height: 6)
                    Capsule().fill(accent).frame(width: max(6, w * frac), height: 6)
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
            Text("-\(formatTime(remaining))")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(Mono.muted(scheme))
                .frame(width: 38, alignment: .trailing)
        }
    }

    private var lyricsTheaterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "quote.bubble.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Mono.cpuAccent)
                    Text("Letras sincronizadas")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(Mono.muted(scheme))
                }
                Spacer()
                if media.lyrics?.isSynced == true {
                    MonoTag(text: "KARAOKE · CLIC PARA IR", tint: Mono.ramAccent)
                }
            }

            if media.isLoadingLyrics {
                VStack(spacing: 8) {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Text("Buscando letras sincronizadas…")
                        .font(.system(size: 12))
                        .foregroundStyle(Mono.muted(scheme))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if let doc = media.lyrics, !doc.syncedLines.isEmpty {
                let activeIdx = media.activeLyricIndex
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(doc.syncedLines.enumerated()), id: \.offset) { idx, line in
                                let isActive = idx == activeIdx
                                Button {
                                    media.seek(to: line.time)
                                } label: {
                                    Text(line.text)
                                        .font(.system(size: isActive ? 15.5 : 13, weight: isActive ? .bold : .medium))
                                        .foregroundStyle(
                                            isActive
                                                ? Mono.ink(scheme)
                                                : Mono.muted(scheme).opacity(idx < (activeIdx ?? 0) ? 0.52 : 0.72)
                                        )
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 2)
                                }
                                .buttonStyle(.plain)
                                .pointingHandCursor()
                                .id(idx)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: activeIdx) { _, newIdx in
                        guard let newIdx else { return }
                        withAnimation(reduceMotion ? .none : Mono.betweenSpring) {
                            proxy.scrollTo(newIdx, anchor: .center)
                        }
                    }
                }
            } else if let doc = media.lyrics, !doc.plainLines.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(doc.plainLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Mono.ink(scheme).opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 6)
                }
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "text.quote")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Mono.subtle(scheme))
                    Text(media.hasActiveTrack ? "Sin letras sincronizadas para esta canción" : "Reproduce una canción para ver las letras en vivo")
                        .font(.system(size: 12))
                        .foregroundStyle(Mono.muted(scheme))
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(18)
        .frame(height: 236, alignment: .topLeading)
        .monoCard(radius: 18, glass: true)
    }

    // MARK: - Row 2: Droppy File Shelf + Rich Clipboard Cards

    private var shelfAndClipboardRow: some View {
        HStack(alignment: .top, spacing: 14) {
            fileShelfCard
                .frame(maxWidth: .infinity)
            clipboardCard
                .frame(maxWidth: .infinity)
        }
    }

    private var fileShelfCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Mono.appsAccent)
                Text("Bandeja de archivos (\(hub.shelfItems.count))")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(Mono.muted(scheme))
                Spacer()

                Button {
                    Task { await hub.captureScreenText() }
                } label: {
                    Label("OCR Pantalla", systemImage: "text.viewfinder")
                }
                .buttonStyle(MonoGhostButtonStyle())
                .help("Capturar texto de la pantalla con Apple Vision")

                Button {
                    Task {
                        let ok = await hub.ocrClipboardImage()
                        if !ok {
                            appState.report("Copia primero una captura o imagen (⌘⇧⌃4) para extraer texto sin permisos.", tone: .info)
                        }
                    }
                } label: {
                    Label("OCR Clip", systemImage: "doc.viewfinder")
                }
                .buttonStyle(MonoGhostButtonStyle())
                .help("Extraer texto de una captura en el portapapeles (sin permiso de pantalla)")
            }

            if hub.shelfItems.isEmpty {
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Image(systemName: isDropTargeted ? "arrow.down.circle.fill" : "tray.and.arrow.down")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(isDropTargeted ? Mono.appsAccent : Mono.muted(scheme))
                    Text(isDropTargeted ? "Suelta aquí para guardar en tu Bandeja" : "Arrastra archivos, imágenes o apps aquí")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Mono.ink(scheme))
                    Text("Comprime en Zip, comparte por AirDrop, convierte PNG↔JPG o extrae texto OCR.")
                        .font(.system(size: 11))
                        .foregroundStyle(Mono.muted(scheme))
                        .multilineTextAlignment(.center)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isDropTargeted ? Mono.appsAccent : Mono.hairlineStrong(scheme),
                            style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])
                        )
                )
            } else {
                HStack(spacing: 6) {
                    Button {
                        Task {
                            isZipping = true
                            _ = await hub.zipShelfItems(hub.shelfItems)
                            isZipping = false
                        }
                    } label: {
                        Label(isZipping ? "Comprimiendo…" : "Zip", systemImage: "doc.zipper")
                    }
                    .buttonStyle(MonoGhostButtonStyle())
                    .disabled(isZipping)

                    Button {
                        hub.shareShelfItems(hub.shelfItems)
                    } label: {
                        Label("AirDrop", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(MonoGhostButtonStyle())

                    Spacer()

                    Button("Vaciar") { hub.clearShelf() }
                        .buttonStyle(MonoGhostButtonStyle())
                }

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(hub.shelfItems) { item in
                            shelfItemRow(item)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(height: 236, alignment: .topLeading)
        .monoCard(radius: 16)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers: providers)
        }
    }

    private func shelfItemRow(_ item: ShelfItem) -> some View {
        let ext = item.url.pathExtension.lowercased()
        let isImage = ["png", "jpg", "jpeg", "heic", "webp", "tiff"].contains(ext)
        return HStack(spacing: 9) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Mono.ink(scheme))
                    .lineLimit(1)
                Text(ByteFormat.compact(item.sizeBytes))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Mono.muted(scheme))
            }
            Spacer()
            if isImage {
                Button("OCR") {
                    Task { await hub.ocrImageItem(item) }
                }
                .buttonStyle(MonoGhostButtonStyle())
                Button(ext == "png" ? "→ JPG" : "→ PNG") {
                    hub.convertImageItem(item, toPNG: ext != "png")
                }
                .buttonStyle(MonoGhostButtonStyle())
            }
            Button {
                hub.removeShelfItem(item)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Mono.muted(scheme))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Mono.ink(scheme).opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Mono.ink(scheme).opacity(0.045)))
        .draggable(item.url)
    }

    private var clipboardCard: some View {
        let entries: [ClipboardEntry] = hub.clipboardEntries.filter { entry in
            switch clipFilter {
            case .all: return true
            case .pinned: return entry.isPinned
            case .colors: return entry.kind == .color
            }
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(HubClipboardFilter.allCases) { f in
                    let selected = clipFilter == f
                    Button(f.rawValue) {
                        withAnimation(Mono.betweenSpring) { clipFilter = f }
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(selected ? Mono.primaryInk(scheme) : Mono.muted(scheme))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(selected ? Mono.primaryFill(scheme) : Mono.ink(scheme).opacity(0.08)))
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
                Spacer()
                if !hub.clipboardEntries.isEmpty {
                    Button("Limpiar") { hub.clearUnpinnedClipboard() }
                        .buttonStyle(MonoGhostButtonStyle())
                }
            }

            if entries.isEmpty {
                VStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Mono.muted(scheme))
                    Text("Tu portapapeles aparecerá aquí")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Mono.ink(scheme))
                    Text("Copia texto, enlaces, colores HEX o imágenes (las contraseñas se ignoran).")
                        .font(.system(size: 11))
                        .foregroundStyle(Mono.muted(scheme))
                        .multilineTextAlignment(.center)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(entries.prefix(16)) { entry in
                            richClipCard(entry)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(16)
        .frame(height: 236, alignment: .topLeading)
        .monoCard(radius: 16)
    }

    private func richClipCard(_ entry: ClipboardEntry) -> some View {
        let isColor = entry.kind == .color && entry.hexColor != nil
        let colorFill = entry.hexColor.flatMap { Color(hexString: $0) }
        let cardFill: Color = colorFill ?? Mono.ink(scheme).opacity(scheme == .dark ? 0.06 : 0.05)
        let badgeFg: Color = isColor ? .black : Mono.ink(scheme)
        let badgeBg: Color = isColor ? Color.white.opacity(0.88) : Mono.ink(scheme).opacity(0.11)
        let pinFg: Color = entry.isPinned ? Mono.junkAccent : (isColor ? Color.black.opacity(0.7) : Mono.muted(scheme))
        let footerFg: Color = isColor ? Color.white.opacity(0.85) : Mono.muted(scheme)
        let footerText: String = hub.lastCopiedEntryID == entry.id
            ? "Copiado ✓"
            : (entry.imageDimensions ?? "\(entry.previewText.count) car.")

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(kindLabel(entry.kind))
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(badgeFg)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(badgeBg))
                Spacer()
                Button {
                    hub.togglePin(entry)
                } label: {
                    Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10))
                        .foregroundStyle(pinFg)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            clipCardBody(entry, isColor: isColor)

            Spacer(minLength: 0)

            HStack {
                Text(footerText)
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(footerFg)
                Spacer()
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(isColor ? .white : Mono.muted(scheme))
            }
        }
        .padding(11)
        .frame(width: 158, height: 164, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(cardFill))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Mono.hairline(scheme), lineWidth: 0.9))
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture {
            hub.copyBack(entry)
        }
        .pointingHandCursor()
    }

    @ViewBuilder
    private func clipCardBody(_ entry: ClipboardEntry, isColor: Bool) -> some View {
        if entry.kind == .image, let data = entry.imageData, let nsImg = NSImage(data: data) {
            Image(nsImage: nsImg)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 136, height: 82)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if isColor, let hex = entry.hexColor {
            Spacer(minLength: 0)
            Text(hex.uppercased())
                .font(.system(size: 16, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 3)
        } else {
            Text(entry.previewText)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Mono.ink(scheme))
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Row 3: Focus Pomodoro · Devly Tools · Quick Notes

    private var modulesBentoRow: some View {
        HStack(alignment: .top, spacing: 14) {
            focusAndAwakeCard
                .frame(maxWidth: .infinity)
            devlyCard
                .frame(maxWidth: .infinity)
            notesCard
                .frame(maxWidth: .infinity)
        }
    }

    private var focusAndAwakeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Focus & Despierto", systemImage: "timer")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Mono.muted(scheme))
                Spacer()
                Button {
                    hub.toggleStayAwake()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: hub.isStayAwakeEnabled ? "cup.and.saucer.fill" : "cup.and.saucer")
                            .font(.system(size: 10.5))
                        Text(hub.isStayAwakeEnabled ? "Despierto" : "Reposo normal")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(hub.isStayAwakeEnabled ? .black : Mono.muted(scheme))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(hub.isStayAwakeEnabled ? Mono.junkAccent : Mono.ink(scheme).opacity(0.08)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            HStack(alignment: .center, spacing: 12) {
                Text(hub.timerFormatted)
                    .font(.system(size: 32, weight: .bold).monospacedDigit())
                    .foregroundStyle(hub.isTimerRunning ? Mono.junkAccent : Mono.ink(scheme))
                    .contentTransition(.numericText())
                Spacer()
                Button {
                    hub.toggleTimer()
                } label: {
                    Image(systemName: hub.isTimerRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Mono.primaryInk(scheme))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Mono.primaryFill(scheme)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                Button {
                    hub.resetTimer()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Mono.ink(scheme))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Mono.ink(scheme).opacity(0.09)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            MonoProgressBar(value: hub.timerProgress, height: 4.5, tint: Mono.junkAccent)

            HStack(spacing: 6) {
                ForEach(FocusPreset.defaults) { preset in
                    focusPresetChip(preset)
                }
            }
        }
        .padding(16)
        .frame(height: 196, alignment: .topLeading)
        .monoCard(radius: 16)
    }

    private func focusPresetChip(_ preset: FocusPreset) -> some View {
        let isMatch = hub.timerLabel == preset.label && hub.timerTotalSeconds == preset.minutes * 60
        let fg: Color = isMatch ? Mono.primaryInk(scheme) : Mono.muted(scheme)
        let bg: Color = isMatch ? Mono.primaryFill(scheme) : Mono.ink(scheme).opacity(0.08)
        return Button("\(preset.minutes)m") {
            hub.startPreset(preset)
        }
        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
        .foregroundStyle(fg)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(bg))
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private var devlyCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Devly Tools", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Mono.muted(scheme))
                Spacer()
                Button("Pegar") {
                    if let str = NSPasteboard.general.string(forType: .string) {
                        devlyInput = str
                        runDevly()
                    }
                }
                .buttonStyle(MonoGhostButtonStyle())
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(DevlyMode.allCases, id: \.self) { mode in
                        let selected = devlyMode == mode
                        Button(mode.rawValue) {
                            devlyMode = mode
                            runDevly()
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(selected ? Mono.primaryInk(scheme) : Mono.muted(scheme))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(selected ? Mono.primaryFill(scheme) : Mono.ink(scheme).opacity(0.08)))
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                }
            }

            TextField("Entrada (Base64, JSON, JWT, URL…)", text: $devlyInput)
                .textFieldStyle(.plain)
                .font(.system(size: 11).monospaced())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Mono.ink(scheme).opacity(0.06)))
                .onChange(of: devlyInput) { _, _ in runDevly() }

            HStack {
                Text(devlyOutput.isEmpty ? "Resultado listo al instante…" : devlyOutput)
                    .font(.system(size: 10.5).monospaced())
                    .foregroundStyle(devlyOutput.isEmpty ? Mono.subtle(scheme) : Mono.ramAccent)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(devlyCopied ? "✓" : "Copiar") {
                    guard !devlyOutput.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(devlyOutput, forType: .string)
                    devlyCopied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        devlyCopied = false
                    }
                }
                .buttonStyle(MonoGhostButtonStyle())
                .disabled(devlyOutput.isEmpty)
            }
        }
        .padding(16)
        .frame(height: 196, alignment: .topLeading)
        .monoCard(radius: 16)
    }

    private var notesCard: some View {
        let activeNote = hub.quickNotes.first(where: { $0.id == hub.selectedNoteID }) ?? hub.quickNotes.first
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Notas rápidas", systemImage: "note.text")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Mono.muted(scheme))
                Spacer()
                Button {
                    _ = hub.createNote()
                } label: {
                    Label("Nueva", systemImage: "plus")
                }
                .buttonStyle(MonoGhostButtonStyle())
            }

            if let note = activeNote {
                if hub.quickNotes.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(hub.quickNotes) { item in
                                let sel = item.id == note.id
                                Button(item.title) {
                                    hub.selectedNoteID = item.id
                                }
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                                .foregroundStyle(sel ? Mono.primaryInk(scheme) : Mono.muted(scheme))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(sel ? Mono.primaryFill(scheme) : Mono.ink(scheme).opacity(0.08)))
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                TextEditor(text: Binding(
                    get: { note.body },
                    set: { hub.updateNote(id: note.id, body: $0) }
                ))
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10).fill(Mono.ink(scheme).opacity(0.05)))
            } else {
                Spacer(minLength: 0)
                Button("Crear primera nota") { _ = hub.createNote() }
                    .buttonStyle(MonoGhostButtonStyle())
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(height: 196, alignment: .topLeading)
        .monoCard(radius: 16)
    }

    // MARK: - Row 4: Live Environment Strip (Weather · Master Audio · Bluetooth Batteries · Calendar · AI Agents)

    private var environmentStrip: some View {
        HStack(spacing: 14) {
            // Weather
            HStack(spacing: 12) {
                Image(systemName: hub.weather?.symbol ?? "cloud.sun.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Mono.gpuAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hub.weather.map { "\($0.city) · \($0.tempC)°" } ?? "Clima")
                        .font(.system(size: 13.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(Mono.ink(scheme))
                    Text(hub.weather.map { "\($0.condition) · Máx \($0.highC)° Mín \($0.lowC)°" } ?? "Cargando clima local…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Mono.muted(scheme))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .monoCard(radius: 14)

            // Master Audio
            HStack(spacing: 10) {
                Button { hub.toggleMasterMute() } label: {
                    Image(systemName: hub.isMasterMuted || hub.masterVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(hub.isMasterMuted ? Mono.danger : Mono.ramAccent)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Mono.ink(scheme).opacity(0.08)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(hub.audioOutputName)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Mono.ink(scheme))
                            .lineLimit(1)
                        Spacer()
                        Text("\(hub.masterVolume)%")
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                            .foregroundStyle(Mono.muted(scheme))
                    }
                    Slider(
                        value: Binding(
                            get: { Double(hub.masterVolume) },
                            set: { hub.setMasterVolume(Int($0)) }
                        ),
                        in: 0...100
                    )
                    .controlSize(.mini)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .monoCard(radius: 14)

            // AI Agents / Bluetooth Batteries
            HStack(spacing: 10) {
                let activeAgents = appState.agents.sessions.count
                Image(systemName: activeAgents > 0 ? "sparkles" : "calendar")
                    .font(.system(size: 18))
                    .foregroundStyle(activeAgents > 0 ? Mono.cpuAccent : Mono.junkAccent)
                VStack(alignment: .leading, spacing: 2) {
                    if activeAgents > 0 {
                        Text("\(activeAgents) agente\(activeAgents == 1 ? "" : "s") IA en vivo")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Mono.ink(scheme))
                        Text(appState.agents.sessions.prefix(2).map(\.source.displayName).joined(separator: " · "))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Mono.muted(scheme))
                            .lineLimit(1)
                    } else if let nextEv = hub.calendarEvents.first {
                        Text(nextEv.title)
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(Mono.ink(scheme))
                            .lineLimit(1)
                        Text(nextEv.timeRange)
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(Mono.muted(scheme))
                    } else {
                        Text("Agenda y Agentes IA")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(Mono.ink(scheme))
                        Text(hub.calendarAuthorized ? "Sin eventos pendientes hoy" : "Conecta Calendario para ver tu agenda")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Mono.muted(scheme))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if !hub.calendarAuthorized && activeAgents == 0 {
                    Button("Conectar") {
                        Task { await hub.requestCalendarAccess() }
                    }
                    .buttonStyle(MonoGhostButtonStyle())
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .monoCard(radius: 14)
        }
    }

    // MARK: - Helpers

    private func runDevly() {
        if devlyMode == .uuid {
            devlyOutput = DevlyTools.encode("", mode: .uuid)
        } else if devlyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            devlyOutput = ""
        } else {
            devlyOutput = DevlyTools.encode(devlyInput, mode: devlyMode)
        }
    }

    private func kindLabel(_ kind: ClipboardEntryKind) -> String {
        switch kind {
        case .text: return "Texto"
        case .url: return "Enlace"
        case .color: return "Color"
        case .image: return "Imagen"
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        TimeFormat.clock(seconds)
    }

    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
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
                    guard let url else { return }
                    Task { @MainActor in
                        hub.addFiles([url])
                    }
                }
            }
        }
        return accepted
    }
}
