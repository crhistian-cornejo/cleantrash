import CleanTrashCore
import SwiftUI

extension AgentSource {
    /// Accent per agent (used sparingly: badge glyph + aurora).
    var tint: Color {
        switch self {
        case .claude: return Color(hex: 0xF0A27A)
        case .codex: return Color(hex: 0x7DD3FC)
        case .antigravity: return Mono.networkAccent
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
