import AppKit
import CleanTrashCore
import SwiftUI

// MARK: - Official provider logos

/// Each agent's own app icon, read from the installed app (Claude, Codex, Antigravity).
@MainActor
enum ProviderLogoStore {
    private static var cache: [AgentSource: NSImage] = [:]
    private static var missing: Set<AgentSource> = []

    static func image(_ source: AgentSource) -> NSImage? {
        if let hit = cache[source] { return hit }
        if missing.contains(source) { return nil }
        guard let image = load(source) else {
            missing.insert(source)
            return nil
        }
        cache[source] = image
        return image
    }

    private static func load(_ source: AgentSource) -> NSImage? {
        let workspace = NSWorkspace.shared
        switch source {
        case .claude:
            return appIcon("com.anthropic.claudefordesktop")
        case .codex:
            // The Codex desktop app ships its own mark next to the ChatGPT one.
            if let url = workspace.urlForApplication(withBundleIdentifier: "com.openai.codex") {
                let mark = url.appendingPathComponent("Contents/Resources/icon-codex-dark-color.png")
                if let image = NSImage(contentsOf: mark) { return image }
                return workspace.icon(forFile: url.path)
            }
            return appIcon("com.openai.chat")
        case .antigravity:
            return appIcon("com.google.antigravity")
        }
    }

    private static func appIcon(_ bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Provider logo cropped to its squircle (macOS icons carry ~10% transparent margin), with the
/// glyph badge as fallback when the app isn't installed.
struct ProviderLogo: View {
    let source: AgentSource
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let image = ProviderLogoStore.image(source) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(1.22)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(source.tint.opacity(0.18))
                    Image(systemName: source.glyph)
                        .font(.system(size: size * 0.46, weight: .bold))
                        .foregroundStyle(source.tint)
                }
                .frame(width: size, height: size)
            }
        }
        .accessibilityLabel(source.displayName)
    }
}

// MARK: - Smooth Marquee Carousel Text (for long song titles, artists & lyrics inside Notch ears)

struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    var speed: Double = 24 // pts per second
    var pauseDuration: Double = 1.6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    private var needsScroll: Bool {
        !Mono.snapshotMode && !reduceMotion && textWidth > containerWidth + 4 && containerWidth > 10
    }

    var body: some View {
        GeometryReader { geo in
            let availW = geo.size.width
            ZStack(alignment: .leading) {
                if needsScroll {
                    let gap: CGFloat = 28
                    let cycleDistance = textWidth + gap
                    let scrollDuration = Double(cycleDistance) / max(10, speed)
                    let totalCycle = pauseDuration + scrollDuration

                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: max(0.5, totalCycle))
                        let progress = max(0, (t - pauseDuration) / max(0.1, scrollDuration))
                        let offsetX = -CGFloat(progress) * cycleDistance

                        HStack(spacing: gap) {
                            Text(text).font(font).foregroundStyle(color).fixedSize()
                            Text(text).font(font).foregroundStyle(color).fixedSize()
                        }
                        .offset(x: offsetX)
                    }
                } else {
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(width: availW, alignment: .leading)
            .clipped()
            .mask(
                Group {
                    if needsScroll {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .black, location: 0.07),
                                .init(color: .black, location: 0.90),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    } else {
                        Color.black
                    }
                }
            )
            .onAppear { containerWidth = availW }
            .onChange(of: availW) { _, newW in containerWidth = newW }
        }
        .frame(height: 15)
        .background(
            Text(text)
                .font(font)
                .fixedSize()
                .hidden()
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { textWidth = proxy.size.width }
                            .onChange(of: text) { _, _ in textWidth = proxy.size.width }
                            .onChange(of: proxy.size.width) { _, w in textWidth = w }
                    }
                )
        )
    }
}

// MARK: - Left ear: live metrics

/// RAM · CPU · GPU with their 3D glass icons, refined compact spacing so the closed notch
/// never crowds the concave curve or the system menu bar.
struct NotchMetricsEar: View {
    let memory: Double
    let cpu: Double
    let gpu: Double

    var body: some View {
        HStack(spacing: 5.5) {
            metric(.memory, memory, label: "RAM")
            metric(.cpu, cpu, label: "CPU")
            metric(.gpu, gpu, label: "GPU")
        }
    }

    private func metric(_ icon: Icon3DName, _ value: Double, label: String) -> some View {
        let percent = Int(min(999, max(0, value)).rounded())
        return HStack(spacing: 2) {
            Icon3D(name: icon, size: 15)
            Text("\(percent)%")
                .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                .foregroundStyle(Self.tint(value))
                .contentTransition(.numericText(value: Double(percent)))
                .lineLimit(1)
                .fixedSize()
        }
        .animation(Mono.betweenSpring, value: percent)
        .help("\(label) \(percent)%")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(percent) por ciento")
    }

