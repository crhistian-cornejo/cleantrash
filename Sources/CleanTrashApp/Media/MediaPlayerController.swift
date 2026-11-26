import AppKit
import CleanTrashCore
import CoreGraphics
import Foundation
import Observation
import SwiftUI

enum MediaSource: String, Equatable, Sendable {
    case spotify = "Spotify"
    case appleMusic = "Apple Music"

    var bundleID: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .appleMusic: return "com.apple.Music"
        }
    }

    var accentColor: Color {
        switch self {
        case .spotify: return Color(hex: 0x1ED760)
        case .appleMusic: return Color(hex: 0xFA243C)
        }
    }
}

struct NowPlayingTrack: Equatable, Sendable {
    let id: String
    let source: MediaSource
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let artworkURL: String?
    let spotifyURL: String?

    var trackKey: String {
        LyricsService.trackKey(artist: artist, title: title)
    }
}

struct ArtworkPalette: Equatable {
    let primary: Color
    let secondary: Color

    static let neutral = ArtworkPalette(primary: Mono.infoAccent, secondary: Mono.networkAccent)
}

/// Live Spotify & Apple Music controller with album artwork color extraction, smooth position
/// interpolation, and synced karaoke lyrics powered by LRCLIB.
@MainActor
@Observable
final class MediaPlayerController {
    private(set) var track: NowPlayingTrack?
    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    private(set) var volume: Int = 75
    private(set) var isShuffling = false
    private(set) var isRepeating = false
    private(set) var artwork: NSImage?
    private(set) var palette: ArtworkPalette = .neutral

    // Synced lyrics state
    private(set) var lyrics: LyricsDocument?
    private(set) var isLoadingLyrics = false
    private(set) var lyricsTrackKey: String?

    /// While scrubbing, freeze incoming poll position updates so the thumb doesn't snap back.
    var isScrubbing = false
    var scrubPreviewPosition: TimeInterval = 0

    /// True when macOS Automation permission for Spotify/Music was denied (-1743).
    private(set) var automationDenied = false

    /// Briefly true after a track changes so the closed ear can morph smoothly.
    private(set) var lastTrackChangeAt: Date = .distantPast

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var interpolationTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var spotifyObserver: NSObjectProtocol?
    @ObservationIgnored private var musicObserver: NSObjectProtocol?
    @ObservationIgnored private var lastPositionAnchorDate: Date = .now
    @ObservationIgnored private var lastPositionAnchorValue: TimeInterval = 0
    @ObservationIgnored private var loadedArtworkURL: String?
    @ObservationIgnored private var isPreviewInjected = false

    var effectivePosition: TimeInterval {
        isScrubbing ? scrubPreviewPosition : position
    }

    var progress: Double {
        guard let track, track.duration > 0 else { return 0 }
        return min(1, max(0, effectivePosition / track.duration))
    }

    var activeLyricIndex: Int? {
        guard let lyrics, lyrics.isSynced else { return nil }
        return lyrics.activeLineIndex(at: effectivePosition)
    }

    var currentLyricLine: String? {
        guard let lyrics else { return nil }
        if let idx = activeLyricIndex, lyrics.syncedLines.indices.contains(idx) {
            let text = lyrics.syncedLines[idx].text
            return text == "♪" ? nil : text
        }
        return nil
    }

    var hasActiveTrack: Bool { track != nil }

    func start() {
        let dnc = DistributedNotificationCenter.default()
        spotifyObserver = dnc.addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo?.reduce(into: [String: String]()) { acc, pair in
                if let k = pair.key as? String { acc[k] = "\(pair.value)" }
            }
            Task { @MainActor [weak self] in
                if let info { self?.applyNotificationHint(source: .spotify, info: info) }
                await self?.refreshNow()
            }
        }

