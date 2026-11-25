import AppKit
import CleanTrashCore
import SwiftUI

/// Floating Animated Desktop Companion (`CleanBot`) for AI Coding Agents (Claude Code, Codex, Antigravity, T3 Code).
/// Floats unobtrusively on screen (draggable anywhere), reacts in real time to agent hooks:
/// - **Idle**: gentle breathing bob + occasional blink
/// - **Working**: glowing eyes in provider tint + orbiting spark + live tool pill
/// - **Ask (Permission needed)**: hops with coral/amber aura + interactive Permitir / Denegar bubble right beside the mascot!
/// - **Done**: celebratory bounce + happy `^ ^` eyes + "¡Listo!" bubble
@MainActor
final class AgentMascotWindowController {
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func setVisible(_ visible: Bool, appState: AppState) {
        if visible {
            show(appState: appState)
        } else {
            hide()
        }
    }

    func show(appState: AppState) {
        if let existing = panel {
            existing.orderFrontRegardless()
            return
        }

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 148),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: vf.maxX - 336, y: vf.minY + 36))
        }

        let hosting = NSHostingView(rootView: AgentMascotRootView(appState: appState) { [weak self, weak appState] in
            appState?.settings.agentMascotEnabled = false
            self?.hide()
        })
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = hosting
        p.orderFrontRegardless()
        self.panel = p
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

private enum MascotMood: Equatable {
    case idle
    case working(Color, String)
    case asking(AgentPermissionRequest)
    case done(Color, String)

    var auraColor: Color {
        switch self {
        case .idle: return Mono.gpuAccent
        case .working(let c, _): return c
        case .asking: return Mono.caution
        case .done(let c, _): return c
        }
    }
}

private struct AgentMascotRootView: View {
    @Bindable var appState: AppState
    let onHide: () -> Void

    @State private var isHovering = false
    @State private var blink = false

    private var monitor: AgentMonitor { appState.agents }
    private var surface: NotchSurfaceMode { appState.settings.notchSurface }