    static func tint(_ value: Double) -> Color {
        if value >= 92 { return Mono.danger }
        if value >= 80 { return Mono.caution }
        return Color.white.opacity(0.86)
    }
}

// MARK: - Right ear (Music): Mini Album Artwork + Live Lyric / Track + Equalizer

struct NotchMusicEar: View {
    let media: MediaPlayerController
    let showLyrics: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var labelKey: String {
        if showLyrics, let lyric = media.currentLyricLine {
            return "lyric:\(media.activeLyricIndex ?? -1):\(lyric)"
        }
        return "track:\(media.track?.id ?? ""):\(media.track?.title ?? "")"
    }

    private var displayedText: String {
        if showLyrics, let lyric = media.currentLyricLine {
            return lyric
        }
        return media.track?.title ?? ""
    }

    var body: some View {
        if let track = media.track {
            HStack(spacing: 6) {
                Group {
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
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 0.6)
                )

                ZStack(alignment: .leading) {
                    Text(displayedText)
                        .id(labelKey)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(
                            showLyrics && media.currentLyricLine != nil
                                ? Color.white.opacity(0.95)
                                : Color.white.opacity(0.86)
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .transition(.asymmetric(
                            insertion: .blurMorph(scale: 0.92, y: 6),
                            removal: .blurMorph(scale: 0.92, y: -6)
                        ))
                }
                .animation(reduceMotion ? .none : Mono.betweenSpring, value: labelKey)

                Spacer(minLength: 2)

                AudioVisualizerBars(
                    isPlaying: media.isPlaying,
                    color: media.palette.primary,
                    secondaryColor: media.palette.secondary,
                    barCount: 3,
                    maxHeight: 11,
                    barWidth: 2
                )
            }
            .help("\(track.title) — \(track.artist)")
        }
    }
}

struct NotchTimerEar: View {
    let formatted: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "timer")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Mono.healthy)
            Text("\(label) · \(formatted)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .contentTransition(.numericText(countsDown: true))
                .lineLimit(1)
        }
    }
}

// MARK: - Right ear: agent stack + morphing label

/// Soft status tints for the ear: readable on black without glowing.
enum EarTint {
    static let done = Color(red: 0.53, green: 0.94, blue: 0.67).opacity(0.85)
    static let ask = Color(red: 0.99, green: 0.83, blue: 0.30).opacity(0.85)
    static let working = Color(hex: 0x7FE7D8)
}

struct NotchAgentsEar: View {
    let stack: [AgentSession]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let size: CGFloat = 17
    private static let step: CGFloat = 12
    private static let maxVisible = 3

    private var visible: [AgentSession] { Array(stack.prefix(Self.maxVisible)) }
    private var extra: Int { stack.count - visible.count }
    private var lead: AgentSession? { stack.first }

    var body: some View {
        HStack(spacing: 6) {
            avatars
            label
        }
        .animation(reduceMotion ? .none : Mono.betweenSpring, value: visible.map(\.id))
        .animation(reduceMotion ? .none : Mono.betweenSpring, value: labelKey)
    }

