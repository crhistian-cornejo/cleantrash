import AppKit
import CleanTrashCore
import Foundation
import Observation
import SwiftUI

/// One agent conversation as seen from its hooks.
struct AgentSession: Identifiable, Equatable {
    let id: String
    let source: AgentSource
    let sessionID: String
    var cwd: String?
    var phase: AgentPhase
    var tool: String?
    var detail: String?
    var message: String?
    var prompt: String?
    var hostBundleID: String?
    /// Display name of `hostBundleID` (Terminal, Ghostty, Zed…), resolved once.
    var hostName: String?
    var t3ThreadID: String?
    var startedAt: Date
    var updatedAt: Date
    var toolCount = 0
    /// Set when a working turn just finished: the ear shows "✓ Done" for a moment, then lets it go.
    var doneAt: Date?

    var project: String {
        guard let cwd, !cwd.isEmpty else { return source.shortName }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    var isT3Code: Bool { t3ThreadID != nil || hostBundleID == "com.t3tools.t3code" }

    /// "Claude · T3 Code", "Codex · Terminal", "Antigravity".
    var originLabel: String {
        if isT3Code { return "\(source.shortName) · T3 Code" }
        if let host = hostName, host != source.displayName, host != source.shortName {
            return "\(source.shortName) · \(host)"
        }
        return source.displayName
    }

    /// Line shown under the project name.
    var statusLine: String {
        switch phase {
        case .started: return "Sesión iniciada"
        case .thinking: return prompt.map { "Pensando · \($0)" } ?? "Pensando…"
        case .runningTool:
            let label = AgentToolLabel.label(for: tool)
            return detail.map { "\(label) · \($0)" } ?? label
        case .toolDone:
            let label = AgentToolLabel.label(for: tool)
            return detail.map { "\(label) ✓ · \($0)" } ?? "\(label) ✓"
        case .toolFailed: return "\(AgentToolLabel.label(for: tool)) falló" + (message.map { " · \($0)" } ?? "")
        case .needsPermission: return "Pide permiso para \(AgentToolLabel.label(for: tool))"
        case .notification: return message ?? "Aviso"
        case .waitingInput: return message ?? "Listo · esperando tu mensaje"
        case .compacting: return "Compactando contexto…"
        case .ended: return "Sesión cerrada"
        }
    }
}

/// A tool call waiting for Allow / Deny from the notch.
struct AgentPermissionRequest: Identifiable, Equatable {
    let id: String
    let sessionKey: String
    let source: AgentSource
    let project: String
    let origin: String
    let tool: String?
    let detail: String?
    let toolUseID: String?
    let receivedAt: Date

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

@MainActor
@Observable
final class AgentMonitor {
    private(set) var sessions: [AgentSession] = []
    private(set) var pending: [AgentPermissionRequest] = []
    private(set) var installed: [AgentSource: Bool] = [:]
    private(set) var present: [AgentSource: Bool] = [:]
    var lastError: String?

    /// Asked whether permission cards may appear (notch enabled); otherwise the agent prompts as usual.
    var canPrompt: () -> Bool = { true }

    @ObservationIgnored private var responders: [String: AgentResponder] = [:]
    @ObservationIgnored private var server: AgentSocketServer?
    @ObservationIgnored private var sweepTask: Task<Void, Never>?
    @ObservationIgnored private let installer = AgentHookInstaller()

    private static let autoInstallKey = "agentHooksAutoInstalled.v1"

    // MARK: Derived

    var visibleSessions: [AgentSession] {
        sessions.sorted { lhs, rhs in
            if lhs.phase.isWorking != rhs.phase.isWorking { return lhs.phase.isWorking }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    var workingCount: Int { sessions.filter { $0.phase.isWorking || $0.phase == .needsPermission }.count }

    var anyInstalled: Bool { installed.values.contains(true) }

    /// Avatars for the closed notch's right ear, front first: waiting on you → just finished → busiest.
    var earStack: [AgentSession] {
        sessions
            .filter { $0.phase.isWorking || $0.phase == .needsPermission || $0.doneAt != nil }
            .sorted { lhs, rhs in
                let l = Self.earRank(lhs), r = Self.earRank(rhs)
                if l != r { return l < r }
                return (lhs.doneAt ?? lhs.updatedAt) > (rhs.doneAt ?? rhs.updatedAt)
            }
    }

    private static func earRank(_ session: AgentSession) -> Int {
        if session.phase == .needsPermission { return 0 }
        if session.doneAt != nil { return 1 }
        return 2
    }

    /// How long a finished agent stays at the front saying "Done" before leaving the stack.
    static let doneLinger: Duration = .milliseconds(2800)

    /// Short label for the closed notch ear while agents work.
    var earLabel: String? {
        let working = sessions.filter { $0.phase.isWorking }
        guard !working.isEmpty else { return nil }
        if working.count == 1, let only = working.first { return only.source.shortName }
        return "\(working.count) agentes"
    }

    // MARK: Lifecycle

    func start() {
        refreshInstallState()
        installHookBinary()
        autoInstallOnce()

        let server = AgentSocketServer(
            path: AgentBridgePaths.socketPath,
            onEvent: { [weak self] event, responder in
                Task { @MainActor [weak self] in self?.handle(event, responder: responder) }
            },
            onHangup: { [weak self] requestID in
                Task { @MainActor [weak self] in self?.dropPending(requestID) }
            }
        )
        do {
            try server.start()
            self.server = server
        } catch {
            lastError = "No se pudo abrir el canal de agentes: \(error.localizedDescription)"
        }

        sweepTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.sweep()
            }
        }
    }

