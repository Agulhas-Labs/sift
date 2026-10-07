//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import SiftMCP

/// The Cursor half of `sift doctor`: reads the registration from the `mcp.json` and `hooks.json` `sift install` writes in the Cursor directory, then runs what Cursor would run.
struct DoctorCursor {
    /// The Cursor directory: `--cursor-dir`, else `~/.cursor` under the home the environment names.
    let directory: URL
    let probe: DoctorProbe

    private var agent: InstallAgent {
        .cursor
    }

    /// Every check, in the order the answer lists them.
    func checks() -> [DoctorCheck] {
        let hooksFile = directory.appendingPathComponent(CursorHooksFile.fileName)
        let hooks: [(event: String, command: String)]
        var checks: [DoctorCheck] = []
        do {
            hooks = try Self.registeredHooks(in: CursorInstall.read(hooksFile))
            let missing = CursorHooksFile.hooks.map(\.event).filter { name in !hooks.contains { $0.event == name } }
            checks.append(Self.hooksCheck(missing: missing, found: hooks.map(\.event), file: hooksFile))
        } catch {
            hooks = []
            checks.append(.fail(agent, "hooks", String(describing: error)))
        }
        let config = directory.appendingPathComponent(CursorMcpFile.fileName)
        guard let server = DoctorClaude.registeredServer(in: config) else {
            return checks + [.fail(agent, "server", "no MCP server named sift of this tool's in \(config.path); run `sift install --agent cursor`")]
        }
        checks.append(.pass(agent, "server", "sift — \(server.command) \(server.arguments.joined(separator: " "))"))
        checks += DoctorRun(agent: agent, probe: probe).binaryChecks(server.command)
        for hook in hooks {
            let payload = Self.payload(for: hook.event, workspace: probe.workspace)
            checks.append(DoctorRun(agent: agent, probe: probe).hook(hook.event, command: hook.command, payload: payload, jsonOnly: true))
        }
        checks.append(DoctorRun(agent: agent, probe: probe).server(([server.command] + server.arguments).map(ShellWord.quoted).joined(separator: " ")))
        return checks
    }

    private static func hooksCheck(missing: [String], found: [String], file: URL) -> DoctorCheck {
        guard missing.isEmpty else {
            return .fail(.cursor, "hooks", "not registered for \(missing.joined(separator: ", ")) in \(file.path); run `sift install --agent cursor`")
        }
        return .pass(.cursor, "hooks", "registered for \(found.joined(separator: ", "))")
    }

    /// The first command of this tool's registered for each of its events, in the order ``CursorHooksFile/hooks`` lists them.
    static func registeredHooks(in data: Data?) -> [(event: String, command: String)] {
        let file = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let events = file?["hooks"] as? [String: Any] ?? [:]
        return CursorHooksFile.hooks.compactMap { hook in
            let entries = events[hook.event] as? [[String: Any]] ?? []
            let commands = entries.compactMap { $0["command"] as? String }
            return commands.first { HookRegistration.isOurs($0, subcommand: hook.registeredSubcommand) }.map { (hook.event, $0) }
        }
    }

    /// The payload Cursor hands the hook for `event`, in the shape a live Cursor sends: a call the hook lets through without a word, with `workspace` as the one workspace root.
    static func payload(for event: String, workspace: URL) -> [String: Any] {
        var payload: [String: Any] = [
            "conversation_id": "sift-doctor",
            "generation_id": "sift-doctor",
            "cursor_version": "sift-doctor",
            "workspace_roots": [workspace.path],
            "transcript_path": NSNull(),
            "hook_event_name": event,
        ]
        switch event {
        case "sessionStart":
            payload["session_id"] = "sift-doctor"
            payload["is_background_agent"] = false
            payload["composer_mode"] = "agent"
        case "preToolUse":
            payload["tool_name"] = "Shell"
            payload["tool_input"] = ["command": "true"]
            payload["tool_use_id"] = "sift-doctor"
            payload["cwd"] = workspace.path
        default:
            payload["tool_name"] = "Write"
            payload["tool_input"] = ["file_path": workspace.appendingPathComponent("notes.txt").path, "content": "notes\n"]
            payload["tool_output"] = "{\"success\":true}"
            payload["tool_use_id"] = "sift-doctor"
            payload["cwd"] = workspace.path
        }
        return payload
    }
}
