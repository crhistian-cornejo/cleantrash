import AppKit
import CleanTrashCore
import SwiftUI

/// Droppy-style minimalist Spotify & Apple Music player inside the Notch:
/// Squircle album art, bold title + `[L]` synced lyrics badge, artist, subtle multi-color spectrum,
/// full-width thick pill scrubber (`1:04` — `-2:20`), large centered transport controls, and
/// expandable Karaoke Lyrics Theater with click-to-seek.
struct NotchMusicView: View {
    @Bindable var media: MediaPlayerController
    @Binding var showLyricsTheater: Bool

    @Environment(\.notchSurface) private var surface
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showVolumeSlider = false
    @State private var hoverScrubFraction: Double?

    private var accent: Color { media.palette.primary }
    private var secondaryAccent: Color { media.palette.secondary }

    var body: some View {
        if let track = media.track {
            VStack(spacing: 8) {
                if showLyricsTheater {
                    lyricsTheater(track)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 6)),
                            removal: .opacity
                        ))
                } else {
                    droppyPlayerMain(track)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(reduceMotion ? .none : Mono.openingSpring, value: showLyricsTheater)
        } else {
            emptyPlayerState
        }
    }

    // MARK: - Droppy Minimalist Music Player (Matches Reference Images 2 & 3)

    private func droppyPlayerMain(_ track: NowPlayingTrack) -> some View {
        VStack(spacing: 14) {
            // Top Row: Squircle Artwork + Title + [L] Lyrics Pill + Artist + Tiny Spectrum
            HStack(alignment: .center, spacing: 14) {
                albumArtwork(track, size: 62)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(track.title)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .contentTransition(.interpolate)

                        // Droppy signature [L] Lyrics badge right beside the track title
                        Button {
                            withAnimation(reduceMotion ? .none : Mono.openingSpring) {
                                showLyricsTheater = true
                            }
                        } label: {
                            Text("L")
                                .font(.system(size: 10.5, weight: .heavy))
                                .foregroundStyle(.black)
                                .frame(width: 20, height: 20)
                                .background(
                                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                        .fill(media.lyrics != nil ? Color.white : Color.white.opacity(0.65))
                                )
                        }
                        .buttonStyle(NotchButtonStyle(hoverScale: 1.1))
                        .help("Ver letras sincronizadas en vivo")
                    }

                    Text(track.artist)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 6)

                AudioVisualizerBars(
                    isPlaying: media.isPlaying,
                    color: accent,
                    secondaryColor: secondaryAccent,
                    barCount: 5,
                    maxHeight: 16,
                    barWidth: 2.5
                )
            }

            // Middle Row: Full-width Thick Pill Scrubber with timestamps on left & right (1:04 ━━━ -2:20)
            scrubberRow(track)

            // Bottom Row: Droppy Large Centered Transport Controls
            HStack(spacing: 0) {
                // Left: Lyrics / Queue button + Shuffle toggle
                HStack(spacing: 8) {
                    Button {
                        withAnimation(reduceMotion ? .none : Mono.openingSpring) {
                            showLyricsTheater = true
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.68))
                            .frame(width: 32, height: 32)
                            .contentShape(Circle())
                    }
                    .buttonStyle(NotchButtonStyle(hoverScale: 1.12))
                    .help("Letras sincronizadas")

                    Button {
                        media.toggleShuffle()
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(media.isShuffling ? accent : Color.white.opacity(0.45))
                            .frame(width: 26, height: 26)
                            .contentShape(Circle())
                    }
                    .buttonStyle(NotchButtonStyle(hoverScale: 1.1))
                    .help("Aleatorio")
                }

                Spacer(minLength: 8)

                // Center: Large crisp Previous · Play/Pause · Next
                HStack(spacing: 28) {
                    Button {
                        media.previousTrack()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .contentShape(Circle())
                    }
                    .buttonStyle(NotchButtonStyle(hoverScale: 1.12))
                    .help("Anterior")

                    Button {
                        media.togglePlayPause()
                    } label: {
                        Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: media.isPlaying ? 0 : 1.5)
                            .frame(width: 44, height: 42)
                            .contentShape(Circle())
                    }
                    .buttonStyle(NotchButtonStyle(hoverScale: 1.1))
                    .help(media.isPlaying ? "Pausar" : "Reproducir")

                    Button {
                        media.nextTrack()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .contentShape(Circle())
                    }
                    .buttonStyle(NotchButtonStyle(hoverScale: 1.12))
                    .help("Siguiente")
                }

                Spacer(minLength: 8)

                // Right: Repeat + Volume + Focus App (laptopcomputer like Image 2)
                HStack(spacing: 6) {
                    if showVolumeSlider {
                        Slider(
                            value: Binding(
                                get: { Double(media.volume) },
                                set: { media.setVolume(Int($0.rounded())) }
                            ),
                            in: 0...100
                        )
                        .tint(.white)
                        .controlSize(.mini)
                        .frame(width: 58)
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .trailing)))
                    } else {
                        Button {
                            media.toggleRepeat()
                        } label: {
                            Image(systemName: "repeat")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(media.isRepeating ? accent : Color.white.opacity(0.45))
                                .frame(width: 26, height: 26)
                                .contentShape(Circle())
                        }
                        .buttonStyle(NotchButtonStyle(hoverScale: 1.1))
                        .help("Repetir")
                    }

                    Button {
                        withAnimation(Mono.betweenSpring) { showVolumeSlider.toggle() }
                    } label: {
                        Image(systemName: volumeSymbol)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(showVolumeSlider ? 1 : 0.65))
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .buttonStyle(NotchButtonStyle(hoverScale: 1.1))
                    .help("Volumen (\(media.volume)%)")

                    Button {
                        media.openPlayerApp()
                    } label: {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.68))
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                    }
                    .buttonStyle(NotchButtonStyle(hoverScale: 1.1))
                    .help("Abrir \(track.source.rawValue)")
                }
            }

            // Live 1-line synced lyric strip right underneath (tap to open full Karaoke view)
            if let lyric = media.currentLyricLine ?? (media.isLoadingLyrics ? "Buscando letra sincronizada…" : nil) {
                Button {
                    withAnimation(reduceMotion ? .none : Mono.openingSpring) {
                        showLyricsTheater = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "quote.opening")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(accent)
                        Text(lyric)
                            .id("mini-\(media.activeLyricIndex ?? -1)-\(lyric)")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.76))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .transition(.asymmetric(
                                insertion: .blurMorph(scale: 0.96, y: 5),
                                removal: .blurMorph(scale: 0.96, y: -5)
                            ))
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .animation(reduceMotion ? .none : Mono.betweenSpring, value: media.activeLyricIndex)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Side-by-Side Synced Karaoke Lyrics Theater (Player Left | Lyrics Right + Artwork Ambient Glow!)

    private func lyricsTheater(_ track: NowPlayingTrack) -> some View {
        HStack(spacing: 16) {
            // LEFT COLUMN: Apple-Music-balanced Vertical Player beside the Lyrics
            VStack(spacing: 10) {
                albumArtwork(track, size: 88)
                    .shadow(color: accent.opacity(0.45), radius: 16, y: 6)

                VStack(spacing: 3) {
                    Button { media.openTrackInPlayer() } label: {
                        Text(track.title)
                            .font(.system(size: 14.5, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Abrir canción en \(track.source.rawValue)")

                    HStack(spacing: 7) {
                        Button { media.openArtistInPlayer() } label: {
                            Text(track.artist)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.68))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .help("Ver perfil de \(track.artist) en \(track.source.rawValue)")

                        AudioVisualizerBars(
                            isPlaying: media.isPlaying,
                            color: accent,
                            secondaryColor: secondaryAccent,
                            barCount: 4,
                            maxHeight: 11,
                            barWidth: 2.0
                        )
                    }
                }
                .frame(maxWidth: .infinity)

                Spacer(minLength: 2)

                scrubberRow(track)

                HStack(spacing: 0) {
                    Button { media.toggleShuffle() } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(media.isShuffling ? accent : Color.white.opacity(0.45))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(NotchButtonStyle(hoverScale: 1.1))

                    Spacer(minLength: 4)

                    HStack(spacing: 18) {
                        Button { media.previousTrack() } label: {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(NotchButtonStyle(hoverScale: 1.12))

                        Button { media.togglePlayPause() } label: {
                            Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 19, weight: .bold))
                                .foregroundStyle(.black)
                                .offset(x: media.isPlaying ? 0 : 1.5)
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(.white))
                                .shadow(color: accent.opacity(0.45), radius: 10)
                        }
                        .buttonStyle(NotchButtonStyle(hoverScale: 1.08))

                        Button { media.nextTrack() } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(NotchButtonStyle(hoverScale: 1.12))
                    }

                    Spacer(minLength: 4)

                    Button {
                        withAnimation(reduceMotion ? .none : Mono.openingSpring) {
                            showLyricsTheater = false
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.white.opacity(0.14)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(NotchButtonStyle(hoverScale: 1.1))
                    .help("Volver a los widgets del Home")
                }
            }
            .frame(width: 268)
            .padding(.vertical, 4)

            // Vertical luminous divider
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, accent.opacity(0.35), Color.white.opacity(0.14), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 1)
                .padding(.vertical, 10)

            // RIGHT COLUMN: Live Karaoke Synced Lyrics Panel
            ZStack {
                if media.isLoadingLyrics {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(accent)
                        Text("Cargando letras en vivo…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.65))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let doc = media.lyrics, doc.isSynced {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 11) {
                                Spacer().frame(height: 16)
                                ForEach(doc.syncedLines) { line in
                                    let activeIdx = media.activeLyricIndex
                                    let isActive = activeIdx == line.id
                                    let isPast = (activeIdx ?? -1) > line.id

                                    Button {
                                        media.seek(to: line.time)
                                    } label: {
                                        Text(line.text)
                                            .font(.system(size: isActive ? 18.5 : 13.5, weight: isActive ? .bold : .medium))
                                            .foregroundStyle(
                                                isActive
                                                    ? Color.white
                                                    : Color.white.opacity(isPast ? 0.28 : 0.50)
                                            )
                                            .shadow(color: isActive ? accent.opacity(0.65) : .clear, radius: isActive ? 12 : 0)
                                            .multilineTextAlignment(.leading)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .scaleEffect(isActive ? 1.0 : 0.97, anchor: .leading)
                                            .padding(.vertical, 2)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .pointingHandCursor()
                                    .id(line.id)
                                    .animation(reduceMotion ? .none : Mono.betweenSpring, value: isActive)
                                }
                                Spacer().frame(height: 44)
                            }
                            .padding(.horizontal, 12)
                        }
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black, location: 0.14),
                                    .init(color: .black, location: 0.84),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .onChange(of: media.activeLyricIndex) { _, newIdx in
                            guard let newIdx else { return }
                            withAnimation(reduceMotion ? .none : .easeInOut(duration: 0.42)) {
                                proxy.scrollTo(newIdx, anchor: .center)
                            }
                        }
                        .onAppear {
                            if let idx = media.activeLyricIndex {
                                proxy.scrollTo(idx, anchor: .center)
                            }
                        }
                    }
                } else if let doc = media.lyrics, !doc.plainLines.isEmpty {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(Array(doc.plainLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.84))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                    }
                } else if media.lyrics?.instrumental == true {
                    VStack(spacing: 6) {
                        Image(systemName: "pianokeys")
                            .font(.system(size: 22))
                            .foregroundStyle(accent)
                        Text("Pista instrumental")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "text.quote")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.white.opacity(0.45))
                        Text("No encontramos letra para esta canción")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Cuando la canción tenga letra sincronizada, podrás tocar cualquier verso para saltar a ese segundo.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.white.opacity(0.5))
                            .multilineTextAlignment(.center)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.24), secondaryAccent.opacity(0.14), Color.black.opacity(0.26)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                RadialGradient(
                    colors: [accent.opacity(0.32), .clear],
                    center: .leading,
                    startRadius: 10,
                    endRadius: 340
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [accent.opacity(0.42), Color.white.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }

    // MARK: - Album Artwork & Droppy Thick Pill Scrubber

    private func albumArtwork(_ track: NowPlayingTrack, size: CGFloat) -> some View {
        Button {
            media.openPlayerApp()
        } label: {
            ZStack {
                if let art = media.artwork {
                    Image(nsImage: art)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(
                        colors: [accent.opacity(0.78), secondaryAccent.opacity(0.62)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.36, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75)
            )
            .shadow(color: accent.opacity(media.isPlaying ? 0.32 : 0.1), radius: size > 50 ? 12 : 4, y: 3)
            .scaleEffect(media.isPlaying ? 1.0 : 0.94)
            .animation(reduceMotion ? .none : Mono.openingSpring, value: media.isPlaying)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Abrir \(track.source.rawValue)")
    }

    /// Droppy horizontal scrubber: `1:04  [━━━━━━──────────]  -2:20`
    private func scrubberRow(_ track: NowPlayingTrack) -> some View {
        let displayedProgress = hoverScrubFraction ?? media.progress
        let elapsed = media.isScrubbing ? media.scrubPreviewPosition : media.effectivePosition
        let remaining = max(0, track.duration - elapsed)

        return HStack(spacing: 10) {
            Text(Self.formatTime(elapsed))
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.55))
                .frame(minWidth: 32, alignment: .leading)

            GeometryReader { geo in
                let width = max(1, geo.size.width)
                let filled = width * min(1, max(0, displayedProgress))
                let barHeight: CGFloat = (media.isScrubbing || hoverScrubFraction != nil) ? 9 : 7

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                        .frame(height: barHeight)
                    Capsule()
                        .fill(Color.white.opacity(0.58))
                        .frame(width: max(barHeight, filled), height: barHeight)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let frac = min(1, max(0, value.location.x / width))
                            media.isScrubbing = true
                            media.scrubPreviewPosition = frac * track.duration
                            hoverScrubFraction = frac
                        }
                        .onEnded { value in
                            let frac = min(1, max(0, value.location.x / width))
                            hoverScrubFraction = nil
                            media.seek(to: frac * track.duration)
                        }
                )
            }
            .frame(height: 16)
            .pointingHandCursor()

            Text("-\(Self.formatTime(remaining))")
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.55))
                .frame(minWidth: 36, alignment: .trailing)
        }
    }

    private var volumeSymbol: String {
        if media.volume == 0 { return "speaker.slash.fill" }
        if media.volume < 45 { return "speaker.wave.1.fill" }
        if media.volume < 80 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private var emptyPlayerState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 52, height: 52)
                Image(systemName: "music.note")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 3) {
                Text("Sin música reproduciéndose")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Reproduce en Spotify o Apple Music para controlar aquí con portada, visualizador y letras [L] en vivo.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.white.opacity(0.52))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 350)
            }

            HStack(spacing: 10) {
                Button { media.openSpotify() } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: 0x1ED760)).frame(width: 7, height: 7)
                        Text("Abrir Spotify")
                            .font(.system(size: 11.5, weight: .bold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.white))
                }
                .buttonStyle(NotchButtonStyle())

                Button { media.openAppleMusic() } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: 0xFA243C)).frame(width: 7, height: 7)
                        Text("Apple Music")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.white.opacity(0.11)))
                }
                .buttonStyle(NotchButtonStyle())
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        TimeFormat.clock(seconds)
    }
}

