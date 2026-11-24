import CleanTrashCore
import Foundation
import Testing

@Suite("Agent bridge")
struct AgentBridgeTests {
    @Test("Claude PreToolUse inside T3 Code is normalized with the command and host")
    func normalizesClaude() throws {
        let payload: [String: Any] = [
            "hook_event_name": "PreToolUse", "session_id": "s1", "cwd": "/tmp/proj",
            "tool_name": "Bash", "tool_input": ["command": "swift build\n-c release"], "tool_use_id": "t1"
        ]
        let event = try #require(AgentEventNormalizer.normalize(
            payload, source: .claude,
            environment: ["__CFBundleIdentifier": "com.t3tools.t3code", "T3CODE_THREAD_ID": "th"]
        ))
        #expect(event.phase == .runningTool)
        #expect(event.detail == "swift build ⏎ -c release")
        #expect(event.projectName == "proj")
        #expect(event.isT3Code)
        #expect(AgentToolLabel.label(for: event.tool) == "Terminal")
        // permission_prompt notifications duplicate PermissionRequest and are dropped.
        #expect(AgentEventNormalizer.normalize(["hook_event_name": "Notification", "notification_type": "permission_prompt"], source: .claude) == nil)
    }

    @Test("Antigravity camelCase payloads map to tool + phase and always answer {}")
    func normalizesAntigravity() throws {
        let payload: [String: Any] = [
            "hookEventName": "PostToolUse", "conversationId": "c1", "workspacePaths": ["/w/app"],
            "toolCall": ["id": "x", "name": "run_command", "args": ["CommandLine": "npm test"]], "error": "exit status 1"
        ]
        let event = try #require(AgentEventNormalizer.normalize(payload, source: .antigravity))
        #expect(event.phase == .toolFailed)
        #expect(event.detail == "npm test")
        #expect(event.cwd == "/w/app")
        #expect(AgentHookOutput.stdout(for: event, reply: nil) == "{}")
    }

    @Test("Permission replies become hookSpecificOutput; ask prints nothing")
    func permissionOutput() throws {
        let event = AgentEvent(source: .codex, phase: .needsPermission, hookEvent: "PermissionRequest", sessionID: "s")
        let allow = try #require(AgentHookOutput.stdout(for: event, reply: AgentReply(decision: .allow)))
        #expect(allow.contains("\"behavior\":\"allow\""))
        #expect(allow.contains("\"hookEventName\":\"PermissionRequest\""))
        #expect(AgentHookOutput.stdout(for: event, reply: AgentReply(decision: .ask)) == nil)
        #expect(AgentHookOutput.stdout(for: event, reply: nil) == nil)
    }

    @Test("Installer adds and removes only its own hooks")
    func installerRoundTrip() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agent-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = AgentHookInstaller(home: home, hookPath: "/opt/ct/cleantrash-hook")

        let claudeURL = installer.configURL(for: .claude)
        try FileManager.default.createDirectory(at: claudeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "other-tool"]]]]]
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: claudeURL)

        #expect(!installer.isInstalled(.claude))
        try installer.install(.claude)
        try installer.install(.claude) // idempotent
        #expect(installer.isInstalled(.claude))
        var root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: claudeURL)) as? [String: Any])
        var hooks = try #require(root["hooks"] as? [String: Any])
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stop.count == 2) // the user's hook first, ours appended once
        #expect(root["model"] as? String == "opus")

        try installer.uninstall(.claude)
        root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: claudeURL)) as? [String: Any])
        hooks = try #require(root["hooks"] as? [String: Any])
        #expect(hooks.keys.sorted() == ["Stop"])
        #expect((hooks["Stop"] as? [[String: Any]])?.count == 1)

        try installer.install(.antigravity)
        #expect(installer.isInstalled(.antigravity))
        try installer.uninstall(.antigravity)
        #expect(!installer.isInstalled(.antigravity))
    }

    @Test("Socket round trip: a permission request waits for the app's decision")
    func socketRoundTrip() async throws {
        let path = "/tmp/ct-agent-\(UInt32.random(in: 0...UInt32.max)).sock"
        let received = Received()
        let server = AgentSocketServer(path: path) { event, responder in
            received.add(event)
            responder?.reply(AgentReply(decision: .deny, reason: "nope"))
        }
        try server.start()
        defer { server.stop() }

        let ping = AgentEvent(source: .claude, phase: .thinking, hookEvent: "UserPromptSubmit", sessionID: "a")
        #expect(AgentSocketClient.send(ping, to: path, replyTimeout: 0) == nil)

        let ask = AgentEvent(source: .claude, phase: .needsPermission, hookEvent: "PermissionRequest", sessionID: "a", tool: "Bash")
        let reply = AgentSocketClient.send(ask, to: path, replyTimeout: 5)
        #expect(reply == AgentReply(decision: .deny, reason: "nope"))

        try await Task.sleep(for: .milliseconds(100))
        #expect(received.count == 2)

        // No app listening → nil quickly, never blocks the agent.
        #expect(AgentSocketClient.send(ask, to: path + ".missing", replyTimeout: 5) == nil)
    }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentEvent] = []
    func add(_ event: AgentEvent) { lock.lock(); events.append(event); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return events.count }
}