        musicObserver = dnc.addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo?.reduce(into: [String: String]()) { acc, pair in
                if let k = pair.key as? String { acc[k] = "\(pair.value)" }
            }
            Task { @MainActor [weak self] in
                if let info { self?.applyNotificationHint(source: .appleMusic, info: info) }
                await self?.refreshNow()
            }
        }

        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                if !self.isPreviewInjected {
                    await self.refreshNow()
                }
                let delay: Duration = SystemActivity.isIdle ? .seconds(10) : (self.isPlaying ? .seconds(2) : .seconds(4))
                try? await Task.sleep(for: delay)
            }
        }

        // Smooth 160 ms local position interpolation so progress & karaoke lyrics glide smoothly.
        interpolationTask?.cancel()
        interpolationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Glide only while something plays and someone can see it; otherwise check back lazily.
                let active = self?.isPlaying == true && !SystemActivity.isIdle
                try? await Task.sleep(for: active ? .milliseconds(160) : .seconds(1))
                guard let self, self.isPlaying, !self.isScrubbing, let track = self.track else { continue }
                let elapsed = Date.now.timeIntervalSince(self.lastPositionAnchorDate)
                let next = min(track.duration, max(0, self.lastPositionAnchorValue + elapsed))
                if abs(next - self.position) > 0.05 {
                    self.position = next
                }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        interpolationTask?.cancel()
        lyricsTask?.cancel()
        artworkTask?.cancel()
        let dnc = DistributedNotificationCenter.default()
        if let o = spotifyObserver { dnc.removeObserver(o) }
        if let o = musicObserver { dnc.removeObserver(o) }
    }

    // MARK: - Playback Polling (never launches closed apps)

    func refreshNow() async {
        guard !isPreviewInjected else { return }
        let spotifyRunning = isAppRunning(.spotify)
        let musicRunning = isAppRunning(.appleMusic)

        if !spotifyRunning && !musicRunning {
            clearTrack()
            return
        }

        var snapshot: PollResult?
        var denied = false
        if spotifyRunning {
            let outcome = await Task.detached(priority: .utility) {
                Self.querySpotify()
            }.value
            snapshot = outcome.result
            denied = outcome.automationDenied
        }

        // Fall back to Apple Music if Spotify isn't playing or returned nothing.
        if (snapshot == nil || snapshot?.isPlaying == false), musicRunning {
            let outcome = await Task.detached(priority: .utility) {
                Self.queryAppleMusic()
            }.value
            if let musicSnap = outcome.result, (snapshot == nil || musicSnap.isPlaying) {
                snapshot = musicSnap
                denied = false
            } else if outcome.automationDenied && snapshot == nil {
                denied = true
            }
        }

        automationDenied = denied
        if let snapshot {
            apply(snapshot)
        } else if !denied {
            clearTrack()
        }
    }

    /// Instant zero-latency update directly from Spotify/Music DistributedNotification userInfo
    /// (works even before AppleScript returns or while Automation permission is pending).
    private func applyNotificationHint(source: MediaSource, info: [String: String]) {
        let state = (info["Player State"] ?? "").lowercased()
        if state == "stopped" {
            if track?.source == source { clearTrack() }
            return
        }
        guard let name = info["Name"], !name.isEmpty else { return }
        let artist = info["Artist"] ?? ""
        let album = info["Album"] ?? ""
        let rawDur = Double((info["Duration"] ?? info["Total Time"] ?? "0").replacingOccurrences(of: ",", with: ".")) ?? 0
        let duration = rawDur > 2000 ? rawDur / 1000.0 : rawDur
        let pos = Double((info["Playback Position"] ?? "0").replacingOccurrences(of: ",", with: ".")) ?? position
        let id = info["Track ID"] ?? "\(source.rawValue):\(artist):\(name)"

        let hintTrack = NowPlayingTrack(
            id: id,
            source: source,
            title: name,
            artist: artist,
            album: album,
            duration: duration,
            artworkURL: track?.id == id ? track?.artworkURL : nil,
            spotifyURL: source == .spotify ? id : nil
        )
        let changed = track?.trackKey != hintTrack.trackKey
        track = hintTrack
        isPlaying = state == "playing"
        if !isScrubbing {
            position = pos
            lastPositionAnchorValue = pos
            lastPositionAnchorDate = .now
        }
        if changed {
            lastTrackChangeAt = .now
            loadLyrics(for: hintTrack)
        }
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func apply(_ snap: PollResult) {
        let previousKey = track?.trackKey
        let changedTrack = previousKey != snap.track.trackKey

        track = snap.track
        isPlaying = snap.isPlaying
        volume = snap.volume
        isShuffling = snap.shuffling
        isRepeating = snap.repeating

        if !isScrubbing {
            position = snap.position
            lastPositionAnchorValue = snap.position
            lastPositionAnchorDate = .now
        }

        if changedTrack {
            lastTrackChangeAt = .now
            loadLyrics(for: snap.track)
        }

        if let embeddedArt = snap.embeddedArtwork {
            if changedTrack || artwork == nil {
                artwork = embeddedArt
                extractPalette(from: embeddedArt)
            }
        } else if let urlString = snap.track.artworkURL, !urlString.isEmpty {
            if loadedArtworkURL != urlString {
                loadArtwork(from: urlString)
            }
        } else if changedTrack {
            artwork = nil
            palette = .neutral
        }
    }

    private func clearTrack() {
        guard track != nil else { return }
        track = nil
        isPlaying = false
        position = 0
        artwork = nil
        loadedArtworkURL = nil
        lyrics = nil
        lyricsTrackKey = nil
        palette = .neutral
    }

    private func isAppRunning(_ source: MediaSource) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).isEmpty
    }

    // MARK: - Controls

    func togglePlayPause() {
        guard let source = track?.source ?? activeSource() else {
            openSpotify()
            return
        }
        AppKitHaptics.tap()
        isPlaying.toggle()
        lastPositionAnchorValue = position
        lastPositionAnchorDate = .now

        Task.detached(priority: .userInitiated) {
            Self.runAppleScript(Self.commandScript(for: source, command: "playpause"))
            try? await Task.sleep(for: .milliseconds(200))
            await self.refreshNow()
        }
    }

    func nextTrack() {
        guard let source = track?.source ?? activeSource() else { return }
        AppKitHaptics.tap()
        Task.detached(priority: .userInitiated) {
            Self.runAppleScript(Self.commandScript(for: source, command: "next track"))
            try? await Task.sleep(for: .milliseconds(280))
            await self.refreshNow()
        }
    }

    func previousTrack() {
        guard let source = track?.source ?? activeSource() else { return }
        AppKitHaptics.tap()
        Task.detached(priority: .userInitiated) {
            Self.runAppleScript(Self.commandScript(for: source, command: "previous track"))
            try? await Task.sleep(for: .milliseconds(280))
            await self.refreshNow()
        }
    }

    func seek(to seconds: TimeInterval) {
        guard let track else { return }
        let clamped = min(max(0, seconds), max(1, track.duration))
        position = clamped
        lastPositionAnchorValue = clamped
        lastPositionAnchorDate = .now
        isScrubbing = false
        AppKitHaptics.tap()

        // AppleScript name is "Music", not the display name "Apple Music".
        let appName = track.source == .spotify ? "Spotify" : "Music"
        Task.detached(priority: .userInitiated) {
            let script = """
            tell application "\(appName)"
                set player position to \(String(format: "%.2f", clamped))
            end tell
            """
            Self.runAppleScript(script)
        }
    }

    func toggleShuffle() {
        guard let source = track?.source ?? activeSource() else { return }
        AppKitHaptics.tap()
        let next = !isShuffling
        isShuffling = next
        Task.detached(priority: .userInitiated) {
            let script: String
            switch source {
            case .spotify:
                script = "tell application \"Spotify\" to set shuffling to \(next ? "true" : "false")"
            case .appleMusic:
                script = "tell application \"Music\" to set shuffle enabled to \(next ? "true" : "false")"
            }
            Self.runAppleScript(script)
        }
    }

    func toggleRepeat() {
        guard let source = track?.source ?? activeSource() else { return }
        AppKitHaptics.tap()
        let next = !isRepeating
        isRepeating = next
        Task.detached(priority: .userInitiated) {
            let script: String
            switch source {
            case .spotify:
                script = "tell application \"Spotify\" to set repeating to \(next ? "true" : "false")"
            case .appleMusic:
                script = "tell application \"Music\" to set song repeat to \(next ? "all" : "off")"
            }
            Self.runAppleScript(script)
        }
    }

    func setVolume(_ value: Int) {
        guard let source = track?.source ?? activeSource() else { return }
        let clamped = min(100, max(0, value))
        volume = clamped
        Task.detached(priority: .userInitiated) {
            let appName = source == .spotify ? "Spotify" : "Music"
            Self.runAppleScript("tell application \"\(appName)\" to set sound volume to \(clamped)")
        }
    }

    func openPlayerApp() {
        let source = track?.source ?? .spotify
        openApp(source)
    }

    /// Opens the exact playing song/album directly inside Spotify (via `spotify:track:...` URI) or Apple Music.
    func openTrackInPlayer() {
        guard let track else {
            openPlayerApp()
            return
        }
        if track.source == .spotify {
            if let raw = track.spotifyURL, !raw.isEmpty,
               let url = URL(string: raw.hasPrefix("spotify:") || raw.hasPrefix("http") ? raw : "spotify:track:\(raw)") {
                NSWorkspace.shared.open(url)
                return
            }
            let query = "\(track.title) \(track.artist)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? track.title
            if let url = URL(string: "spotify:search:\(query)") {
                NSWorkspace.shared.open(url)
                return
            }
        } else {
            let query = "\(track.title) \(track.artist)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "music://search?term=\(query)") {
                NSWorkspace.shared.open(url)
                return
            }
        }
        openPlayerApp()
    }

    /// Opens the primary artist profile/search directly in Spotify or Apple Music.
    func openArtistInPlayer() {
        guard let track, !track.artist.isEmpty else {
            openPlayerApp()
            return
        }
        // Take the main artist before feat./comma so Spotify lands cleanly on their artist page
        let primaryArtist = track.artist
            .components(separatedBy: CharacterSet(charactersIn: ",&"))
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? track.artist

        if track.source == .spotify {
            let encoded = primaryArtist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? primaryArtist
            if let url = URL(string: "spotify:search:\(encoded)") {
                NSWorkspace.shared.open(url)
                return
            }
        } else {
            let encoded = primaryArtist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? primaryArtist
            if let url = URL(string: "music://search?term=\(encoded)") {
                NSWorkspace.shared.open(url)
                return
            }
        }
        openPlayerApp()
    }

    func openSpotify() { openApp(.spotify) }
    func openAppleMusic() { openApp(.appleMusic) }

    private func openApp(_ source: MediaSource) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func activeSource() -> MediaSource? {
        if isAppRunning(.spotify) { return .spotify }
        if isAppRunning(.appleMusic) { return .appleMusic }
        return nil
    }

    // MARK: - Artwork & Dominant Color

    private func loadArtwork(from urlString: String) {
        loadedArtworkURL = urlString
        artworkTask?.cancel()
        guard let url = URL(string: urlString) else { return }

        artworkTask = Task { [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled, let image = NSImage(data: data) else { return }
                let pal = await Task.detached(priority: .utility) {
                    Self.computePalette(from: image)
                }.value
                await MainActor.run { [weak self] in
                    guard let self, self.loadedArtworkURL == urlString else { return }
                    withAnimation(Mono.betweenSpring) {
                        self.artwork = image
                        self.palette = pal
                    }
                }
            } catch {
                // Keep previous or neutral placeholder
            }
        }
    }

    private func extractPalette(from image: NSImage) {
        Task { [weak self] in
            let pal = await Task.detached(priority: .utility) {
                Self.computePalette(from: image)
            }.value
            await MainActor.run { [weak self] in
                withAnimation(Mono.betweenSpring) {
                    self?.palette = pal
                }
            }
        }
    }

    private nonisolated static func computePalette(from image: NSImage) -> ArtworkPalette {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .neutral
        }
        let size = 16
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return .neutral
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var bestSat: Double = -1
        var bestPrimary = (r: 0.38, g: 0.65, b: 0.98)
        var secondPrimary = (r: 0.65, g: 0.55, b: 0.98)
        var rSum = 0.0, gSum = 0.0, bSum = 0.0, count = 0.0

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255.0
            let g = Double(pixels[i + 1]) / 255.0
            let b = Double(pixels[i + 2]) / 255.0
            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let sat = maxC > 0 ? (maxC - minC) / maxC : 0

            rSum += r; gSum += g; bSum += b; count += 1

            // Prefer vibrant mid-bright pixels so the glow looks luminous on dark glass.
            if luma > 0.18 && luma < 0.88 {
                let score = sat * (0.6 + 0.4 * luma)
                if score > bestSat {
                    secondPrimary = bestPrimary
                    bestSat = score
                    bestPrimary = (r, g, b)
                }
            }
        }

        if bestSat < 0.12 && count > 0 {
            bestPrimary = (max(0.35, rSum / count), max(0.35, gSum / count), max(0.35, bSum / count))
        }

        // Lift dark accents slightly so equalizer bars & glow pop cleanly.
        func boost(_ c: (r: Double, g: Double, b: Double)) -> Color {
            let luma = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
            let factor = luma < 0.38 ? (0.45 / max(0.12, luma)) : 1.0
            return Color(
                red: min(1.0, c.r * factor),
                green: min(1.0, c.g * factor),
                blue: min(1.0, c.b * factor)
            )
        }

        return ArtworkPalette(primary: boost(bestPrimary), secondary: boost(secondPrimary))
    }

    // MARK: - Synced Lyrics

    private func loadLyrics(for track: NowPlayingTrack) {
        let key = track.trackKey
        guard lyricsTrackKey != key else { return }
        lyricsTrackKey = key
        lyrics = nil
        isLoadingLyrics = true
        lyricsTask?.cancel()

        lyricsTask = Task { [weak self] in
            let doc = await LyricsService.shared.fetchLyrics(
                artist: track.artist,
                title: track.title,
                album: track.album,
                duration: track.duration
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.lyricsTrackKey == key else { return }
                self.lyrics = doc
                self.isLoadingLyrics = false
            }
        }
    }

    // MARK: - AppleScript Queries (off main thread)

    private struct PollResult: Sendable {
        let track: NowPlayingTrack
        let isPlaying: Bool
        let position: TimeInterval
        let volume: Int
        let shuffling: Bool
        let repeating: Bool
        let embeddedArtwork: NSImage?
    }

    private struct PollOutcome: Sendable {
        let result: PollResult?
        let automationDenied: Bool
    }

    private nonisolated static func commandScript(for source: MediaSource, command: String) -> String {
        let appName = source == .spotify ? "Spotify" : "Music"
        return "tell application \"\(appName)\" to \(command)"
    }

    private nonisolated static func querySpotify() -> PollOutcome {
        // NOTE: Do NOT name AppleScript variables `st` (reserved ordinal suffix -> syntax error -2741).
        let script = """
        tell application "Spotify"
            set pState to player state as string
            if pState is "stopped" then return ""
            set pPos to player position
            set pVol to sound volume
            set pShuf to shuffling
            set pRep to repeating
            set trk to current track
            set tId to id of trk
            set tName to name of trk
            set tArt to artist of trk
            set tAlb to album of trk
            set tDur to duration of trk
            set tArtURL to artwork url of trk
            set tSpotURL to spotify url of trk
            return pState & "|||" & pPos & "|||" & pVol & "|||" & pShuf & "|||" & pRep & "|||" & tId & "|||" & tName & "|||" & tArt & "|||" & tAlb & "|||" & tDur & "|||" & tArtURL & "|||" & tSpotURL
        end tell
        """
        let exec = runAppleScriptDetailed(script)
        if exec.automationDenied {
            return PollOutcome(result: nil, automationDenied: true)
        }
        guard let output = exec.output, !output.isEmpty else {
            return PollOutcome(result: nil, automationDenied: false)
        }
        let parts = output.components(separatedBy: "|||")
        guard parts.count >= 12 else { return PollOutcome(result: nil, automationDenied: false) }

        let state = parts[0].lowercased()
        let isPlaying = state == "playing"
        let position = Double(parts[1].replacingOccurrences(of: ",", with: ".")) ?? 0
        let volume = Int(parts[2]) ?? 75
        let shuffling = parts[3].lowercased() == "true"
        let repeating = parts[4].lowercased() == "true"
        let id = parts[5]
        let title = parts[6]
        let artist = parts[7]
        let album = parts[8]
        let rawDur = Double(parts[9].replacingOccurrences(of: ",", with: ".")) ?? 0
        // Spotify reports duration in milliseconds (e.g., 214500)
        let duration = rawDur > 2000 ? rawDur / 1000.0 : rawDur
        let artworkURL = parts[10].isEmpty ? nil : parts[10]
        let spotifyURL = parts[11].isEmpty ? nil : parts[11]

        guard !title.isEmpty else { return PollOutcome(result: nil, automationDenied: false) }

        return PollOutcome(
            result: PollResult(
                track: NowPlayingTrack(
                    id: id,
                    source: .spotify,
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration,
                    artworkURL: artworkURL,
                    spotifyURL: spotifyURL
                ),
                isPlaying: isPlaying,
                position: position,
                volume: volume,
                shuffling: shuffling,
                repeating: repeating,
                embeddedArtwork: nil
            ),
            automationDenied: false
        )
    }

    private nonisolated static func queryAppleMusic() -> PollOutcome {
        let script = """
        tell application "Music"
            set pState to player state as string
            if pState is "stopped" then return ""
            set pPos to player position
            set pVol to sound volume
            set pShuf to shuffle enabled
            set pRep to (song repeat as string)
            set trk to current track
            set tId to database ID of trk as string
            set tName to name of trk
            set tArt to artist of trk
            set tAlb to album of trk
            set tDur to duration of trk
            return pState & "|||" & pPos & "|||" & pVol & "|||" & pShuf & "|||" & pRep & "|||" & tId & "|||" & tName & "|||" & tArt & "|||" & tAlb & "|||" & tDur
        end tell
        """
        let exec = runAppleScriptDetailed(script)
        if exec.automationDenied {
            return PollOutcome(result: nil, automationDenied: true)
        }
        guard let output = exec.output, !output.isEmpty else {
            return PollOutcome(result: nil, automationDenied: false)
        }
        let parts = output.components(separatedBy: "|||")
        guard parts.count >= 10 else { return PollOutcome(result: nil, automationDenied: false) }

        let state = parts[0].lowercased()
        let isPlaying = state == "playing"
        let position = Double(parts[1].replacingOccurrences(of: ",", with: ".")) ?? 0
        let volume = Int(parts[2]) ?? 75
        let shuffling = parts[3].lowercased() == "true"
        let repeating = parts[4].lowercased() != "off"
        let title = parts[6]
        guard !title.isEmpty else { return PollOutcome(result: nil, automationDenied: false) }

        let duration = Double(parts[9].replacingOccurrences(of: ",", with: ".")) ?? 0

        return PollOutcome(
            result: PollResult(
                track: NowPlayingTrack(
                    id: "music:\(parts[5])",
                    source: .appleMusic,
                    title: title,
                    artist: parts[7],
                    album: parts[8],
                    duration: duration,
                    artworkURL: nil,
                    spotifyURL: nil
                ),
                isPlaying: isPlaying,
                position: position,
                volume: volume,
                shuffling: shuffling,
                repeating: repeating,
                embeddedArtwork: queryAppleMusicArtwork()
            ),
            automationDenied: false
        )
    }

    private nonisolated static func queryAppleMusicArtwork() -> NSImage? {
        let script = """
        tell application "Music"
            if (count of artworks of current track) > 0 then
                return raw data of artwork 1 of current track
            end if
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return NSImage(data: result.data)
    }

    @discardableResult
    private nonisolated static func runAppleScript(_ source: String) -> String? {
        runAppleScriptDetailed(source).output
    }

    private nonisolated static func runAppleScriptDetailed(_ source: String) -> (output: String?, automationDenied: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let errText = String(data: errData, encoding: .utf8) ?? ""
                let denied = errText.contains("-1743") || errText.localizedCaseInsensitiveContains("Not authorized")
                return (nil, denied)
            }
            let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (out, false)
        } catch {
            return (nil, false)
        }
    }

    #if DEBUG
    func injectPreview() {
        isPreviewInjected = true
        track = NowPlayingTrack(
            id: "spotify:preview",
            source: .spotify,
            title: "Midnight City",
            artist: "M83",
            album: "Hurry Up, We're Dreaming",
            duration: 243,
            artworkURL: nil,
            spotifyURL: nil
        )
        isPlaying = true
        position = 64
        volume = 82
        palette = ArtworkPalette(primary: Color(hex: 0xF472B6), secondary: Mono.cpuAccent)
        lyrics = LyricsDocument(
            trackKey: "m83::midnight city",
            syncedLines: [
                LyricLine(id: 0, time: 52, text: "Waiting in a car"),
                LyricLine(id: 1, time: 58, text: "Waiting for a ride in the dark"),
                LyricLine(id: 2, time: 63, text: "The night city grows"),
                LyricLine(id: 3, time: 69, text: "Look and see her eyes, they glow"),
                LyricLine(id: 4, time: 76, text: "Waiting in a car")
            ]
        )
        lyricsTrackKey = "m83::midnight city"
    }
    #endif
}
