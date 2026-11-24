import Foundation

/// Adds / removes CleanTrash's hook in each agent's config without touching anyone else's hooks.
///
/// - Claude Code (also T3 Code's Claude threads): `~/.claude/settings.json` → `hooks.<Event>[]`
/// - Codex (also T3 Code's Codex threads): `~/.codex/hooks.json` → `hooks.<Event>[]`
/// - Antigravity: `~/.gemini/config/hooks.json` → named entry `"cleantrash"`
public struct AgentHookInstaller: Sendable {
    public static let marker = "cleantrash-hook"
    static let antigravityKey = "cleantrash"

    public let home: URL
    public let hookPath: String

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()), hookPath: String = AgentBridgePaths.hookBinary.path) {
        self.home = home
        self.hookPath = hookPath
    }

    public func configURL(for source: AgentSource) -> URL {
        switch source {
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .codex: return home.appendingPathComponent(".codex/hooks.json")
        case .antigravity: return home.appendingPathComponent(".gemini/config/hooks.json")
        }
    }

    /// The agent looks installed on this Mac (its config folder exists).
    public func isAgentPresent(_ source: AgentSource) -> Bool {
        FileManager.default.fileExists(atPath: configURL(for: source).deletingLastPathComponent().path)
    }

    public func isInstalled(_ source: AgentSource) -> Bool {
        guard let root = load(source) else { return false }
        switch source {
        case .claude, .codex:
            guard let hooks = root["hooks"] as? [String: Any] else { return false }
            return hooks.values.contains { Self.groups($0).contains(where: Self.isOurs) }
        case .antigravity:
            return root[Self.antigravityKey] != nil
        }
    }

    func command(for source: AgentSource) -> String {
        "\"\(hookPath)\" --source \(source.rawValue)"
    }

    /// Events registered per agent, with timeouts (seconds). Permission requests wait for a click.
    static func events(for source: AgentSource) -> [(name: String, timeout: Int, toolScoped: Bool)] {
        switch source {
        case .claude:
            return [
                ("SessionStart", 5, false), ("UserPromptSubmit", 5, false),
                ("PreToolUse", 5, true), ("PostToolUse", 5, true), ("PostToolUseFailure", 5, true),
                ("PermissionRequest", 120, true), ("Notification", 5, false),
                ("Stop", 5, false), ("StopFailure", 5, false), ("PreCompact", 5, false), ("SessionEnd", 5, false)
            ]
        case .codex:
            return [
                ("SessionStart", 5, false), ("UserPromptSubmit", 5, false),
                ("PreToolUse", 5, false), ("PostToolUse", 5, false),
                ("PermissionRequest", 120, false), ("Stop", 5, false), ("SessionEnd", 5, false)
            ]
        case .antigravity:
            // PreToolUse is skipped on purpose: it must return a decision for *every* tool call.
            return [("SessionStart", 5, false), ("PreInvocation", 5, false), ("PostToolUse", 5, true), ("Stop", 5, false)]
        }
    }

    public func install(_ source: AgentSource) throws {
        var root = load(source) ?? [:]
        let command = command(for: source)

        switch source {
        case .claude, .codex:
            var hooks = Self.stripped(root["hooks"] as? [String: Any] ?? [:])
            for event in Self.events(for: source) {
                var group: [String: Any] = [
                    "hooks": [["type": "command", "command": command, "timeout": event.timeout]]
                ]
                if event.toolScoped { group["matcher"] = "*" }
                // Appended last so existing entries keep their indexes (Codex trust is keyed by index).
                hooks[event.name] = Self.groups(hooks[event.name]) + [group]
            }
            root["hooks"] = hooks
        case .antigravity:
            var entry: [String: Any] = [:]
            for event in Self.events(for: source) {
                let handler: [String: Any] = ["type": "command", "command": command, "timeout": event.timeout]
                entry[event.name] = event.toolScoped ? [["matcher": "*", "hooks": [handler]]] : [handler]
            }
            root[Self.antigravityKey] = entry
        }
        try save(root, for: source)
    }

    public func uninstall(_ source: AgentSource) throws {
        guard var root = load(source) else { return }
        switch source {
        case .claude, .codex:
            guard let hooks = root["hooks"] as? [String: Any] else { return }
            root["hooks"] = Self.stripped(hooks)
        case .antigravity:
            guard root[Self.antigravityKey] != nil else { return }
            root.removeValue(forKey: Self.antigravityKey)
        }
        try save(root, for: source)
    }

    // MARK: - JSON plumbing

    static func groups(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }

    static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains {
            ($0["command"] as? String)?.contains(marker) == true
        }
    }

    /// Removes our groups everywhere, dropping events left empty.
    static func stripped(_ hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let list = value as? [[String: Any]] else {
                result[event] = value
                continue
            }
            let kept = list.filter { !isOurs($0) }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    func load(_ source: AgentSource) -> [String: Any]? {
        guard let data = try? Data(contentsOf: configURL(for: source)), !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func save(_ root: [String: Any], for source: AgentSource) throws {
        let url = configURL(for: source)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // One backup per file, taken before CleanTrash's first edit.
        let backup = url.appendingPathExtension("cleantrash-backup")
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) {
            try? fm.copyItem(at: url, to: backup)
        }
        var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }
}
