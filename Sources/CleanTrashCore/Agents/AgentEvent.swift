import Foundation

/// Coding agents CleanTrash listens to through lifecycle hooks.
/// T3 Code drives Claude and Codex, so its threads arrive through those two (tagged by host).
public enum AgentSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude, codex, antigravity

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    public var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }
}

/// What an agent session is doing right now, reduced from each tool's event vocabulary.
public enum AgentPhase: String, Codable, Sendable {
    case started
    case thinking
    case runningTool
    case toolDone
    case toolFailed
    case needsPermission
    case notification
    case waitingInput
    case compacting
    case ended

    /// The agent is mid-turn (spinner in the notch).
    public var isWorking: Bool {
        switch self {
        case .thinking, .runningTool, .toolDone, .toolFailed, .compacting: return true
        default: return false
        }
    }
}

/// One normalized hook invocation sent from `cleantrash-hook` to the app over the agent socket.
public struct AgentEvent: Codable, Sendable, Equatable {
    public var source: AgentSource
    public var phase: AgentPhase
    /// Original hook name (`PreToolUse`, `PreInvocation`…), kept for debugging.
    public var hookEvent: String
    public var sessionID: String
    public var cwd: String?
    public var tool: String?
    /// One-line summary of the tool input (command, file, pattern…).
    public var detail: String?
    public var toolUseID: String?
    public var message: String?
    public var prompt: String?
    /// `__CFBundleIdentifier` of the app that launched the agent (terminal, T3 Code, IDE).
    public var hostBundleID: String?
    public var t3ThreadID: String?
    public var pid: Int32?
    /// Correlates a permission request with the reply sent back on the same connection.
    public var requestID: String
    public var date: Date

    public init(
        source: AgentSource,
        phase: AgentPhase,
        hookEvent: String,
        sessionID: String,
        cwd: String? = nil,
        tool: String? = nil,
        detail: String? = nil,
        toolUseID: String? = nil,
        message: String? = nil,
        prompt: String? = nil,
        hostBundleID: String? = nil,
        t3ThreadID: String? = nil,
        pid: Int32? = nil,
        requestID: String = UUID().uuidString,
        date: Date = .now
    ) {
        self.source = source
        self.phase = phase
        self.hookEvent = hookEvent
        self.sessionID = sessionID
        self.cwd = cwd
        self.tool = tool
        self.detail = detail
        self.toolUseID = toolUseID
        self.message = message
        self.prompt = prompt
        self.hostBundleID = hostBundleID
        self.t3ThreadID = t3ThreadID
        self.pid = pid
        self.requestID = requestID
        self.date = date
    }

    /// The hook blocks until the app answers (or gives up).
    public var awaitsDecision: Bool { phase == .needsPermission }

    /// Launched from T3 Code (its Claude / Codex threads).
    public var isT3Code: Bool {
        t3ThreadID != nil || hostBundleID == "com.t3tools.t3code"
    }

    public var projectName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}

public enum AgentDecision: String, Codable, Sendable {
    case allow, deny
    /// Let the agent show its own prompt (terminal / T3 Code UI).
    case ask
}

public struct AgentReply: Codable, Sendable, Equatable {
    public var decision: AgentDecision
    public var reason: String?

    public init(decision: AgentDecision, reason: String? = nil) {
        self.decision = decision
        self.reason = reason
    }
}

// MARK: - Normalization

public enum AgentEventNormalizer {
    /// Turns a raw hook payload (Claude/Codex snake_case or Antigravity camelCase) into an `AgentEvent`.
    /// Returns nil for events the notch has nothing to show for.
    public static func normalize(
        _ json: [String: Any],
        source: AgentSource,
        environment: [String: String] = [:],
        parentPID: Int32? = nil
    ) -> AgentEvent? {
        let hookEvent = (json["hook_event_name"] as? String) ?? (json["hookEventName"] as? String) ?? ""
        guard let phase = phase(for: hookEvent, json: json) else { return nil }

        let toolCall = json["toolCall"] as? [String: Any]
        let tool = (json["tool_name"] as? String) ?? (toolCall?["name"] as? String)
        let input = (json["tool_input"] as? [String: Any]) ?? (toolCall?["args"] as? [String: Any])
        let workspace = (json["workspacePaths"] as? [String])?.first
        let sessionID = (json["session_id"] as? String)
            ?? (json["conversationId"] as? String)
            ?? (json["sessionId"] as? String)
            ?? "unknown"

        var message = (json["message"] as? String) ?? (json["error"] as? String)
        if message == nil, phase == .toolFailed { message = "La herramienta falló" }

        let thread = environment["T3CODE_THREAD_ID"].flatMap { $0.isEmpty ? nil : $0 }

        return AgentEvent(
            source: source,
            phase: phase,
            hookEvent: hookEvent,
            sessionID: sessionID,
            cwd: (json["cwd"] as? String) ?? workspace,
            tool: tool,
            detail: input.flatMap(summarize),
            toolUseID: (json["tool_use_id"] as? String) ?? (toolCall?["id"] as? String),
            message: message.map { clip($0, 220) },
            prompt: ((json["prompt"] as? String) ?? (json["lastUserInput"] as? String)).map { clip($0, 160) },
            hostBundleID: environment["__CFBundleIdentifier"],
            t3ThreadID: thread,
            pid: parentPID
        )
    }