// MARK: - Album-Colored Live Audio Visualizer

struct AudioVisualizerBars: View {
    let isPlaying: Bool
    let color: Color
    var secondaryColor: Color = .white
    var barCount: Int = 4
    var maxHeight: CGFloat = 14
    var barWidth: CGFloat = 2.6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.14, paused: !isPlaying || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.2) {
                ForEach(0..<barCount, id: \.self) { index in
                    let height = barHeight(for: index, time: t)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [color, secondaryColor],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: barWidth, height: height)
                        .animation(.easeInOut(duration: 0.16), value: height)
                }
            }
            .frame(height: maxHeight)
        }
    }

    private func barHeight(for index: Int, time: TimeInterval) -> CGFloat {
        guard isPlaying else { return max(2.8, maxHeight * 0.2) }
        if reduceMotion {
            let staticRatios: [CGFloat] = [0.42, 0.85, 0.62, 0.92, 0.50]
            return maxHeight * staticRatios[index % staticRatios.count]
        }
        let speed = 5.2 + Double(index) * 1.35
        let phase = Double(index) * 1.15
        let wave = (sin(time * speed + phase) + cos(time * (speed * 0.65) - phase)) * 0.25 + 0.5
        return max(2.8, maxHeight * CGFloat(0.22 + 0.78 * min(1, max(0, wave))))
    }
}