    private var mood: MascotMood {
        if let pending = monitor.pending.first {
            return .asking(pending)
        }
        if let working = monitor.sessions.first(where: { $0.phase.isWorking }) {
            let activity = NotchAgentsEar.liveActivity(working)
            return .working(working.source.tint, "\(working.source.displayName): \(activity)")
        }
        if let recentDone = monitor.sessions.first(where: { Date.now.timeIntervalSince($0.updatedAt) < 25 }) {
            return .done(Mono.healthy, "\(recentDone.source.displayName) terminó ✓")
        }
        return .idle
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Spacer(minLength: 0)

            // Speech bubble (shows automatically on Ask / Working / Done, or on hover when Idle)
            speechBubble
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.88, anchor: .trailing)),
                    removal: .opacity
                ))

            // Animated CleanBot Character
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                botCharacter(time: t)
            }
            .onTapGesture {
                if let lead = monitor.sessions.first {
                    monitor.focus(lead)
                } else {
                    appState.selectedSection = .notchHub
                    appState.onOpenMainWindow?()
                }
                AppKitHaptics.tap()
            }
            .contextMenu {
                Button("Abrir Centro Notch") {
                    appState.selectedSection = .notchHub
                    appState.onOpenMainWindow?()
                }
                Button("Ocultar mascota", action: onHide)
            }
            .pointingHandCursor()
        }
        .padding(14)
        .frame(width: 320, height: 148, alignment: .bottomTrailing)
        .onHover { hovering in
            withAnimation(Mono.fast) { isHovering = hovering }
        }
        .animation(Mono.openingSpring, value: mood)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 2.8...5.2)))
                blink = true
                try? await Task.sleep(for: .milliseconds(130))
                blink = false
            }
        }
        .environment(\.colorScheme, .dark)
        .environment(\.notchSurface, surface)
    }

    @ViewBuilder
    private var speechBubble: some View {
        switch mood {
        case .asking(let req):
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    ProviderLogo(source: req.source, size: 15)
                    Text("\(req.source.displayName) pide permiso")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Text(req.detail ?? AgentToolLabel.label(for: req.tool))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(2)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))

                HStack(spacing: 6) {
                    Button("Denegar") {
                        monitor.respond(req, decision: .deny)
                        AppKitHaptics.tap()
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xFCA5A5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Mono.danger.opacity(0.22)))
                    .buttonStyle(.plain)
                    .pointingHandCursor()

                    Button("Permitir") {
                        monitor.respond(req, decision: .allow)
                        AppKitHaptics.confirm()
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.white))
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
            .padding(11)
            .frame(width: 210)
            .floatingDockGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), surface: surface)

        case .working(let tint, let text):
            HStack(spacing: 7) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: 205, alignment: .leading)
            .floatingDockGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous), surface: surface)

        case .done(_, let text):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Mono.healthy)
                Text(text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .floatingDockGlass(in: Capsule(), surface: surface)

        case .idle:
            if isHovering {
                HStack(spacing: 6) {
                    Text("Agentes en espera")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Button(action: onHide) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .floatingDockGlass(in: Capsule(), surface: surface)
            }
        }
    }

    private func botCharacter(time: TimeInterval) -> some View {
        let bob: CGFloat = {
            switch mood {
            case .asking: return CGFloat(abs(sin(time * 5.2))) * -7.0
            case .working: return CGFloat(sin(time * 3.4)) * 3.5
            case .done: return CGFloat(abs(sin(time * 4.5))) * -5.0
            case .idle: return CGFloat(sin(time * 1.8)) * 2.5
            }
        }()
        let aura = mood.auraColor

        return ZStack {
            // Soft ambient aura glow behind CleanBot
            Circle()
                .fill(aura.opacity(0.28))
                .frame(width: 58, height: 58)
                .blur(radius: 12)

            // Orbiting energy ring when working or asking
            if case .working = mood {
                Circle()
                    .trim(from: 0, to: 0.35)
                    .stroke(aura, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 60, height: 60)
                    .rotationEffect(.radians(time * 2.8))
            } else if case .asking = mood {
                Circle()
                    .stroke(Mono.caution.opacity(0.65), lineWidth: 2)
                    .frame(width: 60 + CGFloat(sin(time * 6) * 3), height: 60 + CGFloat(sin(time * 6) * 3))
            }

            // Frosted Obsidian Glass Bot Body
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x1A1C24), Color(hex: 0x090A0F)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 52, height: 50)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.32), aura.opacity(0.45)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1.2
                        )
                )
                .shadow(color: .black.opacity(0.55), radius: 12, y: 6)

            // Antenna sparkle on top
            Circle()
                .fill(aura)
                .frame(width: 6, height: 6)
                .shadow(color: aura, radius: 5)
                .offset(y: -29)

            // Expressive Face Visor
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.75))
                .frame(width: 38, height: 22)
                .overlay {
                    botEyes(aura: aura)
                }
                .offset(y: 1)
        }
        .frame(width: 64, height: 64)
        .offset(y: bob)
    }

    @ViewBuilder
    private func botEyes(aura: Color) -> some View {
        switch mood {
        case .done:
            // Happy ^ ^ eyes
            HStack(spacing: 10) {
                Text("^")
                Text("^")
            }
            .font(.system(size: 14, weight: .black))
            .foregroundStyle(Mono.healthy)
            .offset(y: 2)

        case .asking:
            // Alert ! eyes
            HStack(spacing: 9) {
                Capsule().fill(Mono.caution).frame(width: 5, height: 10)
                Capsule().fill(Mono.caution).frame(width: 5, height: 10)
            }
            .shadow(color: Mono.caution, radius: 4)

        case .working(let tint, _):
            HStack(spacing: 9) {
                Capsule().fill(tint).frame(width: 6, height: blink ? 2 : 9)
                Capsule().fill(tint).frame(width: 6, height: blink ? 2 : 9)
            }
            .shadow(color: tint, radius: 4)

        case .idle:
            HStack(spacing: 9) {
                Capsule().fill(Mono.gpuAccent).frame(width: 5.5, height: blink ? 1.8 : 7.5)
                Capsule().fill(Mono.gpuAccent).frame(width: 5.5, height: blink ? 1.8 : 7.5)
            }
            .shadow(color: Mono.gpuAccent.opacity(0.6), radius: 3)
        }
    }
}