    static func phase(for hookEvent: String, json: [String: Any]) -> AgentPhase? {
        switch hookEvent {
        case "SessionStart": return .started
        case "UserPromptSubmit", "PreInvocation", "SubagentStart", "SubagentStop", "PostCompact": return .thinking
        case "PreToolUse": return .runningTool
        case "PostToolUse":
            return json["error"] != nil ? .toolFailed : .toolDone
        case "PostToolUseFailure": return .toolFailed
        case "PermissionRequest": return .needsPermission
        case "Notification":
            switch json["notification_type"] as? String {
            // PermissionRequest already carries the tool and input for this one.
            case "permission_prompt": return nil
            case "idle_prompt": return .waitingInput
            default: return .notification
            }
        case "Stop", "StopFailure", "Interrupt": return .waitingInput
        case "PreCompact": return .compacting
        case "SessionEnd": return .ended
        default: return nil
        }
    }

    /// Picks the most telling field of a tool input: the command, the file, the pattern, the URL…
    static func summarize(_ input: [String: Any]) -> String? {
        let keys = [
            "command", "CommandLine", "cmd",
            "file_path", "notebook_path", "AbsolutePath", "TargetFile", "path", "Path", "DirectoryPath",
            "pattern", "Query", "query", "url", "Url",
            "description", "prompt", "Prompt"
        ]
        for key in keys {
            guard let value = input[key] else { continue }
            var text: String?
            if let string = value as? String {
                text = string
            } else if let parts = value as? [String] {
                // Codex shell calls arrive as ["bash", "-lc", "<script>"].
                text = parts.count >= 3 && parts[1] == "-lc" ? parts[2] : parts.joined(separator: " ")
            }
            guard var text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if key.lowercased().contains("path") || key == "TargetFile" {
                text = abbreviateHome(text)
            }
            return clip(text.replacingOccurrences(of: "\n", with: " ⏎ "), 240)
        }
        return nil
    }

    static func abbreviateHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }
}

// MARK: - Tool labels

public enum AgentToolLabel {
    /// Human, Spanish name for a tool across Claude, Codex and Antigravity vocabularies.
    public static func label(for tool: String?) -> String {
        guard let tool, !tool.isEmpty else { return "Herramienta" }
        if tool.hasPrefix("mcp__") {
            let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
            return "MCP · " + (parts.last.map(String.init) ?? tool)
        }
        switch tool.lowercased() {
        case "bash", "shell", "run_command", "exec_command", "local_shell", "bashoutput", "command_status", "send_command_input":
            return "Terminal"
        case "read", "view_file", "view_file_outline", "view_code_item", "read_file":
            return "Leer"
        case "edit", "multiedit", "replace_file_content", "multi_replace_file_content", "apply_patch", "notebookedit":
            return "Editar"
        case "write", "write_to_file", "write_file":
            return "Escribir"
        case "grep", "glob", "grep_search", "find_by_name", "codebase_search", "list_dir", "ls":
            return "Buscar"
        case "webfetch", "websearch", "read_url_content", "search_web", "web_search":
            return "Web"
        case "task", "agent", "spawn_agent", "delegate_task":
            return "Subagente"
        case "todowrite", "update_plan", "task_boundary":
            return "Plan"
        default:
            if tool.lowercased().hasPrefix("browser_") { return "Navegador" }
            return tool
        }
    }
}

// MARK: - Hook stdout

public enum AgentHookOutput {
    /// What `cleantrash-hook` prints for the agent. nil → print nothing (agent keeps its default flow).
    public static func stdout(for event: AgentEvent, reply: AgentReply?) -> String? {
        if event.source == .antigravity {
            // Antigravity expects a JSON object from every hook.
            return "{}"
        }
        guard event.awaitsDecision, let reply, reply.decision != .ask else { return nil }
        var decision: [String: Any] = ["behavior": reply.decision.rawValue]
        if reply.decision == .deny {
            decision["message"] = reply.reason ?? "Denegado desde el notch de CleanTrash"
        }
        let object: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum AgentBridgePaths {
    public static var supportDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/CleanTrash", isDirectory: true)
    }

    /// Unix socket the app listens on (path must stay under 104 bytes).
    public static var socketPath: String {
        supportDirectory.appendingPathComponent("agents.sock").path
    }

    /// Stable location of the hook binary that agent configs point to (survives moving the app).
    public static var hookBinary: URL {
        supportDirectory.appendingPathComponent("bin/cleantrash-hook")
    }
}