    // Stack: front avatar sits nearest the camera, the rest tuck in behind it.
    private var avatars: some View {
        let width = visible.isEmpty ? 0 : CGFloat(visible.count - 1) * Self.step + Self.size + (extra > 0 ? 24 : 0)
        return ZStack(alignment: .leading) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, session in
                AgentStackAvatar(session: session, isFront: index == 0, size: Self.size)
                    .offset(x: CGFloat(index) * Self.step)
                    .zIndex(Double(10 - index))
                    .transition(.blurMorph(scale: 0.45, y: 0))
            }
            if extra > 0 {
                Text("+\(extra)")
                    .font(.system(size: 8.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.8))
                    .padding(.horizontal, 4)
                    .frame(minWidth: 18, minHeight: 14)
                    .background(Capsule().fill(Color(white: 0.14)))
                    .offset(x: CGFloat(visible.count) * Self.step + 6)
                    .transition(.opacity)
            }
        }
        .frame(width: width, height: Self.size, alignment: .leading)
    }

    private var labelKey: String {
        guard let lead else { return "none" }
        if lead.phase == .needsPermission { return "ask:\(lead.id)" }
        if lead.doneAt != nil { return "done:\(lead.id)" }
        return "w:\(lead.id):\(Self.liveActivity(lead))"
    }

    private var label: some View {
        ZStack(alignment: .leading) {
            if let lead {
                labelText(lead)
                    .id(labelKey)
                    .transition(.asymmetric(
                        insertion: .blurMorph(scale: 0.92, y: 7),
                        removal: .blurMorph(scale: 0.92, y: -7)
                    ))
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private func labelText(_ lead: AgentSession) -> Text {
        if lead.phase == .needsPermission {
            return Text("Permiso").foregroundStyle(EarTint.ask)
        }
        if lead.doneAt != nil {
            return Text("\(Image(systemName: "checkmark")) Listo").foregroundStyle(EarTint.done)
        }
        if lead.phase == .toolFailed {
            return Text("Error").foregroundStyle(Mono.danger.opacity(0.88))
        }
        return Text(Self.liveActivity(lead)).foregroundStyle(Color.white.opacity(0.88))
    }

    /// Clean, direct verb for the closed Notch ear ("Pensando…", "Editando…", "Ejecutando…", "Trabajando…")
    /// without cluttering the ear with raw shell commands or truncated file paths.
    static func liveActivity(_ session: AgentSession) -> String {
        switch session.phase {
        case .compacting:
            return "Compactando…"
        case .runningTool, .toolDone:
            switch AgentToolLabel.label(for: session.tool) {
            case "Terminal": return "Ejecutando…"
            case "Leer": return "Leyendo…"
            case "Editar": return "Editando…"
            case "Escribir": return "Escribiendo…"
            case "Buscar": return "Buscando…"
            case "Web": return "Navegando…"
            case "Plan": return "Planificando…"
            case "Subagente": return "Trabajando…"
            default: return "Trabajando…"
            }
        case .toolFailed:
            return "Error"
        default:
            return "Pensando…"
        }
    }
}

/// One logo in the stack, with a hairline halo when it finished or waits on you.
private struct AgentStackAvatar: View {
    let session: AgentSession
    let isFront: Bool
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var haloTint: Color? {
        if session.phase == .needsPermission { return EarTint.ask }
        if session.doneAt != nil { return EarTint.done }
        return nil
    }

    var body: some View {
        ProviderLogo(source: session.source, size: size)
            // Thin cut-out in the notch color so overlapping logos stay separate.
            .background(
                RoundedRectangle(cornerRadius: size * 0.27 + 1.5, style: .continuous)
                    .fill(Color(hex: 0x050505))
                    .padding(-1.5)
            )
            .overlay { if let haloTint { halo(haloTint) } }
            .overlay(alignment: .bottomTrailing) {
                if isFront && session.phase.isWorking {
                    WorkingDot()
                        .offset(x: 2, y: 2)
                }
            }
            .saturation(isFront || haloTint != nil ? 1 : 0.75)
            .opacity(isFront || haloTint != nil ? 1 : 0.82)
            .scaleEffect(haloTint != nil ? 1.06 : (isFront ? 1 : 0.92))
            .help("\(session.source.displayName) · \(session.project)")
    }

    @ViewBuilder
    private func halo(_ tint: Color) -> some View {
        let ring = RoundedRectangle(cornerRadius: size * 0.27 + 2.5, style: .continuous)
        if reduceMotion {
            ring.strokeBorder(tint.opacity(0.4), lineWidth: 1).padding(-2.5)
        } else {
            ring.strokeBorder(tint, lineWidth: 1)
                .padding(-2.5)
                .phaseAnimator([0.28, 0.5]) { content, alpha in
                    content
                        .opacity(alpha)
                        .shadow(color: tint.opacity(alpha * 0.35), radius: 3)
                } animation: { _ in .easeInOut(duration: 1.2) }
        }
    }
}

private struct WorkingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(EarTint.working)
            .frame(width: 5, height: 5)
            .background(Circle().fill(Color(hex: 0x050505)).padding(-1.2))
            .phaseAnimator(reduceMotion ? [1.0] : [0.45, 1.0]) { content, alpha in
                content.opacity(alpha).scaleEffect(0.8 + 0.2 * alpha)
            } animation: { _ in .easeInOut(duration: 0.6) }
    }
}

// MARK: - Blur morph transition

private struct BlurMorph: ViewModifier {
    let progress: Double // 0 = shown, 1 = gone
    let scale: CGFloat
    let y: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - (1 - scale) * progress)
            .offset(y: y * progress)
            .blur(radius: 4 * progress)
            .opacity(1 - progress)
    }
}

extension AnyTransition {
    /// Scale + blur + fade, the "morph" used for the ear avatars and label.
    static func blurMorph(scale: CGFloat, y: CGFloat) -> AnyTransition {
        .modifier(
            active: BlurMorph(progress: 1, scale: scale, y: y),
            identity: BlurMorph(progress: 0, scale: scale, y: y)
        )
    }
}
