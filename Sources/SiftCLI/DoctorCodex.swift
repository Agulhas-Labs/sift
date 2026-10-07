//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import SiftMCP

/// The Codex half of `sift doctor`: the hooks in the Codex home's `hooks.json`, their trust in its `config.toml`, and the server `codex mcp get` shows, then what Codex would run, fed Claude Code's payloads, which Codex speaks.
///
/// The home is resolved as the install resolves it (``CodexInstall/home(flag:environment:)``). Without a `codex` to ask, the server is unknown and the binary, version and server run are not checked; the hooks still run, since each carries its own command.
struct DoctorCodex {
    let home: CodexInstall.Home
    let runner: any CodexMcpRunner
    let probe: DoctorProbe

    private var agent: InstallAgent {
        .codex
    }

    /// Every check, in the order the answer lists them.
    func checks() -> [DoctorCheck] {
        let file = home.directory.appendingPathComponent(CodexHooksFile.fileName)
        let hooks: [Registered]
        var checks: [DoctorCheck] = []
        do {
            hooks = try Self.registeredHooks(in: CursorInstall.read(file, agent: "codex", flag: "--codex-dir"))
            let missing = CodexHooksFile.hooks.map(\.event).filter { event in !hooks.contains { $0.event == event } }
            checks.append(hooksCheck(missing: missing, found: hooks.map(\.event), file: file))
        } catch {
            hooks = []
            checks.append(.fail(agent, "hooks", Self.describe(error)))
        }
        if !hooks.isEmpty {
            checks.append(DoctorCodexTrust.check(config: home.directory.appendingPathComponent("config.toml"), hooks: file, positions: hooks.map(\.position)))
        }
        let server = registeredServer()
        checks.append(server.check)
        let run = DoctorRun(agent: agent, probe: probe)
        if let binary = server.binary {
            checks += run.binaryChecks(binary)
        }
        let payloads = DoctorClaude(environment: [:], probe: probe)
        for hook in hooks {
            checks.append(run.hook(hook.event, command: hook.command, payload: payloads.payload(for: hook.event), jsonOnly: hook.event != "SessionStart"))
        }
        if let binary = server.binary {
            checks.append(run.server(([binary] + CursorMcpFile.arguments).map(ShellWord.quoted).joined(separator: " ")))
        }
        return checks
    }

    /// The first handler of this tool's registered for each of its events, where it sits, in the order ``CodexHooksFile/hooks`` lists them.
    static func registeredHooks(in data: Data?) -> [Registered] {
        let file = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let events = file?["hooks"] as? [String: Any] ?? [:]
        return CodexHooksFile.hooks.compactMap { hook in
            for (group, entry) in (events[hook.event] as? [Any] ?? []).enumerated() {
                let handlers = (entry as? [String: Any])?["hooks"] as? [Any] ?? []
                for (index, handler) in handlers.enumerated() {
                    guard let command = (handler as? [String: Any])?["command"] as? String, HookRegistration.isOurs(command, subcommand: hook.subcommand) else { continue }
                    return Registered(event: hook.event, command: command, position: DoctorCodexTrust.Position(event: DoctorCodexTrust.snakeCase(hook.event), group: group, handler: index))
                }
            }
            return nil
        }
    }

    /// The command that registers what is missing, naming the home when it came from `--codex-dir`, where `sift install` would not look.
    private var installHint: String {
        guard home.source == "--codex-dir" else { return "run `sift install --agent codex`" }
        return "run `sift install-hook --agent codex --codex-dir \(ShellWord.quoted(home.directory.path))`"
    }

    private func hooksCheck(missing: [String], found: [String], file: URL) -> DoctorCheck {
        guard missing.isEmpty else {
            return .fail(agent, "hooks", "not registered for \(missing.joined(separator: ", ")) in \(file.path) (Codex home from \(home.source)); \(installHint)")
        }
        return .pass(agent, "hooks", "registered for \(found.joined(separator: ", ")) in \(file.path) (Codex home from \(home.source))")
    }

    /// The server check, and the binary it runs where it is this tool's.
    private func registeredServer() -> (check: DoctorCheck, binary: String?) {
        let asked = "`codex \(CodexMcpServer.getArguments.joined(separator: " "))`"
        let found: CodexMcpServer.Found
        do {
            found = try CodexMcpServer.find(runner: runner, home: home.directory)
        } catch {
            return (.unknown(agent, "server", "\(asked) did not answer: \(Self.describe(error)); binary, version and mcp server not checked"), nil)
        }
        return switch found {
        case let .ours(binary):
            (.pass(agent, "server", "sift — \(binary) \(CursorMcpFile.arguments.joined(separator: " "))"), binary)
        case .absent:
            (.fail(agent, "server", "no MCP server named sift in \(home.directory.path); \(installHint)"), nil)
        case let .foreign(existing):
            (.fail(agent, "server", "the MCP server named sift in \(home.directory.path) runs something else (\(existing)); \(installHint)"), nil)
        case .noCodex:
            (.unknown(agent, "server", "`codex` is not on PATH to ask \(asked); binary, version and mcp server not checked"), nil)
        }
    }

    /// A refusal as the path and why, without the install's "nothing written".
    private static func describe(_ error: any Error) -> String {
        guard let refused = error as? CursorInstall.Refused else { return String(describing: error) }
        return "\(refused.path) \(refused.reason)"
    }
}

extension DoctorCodex {
    /// One handler of this tool's in `hooks.json`: the event, the command it runs and where it sits.
    struct Registered {
        let event: String
        let command: String
        let position: DoctorCodexTrust.Position
    }
}
