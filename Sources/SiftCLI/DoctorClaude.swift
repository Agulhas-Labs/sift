//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import SiftMCP

/// The Claude Code half of `sift doctor`: reads the registration from the files `sift install` writes, resolved from the same environment, then runs what Claude Code would run.
struct DoctorClaude {
    let environment: [String: String]
    let probe: DoctorProbe

    private var agent: InstallAgent {
        .claude
    }

    /// Every check, in the order the answer lists them.
    func checks() -> [DoctorCheck] {
        let settings = SiftPaths.claudeSettings(environment: environment)
        let hooks: [(event: String, command: String)]
        var checks: [DoctorCheck] = []
        do {
            hooks = try Self.registeredHooks(in: CursorInstall.read(settings, agent: "claude", flag: "--settings"))
            let missing = HookRegistration.events.map(\.name).filter { name in !hooks.contains { $0.event == name } }
            checks.append(Self.hooksCheck(missing: missing, found: hooks.map(\.event), settings: settings))
        } catch {
            hooks = []
            checks.append(.fail(agent, "hooks", String(describing: error)))
        }
        let config = SiftPaths.claudeConfig(environment: environment)
        let server = Self.registeredServer(in: config)
        guard let server else {
            return checks + [.fail(agent, "server", "no MCP server named sift of this tool's in \(config.path); run `sift install --agent claude`")]
        }
        checks.append(.pass(agent, "server", "sift — \(server.command) \(server.arguments.joined(separator: " "))"))
        checks += DoctorRun(agent: agent, probe: probe).binaryChecks(server.command)
        for hook in hooks {
            checks.append(DoctorRun(agent: agent, probe: probe).hook(hook.event, command: hook.command, payload: payload(for: hook.event), jsonOnly: hook.event != "SessionStart" && hook.event != "SubagentStart"))
        }
        checks.append(DoctorRun(agent: agent, probe: probe).server(([server.command] + server.arguments).map(ShellWord.quoted).joined(separator: " ")))
        return checks
    }

    /// Passes only where the registration is also the one this binary writes — the comparison `sift status` makes (``RegisteredHooks/isCurrent``) — so an upgrade that changed a matcher does not read as healthy.
    private static func hooksCheck(missing: [String], found: [String], settings: URL) -> DoctorCheck {
        guard missing.isEmpty else {
            return .fail(.claude, "hooks", "not registered for \(missing.joined(separator: ", ")) in \(settings.path); run `sift install --agent claude`")
        }
        guard RegisteredHooks(settings: settings).isCurrent else {
            return .fail(.claude, "hooks", "registered for \(found.joined(separator: ", ")) in \(settings.path), but not as this version registers them; run `sift install --agent claude`")
        }
        return .pass(.claude, "hooks", "registered for \(found.joined(separator: ", "))")
    }

    /// The first command of this tool's registered for each of its events, in the order ``HookRegistration/events`` lists them.
    static func registeredHooks(in data: Data?) -> [(event: String, command: String)] {
        let settings = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let hooks = settings?["hooks"] as? [String: Any] ?? [:]
        return HookRegistration.events.compactMap { event in
            let entries = hooks[event.name] as? [[String: Any]] ?? []
            let commands = entries.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.compactMap { $0["command"] as? String }
            return commands.first { HookRegistration.isOurs($0, subcommand: event.subcommand) }.map { (event.name, $0) }
        }
    }

    /// The user-scope server named `sift` in `config`, where it is this tool's.
    static func registeredServer(in config: URL) -> (command: String, arguments: [String])? {
        let object = (try? Data(contentsOf: config)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let entry = (object?["mcpServers"] as? [String: Any])?[CursorMcpFile.serverName]
        guard CursorMcpFile.isOurs(entry), let entry = entry as? [String: Any], let command = entry["command"] as? String else { return nil }
        return (command, entry["args"] as? [String] ?? [])
    }

    /// The payload Claude Code hands the hook for `event`, and Codex in the same shape: a call the hook lets through without a word, in the scratch workspace.
    func payload(for event: String) -> [String: Any] {
        var payload: [String: Any] = ["session_id": "sift-doctor", "cwd": probe.workspace.path, "hook_event_name": event, "transcript_path": ""]
        switch event {
        case "SessionStart":
            payload["source"] = "startup"
        case "SubagentStart":
            payload["agent_id"] = "sift-doctor-agent"
            payload["agent_type"] = "general-purpose"
        case "PreToolUse":
            payload["permission_mode"] = "default"
            payload["tool_name"] = "Bash"
            payload["tool_input"] = ["command": "true"]
        case "PostToolUse":
            payload["tool_name"] = "Write"
            payload["tool_input"] = ["file_path": probe.workspace.appendingPathComponent("notes.txt").path, "content": "notes\n"]
            payload["tool_response"] = [String: Any]()
        default:
            payload["stop_hook_active"] = false
        }
        return payload
    }
}
