import CleanTrashCore
import SwiftUI

extension AgentSource {
    /// Accent per agent (used sparingly: badge glyph + aurora).
    var tint: Color {
        switch self {
        case .claude: return Color(hex: 0xF0A27A)
        case .codex: return Color(hex: 0x7DD3FC)
        case .antigravity: return Color(hex: 0xA78BFA)
        }
    }

    var glyph: String {
        switch self {
        case .claude: return "asterisk"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .antigravity: return "paperplane.fill"
        }
    }
}

struct AgentSourceBadge: View {
    let source: AgentSource
    var size: CGFloat = 26
    var isWorking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ProviderLogo(source: source, size: size)
            .overlay(alignment: .bottomTrailing) {
                if isWorking {
                    Circle()
                        .fill(EarTint.working)
                        .frame(width: size * 0.26, height: size * 0.26)
                        .background(Circle().fill(Color(hex: 0x050505)).padding(-1.5))
                        .phaseAnimator(reduceMotion ? [1.0] : [0.45, 1.0]) { content, alpha in
                            content.opacity(alpha)
                        } animation: { _ in .easeInOut(duration: 0.7) }
                        .offset(x: 2, y: 2)
                }
            }
    }
}

/// Allow / Deny card for a tool call an agent is waiting on.
struct AgentPermissionCard: View {
    let request: AgentPermissionRequest
    let monitor: AgentMonitor
    /// Floating over the closed notch (bigger type) vs. inline in the Agentes tab.
    var isToast = false
    var queueCount = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                AgentSourceBadge(source: request.source, size: isToast ? 28 : 24)
                VStack(alignment: .leading, spacing: 1.5) {
                    (Text(request.project).foregroundStyle(.white)
                        + Text(" quiere usar ").foregroundStyle(Color.white.opacity(0.6))
                        + Text(AgentToolLabel.label(for: request.tool)).foregroundStyle(Mono.caution))
                        .font(.system(size: isToast ? 12.5 : 12, weight: .semibold))
                        .lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("\(request.origin) · \(Self.elapsed(since: request.receivedAt, now: context.date))")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if queueCount > 1 {
                    Text("+\(queueCount - 1)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Mono.caution))
                        .help("\(queueCount - 1) solicitudes más en cola")
                }
            }

            if let detail = request.detail {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.86))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .help(detail)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Button {
                    monitor.respond(request, decision: .ask)
                } label: {
                    Label("Responder allí", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .contentShape(Capsule())
                }
                .buttonStyle(NotchButtonStyle())
                .help("Abre la app del agente y responde en su propio diálogo")

                Spacer(minLength: 4)

                Button {
                    monitor.respond(request, decision: .deny)
                } label: {
                    Text("Denegar")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xFCA5A5))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Mono.danger.opacity(0.16)))
                        .overlay(Capsule().strokeBorder(Mono.danger.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(NotchButtonStyle())
                .keyboardShortcut(.cancelAction)

                Button {
                    monitor.respond(request, decision: .allow)
                } label: {
                    Text("Permitir")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.white))
                }
                .buttonStyle(NotchButtonStyle())
            }
        }
    }

    static func elapsed(since date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "hace \(seconds) s" }
        if seconds < 3600 { return "hace \(seconds / 60) min" }
        return "hace \(seconds / 3600) h"
    }
}

/// "Agentes" tab: pending permissions first, then every live session with what it's doing.
struct NotchAgentsTab: View {
    let monitor: AgentMonitor

    var body: some View {
        if !monitor.anyInstalled {
            emptyState(
                title: "Conecta tus agentes",
                subtitle: "Ve aquí lo que hacen Claude Code, Codex, Antigravity y T3 Code, y aprueba permisos sin cambiar de ventana.",
                action: ("Conectar", { monitor.installAllAvailable() })
            )
        } else if monitor.sessions.isEmpty && monitor.pending.isEmpty {
            emptyState(
                title: "Sin agentes trabajando",
                subtitle: "Cuando Claude Code, Codex o Antigravity trabajen, verás aquí su actividad y sus pedidos de permiso.",
                action: nil
            )
        } else {
            // Fixed rows (like Dev): the shelf is 218 pt tall — one permission card + 1 row, or 4 rows.
            let request = monitor.pending.first
            let all = monitor.visibleSessions
            let capacity = request == nil ? 4 : 1
            let shown = all.count > capacity ? Array(all.prefix(capacity - (request == nil ? 1 : 0))) : all
            VStack(spacing: 6) {
                if let request {
                    AgentPermissionCard(request: request, monitor: monitor, queueCount: monitor.pending.count)
                        .padding(11)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Mono.caution.opacity(0.07))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Mono.caution.opacity(0.35), lineWidth: 1)
                        )
                }
                ForEach(shown) { session in
                    sessionRow(session)
                }
                if all.count > shown.count {
                    Text("+\(all.count - shown.count) \(all.count - shown.count == 1 ? "sesión" : "sesiones") más")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.top, 2)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        Button {
            monitor.focus(session)
        } label: {
            HStack(spacing: 10) {
                AgentSourceBadge(source: session.source, size: 26, isWorking: session.phase.isWorking)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(session.project)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(session.originLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    Text(session.statusLine)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(statusColor(session))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(session.statusLine)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 3) {
                    phaseIndicator(session)
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        Text(AgentPermissionCard.elapsed(since: session.updatedAt, now: context.date))
                            .font(.system(size: 9.5).monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.35))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .notchHoverRow(cornerRadius: 11)
        .pointingHandCursor()
        .help("Abrir \(session.originLabel)")
    }

    @ViewBuilder
    private func phaseIndicator(_ session: AgentSession) -> some View {
        switch session.phase {
        case .needsPermission:
            pill("Permiso", color: Mono.caution)
        case .toolFailed:
            pill("Error", color: Mono.danger)
        case .waitingInput, .started:
            pill("Listo", color: Mono.healthy)
        case .ended:
            pill("Cerrada", color: .white.opacity(0.5))
        default:
            AgentSpinner(tint: session.source.tint)
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private func statusColor(_ session: AgentSession) -> Color {
        switch session.phase {
        case .needsPermission: return Mono.caution
        case .toolFailed: return Color(hex: 0xFCA5A5)
        default: return Color.white.opacity(0.6)
        }
    }

    private func emptyState(title: String, subtitle: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            HStack(spacing: -6) {
                ForEach(AgentSource.allCases) { source in
                    AgentSourceBadge(source: source, size: 30)
                        .background(Circle().fill(Color(hex: 0x050505)))
                }
            }
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)
            }
            if let action {
                Button(action: action.1) {
                    Text(action.0)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.white))
                }
                .buttonStyle(NotchButtonStyle())
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Thin rotating arc in the agent's tint (lighter than a system spinner on the black shelf).
struct AgentSpinner: View {
    var tint: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.8)
            .stroke(tint, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .frame(width: 14, height: 14)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spinning = true }
            }
    }
}