    func stop() {
        sweepTask?.cancel()
        for responder in responders.values { responder.reply(nil) }
        responders.removeAll()
        server?.stop()
        server = nil
    }

    // MARK: Events

    private func handle(_ event: AgentEvent, responder: AgentResponder?) {
        let key = "\(event.source.rawValue):\(event.sessionID)"
        let wasWorking = sessions.first(where: { $0.id == key })?.phase.isWorking ?? false
        var session = sessions.first(where: { $0.id == key }) ?? AgentSession(
            id: key, source: event.source, sessionID: event.sessionID, cwd: event.cwd, phase: event.phase,
            hostBundleID: event.hostBundleID, t3ThreadID: event.t3ThreadID,
            startedAt: event.date, updatedAt: event.date
        )
        session.phase = event.phase
        session.updatedAt = .now
        if let cwd = event.cwd { session.cwd = cwd }
        if let host = event.hostBundleID, host != session.hostBundleID || session.hostName == nil {
            session.hostBundleID = host
            session.hostName = Self.appName(for: host)
        }
        if let thread = event.t3ThreadID { session.t3ThreadID = thread }
        if let prompt = event.prompt, event.phase == .thinking { session.prompt = prompt }
        switch event.phase {
        case .runningTool, .toolDone, .toolFailed, .needsPermission:
            session.tool = event.tool
            session.detail = event.detail
            if event.phase == .runningTool || (event.source == .antigravity && event.phase != .needsPermission) {
                session.toolCount += 1
            }
        default:
            break
        }
        session.message = event.message
        if event.phase.isWorking || event.phase == .needsPermission {
            session.doneAt = nil
        } else if wasWorking, event.phase == .waitingInput || event.phase == .ended {
            let doneAt = Date.now
            session.doneAt = doneAt
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.doneLinger)
                guard let self, let index = self.sessions.firstIndex(where: { $0.id == key }),
                      self.sessions[index].doneAt == doneAt else { return }
                withAnimation(Mono.betweenSpring) { self.sessions[index].doneAt = nil }
            }
        }

        withAnimation(Mono.betweenSpring) {
            if let index = sessions.firstIndex(where: { $0.id == key }) {
                sessions[index] = session
            } else {
                sessions.append(session)
            }
        }

        // Anything after a permission request means it was answered elsewhere (terminal / T3 Code).
        if event.phase != .needsPermission {
            for request in pending where request.sessionKey == key {
                if event.phase == .runningTool, let id = request.toolUseID, id != event.toolUseID { continue }
                dropPending(request.id)
            }
        }

        if event.phase == .needsPermission, let responder {
            guard canPrompt() else {
                responder.reply(nil)
                return
            }
            responders[event.requestID] = responder
            let request = AgentPermissionRequest(
                id: event.requestID, sessionKey: key, source: event.source, project: session.project,
                origin: session.originLabel, tool: event.tool, detail: event.detail, toolUseID: event.toolUseID,
                receivedAt: .now
            )
            withAnimation(Mono.betweenSpring) { pending.append(request) }
            NSSound(named: "Tink")?.play()
        }

