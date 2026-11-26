import CleanTrashCore
import SwiftUI

/// Live view of every coding-agent session the hooks report (Claude Code, Codex, Antigravity, T3 Code).
struct AgentsView: View {
    @Bindable var appState: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var monitor: AgentMonitor { appState.agents }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if !monitor.pending.isEmpty {
                    section("Esperando tu respuesta") {
                        VStack(spacing: 10) {
                            ForEach(monitor.pending) { request in
                                AgentPermissionCard(request: request, monitor: monitor, queueCount: 1)
                                    .padding(14)
                                    .monoCard(radius: 14)
                            }
                        }
                    }
                }

                if monitor.visibleSessions.isEmpty {
                    emptyState
                } else {
                    section("Sesiones") {
                        VStack(spacing: 0) {
                            ForEach(Array(monitor.visibleSessions.enumerated()), id: \.element.id) { index, session in
                                if index > 0 { Divider().overlay(Mono.hairline(scheme)) }
                                sessionRow(session)
                            }
                        }
                        .padding(.horizontal, 14)
                        .monoCard(radius: 14)
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(20)
            .animation(reduceMotion ? .none : Mono.betweenSpring, value: monitor.visibleSessions.map(\.id))
            .animation(reduceMotion ? .none : Mono.betweenSpring, value: monitor.pending.map(\.id))
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Icon3D(name: .dev, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("Agentes")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Mono.ink(scheme))
                Text(summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Mono.muted(scheme))
            }
            Spacer()
            HStack(spacing: -5) {
                ForEach(AgentSource.allCases, id: \.self) { source in
                    if monitor.installed[source] == true {
                        ProviderLogo(source: source, size: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Mono.canvas(scheme))
                                    .padding(-1.5)
                            )
                    }
                }
            }
            Button("Configurar") {
                appState.settingsPane = .agents
                appState.selectedSection = .settings
            }
            .buttonStyle(MonoGhostButtonStyle())
        }
    }

    private var summary: String {
        let working = monitor.sessions.filter { $0.phase.isWorking }.count
        let waiting = monitor.pending.count
        switch (working, waiting) {
        case (0, 0): return monitor.sessions.isEmpty ? "Sin actividad" : "Todo en pausa"
        case (_, 0): return working == 1 ? "1 trabajando" : "\(working) trabajando"
        case (0, _): return waiting == 1 ? "1 espera tu respuesta" : "\(waiting) esperan tu respuesta"
        default: return "\(working) trabajando · \(waiting) esperando"
        }
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        HStack(spacing: 12) {
            AgentSourceBadge(source: session.source, size: 28, isWorking: session.phase.isWorking)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.project)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Mono.ink(scheme))
                        .lineLimit(1)
                    Text(session.originLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Mono.muted(scheme))
                        .lineLimit(1)
                }
                Text(session.statusLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(statusColor(session))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.interpolate)
            }
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 5)) { context in
                Text(Self.ago(session.updatedAt, now: context.date))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Mono.muted(scheme))
            }
            Button {
                monitor.focus(session)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Mono.muted(scheme))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Ir a la sesión")
        }
        .padding(.vertical, 10)
    }

    private func statusColor(_ session: AgentSession) -> Color {
        switch session.phase {
        case .needsPermission: return Mono.caution
        case .toolFailed: return Mono.danger
        default: return session.phase.isWorking ? Mono.ink(scheme).opacity(0.85) : Mono.muted(scheme)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Mono.muted(scheme))
            Text(monitor.installed.values.contains(true) ? "Sin agentes trabajando" : "Conecta tus agentes")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Mono.ink(scheme))
            Text("Claude Code, Codex y Antigravity aparecen aquí y en el Notch.")
                .font(.system(size: 12))
                .foregroundStyle(Mono.muted(scheme))
            if !monitor.installed.values.contains(true) {
                Button("Conectar") { monitor.installAllAvailable() }
                    .buttonStyle(MonoPrimaryButtonStyle())
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .monoCard(radius: 14)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Mono.muted(scheme))
                .padding(.horizontal, 4)
            content()
        }
    }

    private static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 10 { return "ahora" }
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h"
    }
}