        if event.phase == .ended {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.sessions.removeAll { $0.id == key && $0.phase == .ended }
            }
        }
    }

    func respond(_ request: AgentPermissionRequest, decision: AgentDecision) {
        responders.removeValue(forKey: request.id)?.reply(AgentReply(decision: decision))
        withAnimation(Mono.betweenSpring) { pending.removeAll { $0.id == request.id } }
        if decision != .ask, let index = sessions.firstIndex(where: { $0.id == request.sessionKey }) {
            sessions[index].phase = decision == .allow ? .runningTool : .thinking
            sessions[index].updatedAt = .now
        }
        if decision == .ask { focus(sessionKey: request.sessionKey) }
    }

    private func dropPending(_ requestID: String) {
        responders.removeValue(forKey: requestID)?.reply(nil)
        guard let request = pending.first(where: { $0.id == requestID }) else { return }
        // Answered elsewhere: the agent carries on, so the row stops saying "pide permiso".
        if let index = sessions.firstIndex(where: { $0.id == request.sessionKey }), sessions[index].phase == .needsPermission {
            sessions[index].phase = .thinking
            sessions[index].updatedAt = .now
        }
        withAnimation(Mono.betweenSpring) { pending.removeAll { $0.id == requestID } }
    }

    /// Forget quiet sessions; give up on unanswered permission cards before the hook times out.
    private func sweep() {
        let now = Date.now
        for request in pending where now.timeIntervalSince(request.receivedAt) > 112 {
            dropPending(request.id)
        }
        sessions.removeAll { session in
            let idle = now.timeIntervalSince(session.updatedAt)
            if session.phase.isWorking { return idle > 15 * 60 }
            return idle > 45 * 60
        }
        for index in sessions.indices where sessions[index].phase.isWorking
            && now.timeIntervalSince(sessions[index].updatedAt) > 5 * 60 {
            sessions[index].phase = .waitingInput
            sessions[index].message = "Sin actividad reciente"
        }
    }

    // MARK: Focus host app

    func focus(sessionKey: String) {
        guard let session = sessions.first(where: { $0.id == sessionKey }) else { return }
        focus(session)
    }

    func focus(_ session: AgentSession) {
        let bundleID: String? = session.isT3Code ? "com.t3tools.t3code"
            : session.hostBundleID ?? (session.source == .antigravity ? "com.google.antigravity" : nil)
        guard let bundleID else { return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static var appNames: [String: String] = [:]

    static func appName(for bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let cached = appNames[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        appNames[bundleID] = name
        return name
    }

    // MARK: Hook installation

    func refreshInstallState() {
        for source in AgentSource.allCases {
            present[source] = installer.isAgentPresent(source)
            installed[source] = installer.isInstalled(source)
        }
    }

    func setIntegration(_ source: AgentSource, enabled: Bool) {
        do {
            if enabled {
                installHookBinary()
                try installer.install(source)
            } else {
                try installer.uninstall(source)
            }
            lastError = nil
        } catch {
            lastError = "\(source.displayName): \(error.localizedDescription)"
        }
        refreshInstallState()
    }

    func installAllAvailable() {
        for source in AgentSource.allCases where present[source] == true && installed[source] != true {
            setIntegration(source, enabled: true)
        }
    }

    /// First launch with this feature: hook into every agent found on the Mac.
    private func autoInstallOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.autoInstallKey) else { return }
        defaults.set(true, forKey: Self.autoInstallKey)
        installAllAvailable()
    }

    /// Copies the bundled `cleantrash-hook` to a stable path the agent configs point to.
    private func installHookBinary() {
        let fm = FileManager.default
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cleantrash-hook"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("cleantrash-hook")
        ].compactMap { $0 }
        guard let bundled = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else { return }
        let target = AgentBridgePaths.hookBinary
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let same = (try? Data(contentsOf: bundled)) == (try? Data(contentsOf: target))
            guard !same else { return }
            let staging = target.appendingPathExtension("new")
            try? fm.removeItem(at: staging)
            try fm.copyItem(at: bundled, to: staging)
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: target)
            }
        } catch {
            if !fm.fileExists(atPath: target.path) {
                try? fm.copyItem(at: bundled, to: target)
            }
        }
    }

    #if DEBUG
    /// Fake sessions + one pending request for `NotchSnapshotRenderer`.
    func injectPreview() {
        installed = [.claude: true, .codex: true, .antigravity: true]
        let now = Date.now
        sessions = [
            AgentSession(id: "claude:1", source: .claude, sessionID: "1", cwd: "/Users/me/cleantrash", phase: .runningTool,
                         tool: "Bash", detail: "swift build -c release", hostBundleID: "com.t3tools.t3code", t3ThreadID: "t",
                         startedAt: now, updatedAt: now.addingTimeInterval(-4), toolCount: 12),
            AgentSession(id: "codex:2", source: .codex, sessionID: "2", cwd: "/Users/me/web-app", phase: .waitingInput,
                         hostBundleID: "com.mitchellh.ghostty", hostName: "Ghostty", startedAt: now, updatedAt: now.addingTimeInterval(-180)),
            AgentSession(id: "antigravity:3", source: .antigravity, sessionID: "3", cwd: "/Users/me/api", phase: .toolDone,
                         tool: "view_file", detail: "~/api/src/server.ts", startedAt: now, updatedAt: now.addingTimeInterval(-20))
        ]
        pending = [
            AgentPermissionRequest(id: "p1", sessionKey: "claude:1", source: .claude, project: "cleantrash", origin: "Claude · T3 Code",
                                   tool: "Bash", detail: "rm -rf .build && swift build -c release --product CleanTrash",
                                   toolUseID: nil, receivedAt: now.addingTimeInterval(-6))
        ]
    }

    func clearPreviewPending() { pending = [] }

    /// Marks the Codex preview session as just finished ("✓ Done" at the front of the ear stack).
    func previewDone() {
        guard let index = sessions.firstIndex(where: { $0.id == "codex:2" }) else { return }
        sessions[index].doneAt = .now
    }
    #endif
}
