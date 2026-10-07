//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// What `sift install --dry-run` prints: what was found and what an install would do to each file it writes, with what the Claude Code server and rule steps would do, read without writing a file or running a command.
struct InstallDryRun {
    /// The answer for `picks`, found in `detection`, for `binary` under the home `environment` names.
    static func lines(_ picks: [AgentSelection.Pick], detection: AgentDetection, binary: String, environment: [String: String]) -> [String] {
        var lines = [text(detection, binary: binary, environment: environment)]
        lines += picks.compactMap(\.note)
        if picks.contains(where: { $0.agent == .claude }) {
            let config = SiftPaths.claudeConfig(environment: environment)
            let rule = SiftPaths.claudeRule(environment: environment)
            lines.append("Claude Code MCP server: \(describe(ClaudeMcpInstall.plan(config: config, binary: binary), binary: binary, config: config))")
            lines += LegacyBandCleanup.pending(settings: SiftPaths.claudeSettings(environment: environment))
            lines.append("Claude Code rule: \(describe(ClaudeRuleInstall.plan(source: ClaudeRuleInstall.source(forBinary: binary), destination: rule), at: rule))")
        }
        let names = picks.map(\.agent.harness).joined(separator: ", ")
        lines.append("dry run: nothing written and nothing run; without --dry-run this installs into \(names)")
        return lines
    }

    /// One line per agent as detection says it, with each file an install writes beneath it and what the install would do to that file as it stands.
    ///
    /// A file the install would change reads exactly as ``AgentDetection/text`` has it, so on a machine with nothing installed the two are the same text.
    private static func text(_ detection: AgentDetection, binary: String, environment: [String: String]) -> String {
        detection.findings.flatMap { finding in
            let states = states(of: finding.agent, binary: binary, environment: environment)
            return [finding.line] + finding.targets.map { target in
                (states[target.url.path] ?? .write).line(target)
            }
        }
        .joined(separator: "\n")
    }

    /// What an install into `agent` would do to each file it writes, by path, read through the installers' own merges.
    private static func states(of agent: InstallAgent, binary: String, environment: [String: String]) -> [String: TargetState] {
        let word = ShellWord.quoted(binary)
        switch agent {
        case .claude:
            let settings = SiftPaths.claudeSettings(environment: environment)
            let config = SiftPaths.claudeConfig(environment: environment)
            let rule = SiftPaths.claudeRule(environment: environment)
            return [
                settings.path: TargetState.reading { try claudeSettings(settings, word: word) },
                config.path: server(ClaudeMcpInstall.plan(config: config, binary: binary)),
                rule.path: self.rule(ClaudeRuleInstall.plan(source: ClaudeRuleInstall.source(forBinary: binary), destination: rule)),
            ]
        case .cursor:
            let directory = SiftPaths.cursorDirectory(environment: environment)
            let mcp = directory.appendingPathComponent(CursorMcpFile.fileName)
            let hooks = directory.appendingPathComponent(CursorHooksFile.fileName)
            return [
                mcp.path: TargetState.reading {
                    switch try CursorMcpFile.apply(to: CursorInstall.read(mcp), binary: binary).outcome {
                    case .registered, .replaced:
                        .write
                    case .unchanged, .removed:
                        .installed
                    case let .foreign(existing):
                        TargetState(verb: "left alone", reason: "a server named \(CursorMcpFile.serverName) runs something else (\(existing))")
                    }
                },
                hooks.path: TargetState.reading {
                    try CursorHooksFile.apply(to: CursorInstall.read(hooks), binaryWord: word).changed ? .write : .installed
                },
            ]
        case .codex:
            let home = CodexInstall.home(flag: nil, environment: environment)
            let hooks = home.directory.appendingPathComponent(CodexHooksFile.fileName)
            let config = home.directory.appendingPathComponent("config.toml")
            return [
                hooks.path: TargetState.reading {
                    try CodexHooksFile.apply(to: CursorInstall.read(hooks, agent: "codex", flag: "--codex-dir"), binaryWord: word).changed ? .write : .installed
                },
                // Only `codex mcp get` can say what the file registers, and a dry run runs nothing; a file that is not there registers nothing.
                config.path: PathKind.of(config) == .absent
                    ? .write
                    : TargetState(verb: "not checked", reason: "only `codex mcp get` can say whether sift is registered there"),
            ]
        }
    }

    /// The Claude Code settings as the install merges them: every hook, and an older install's status line taken out; `sift install` never adds the allow rules, having no terminal to ask on.
    private static func claudeSettings(_ url: URL, word: String) throws -> TargetState {
        var merged = try CursorInstall.read(url, agent: "claude", flag: "--settings")
        var changed = false
        for event in HookRegistration.events {
            let result = try HookRegistration.apply(
                to: merged,
                command: "\(word) \(event.subcommand)",
                event: event.name,
                subcommand: event.subcommand,
                matchers: event.matchers,
                timeout: event.timeout
            )
            guard result.changed else { continue }
            merged = result.data
            changed = true
        }
        // Only sift's own status line is named: the install takes it out, and leaves someone else's unmentioned.
        if case .removed = try StatuslineRegistration.remove(from: merged) {
            return TargetState(verb: "would write", reason: "the status line an older install registered would be removed")
        }
        return changed ? .write : .installed
    }

    private static func server(_ plan: ClaudeMcpInstall.Plan) -> TargetState {
        switch plan {
        case .absent, .stale:
            .write
        case .current:
            .installed
        case let .foreign(existing):
            TargetState(verb: "left alone", reason: "a server named sift runs something else (\(existing))")
        case let .unreadable(reason):
            TargetState(verb: "would be refused", reason: reason)
        }
    }

    private static func rule(_ plan: ClaudeRuleInstall.Plan) -> TargetState {
        switch plan {
        case .copy, .replace:
            .write
        case .identical:
            .installed
        case .noSource:
            TargetState(verb: "would be skipped", reason: "no Sift.md ships with this binary")
        case let .symlink(target):
            TargetState(verb: "left alone", reason: "a symlink to \(target)")
        case .refused:
            TargetState(verb: "left alone", reason: "not a plain file")
        }
    }

    private static func describe(_ plan: ClaudeMcpInstall.Plan, binary: String, config: URL) -> String {
        switch plan {
        case .absent:
            "would register \(binary) mcp through `claude mcp add`"
        case .current:
            "already registered"
        case let .stale(previous):
            "would replace the stale registration (\(previous)) with \(binary) mcp"
        case let .foreign(existing):
            "would be left alone — a server named sift runs something else (\(existing))"
        case let .unreadable(reason):
            "would be refused — \(config.path) \(reason)"
        }
    }

    private static func describe(_ plan: ClaudeRuleInstall.Plan, at rule: URL) -> String {
        switch plan {
        case .noSource:
            "would be skipped — no Sift.md ships with this binary"
        case .copy:
            "would copy Sift.md to \(rule.path)"
        case .identical:
            "already installed"
        case let .symlink(target):
            "would be left as is — \(rule.path) is a symlink to \(target)"
        case .replace:
            "would replace \(rule.path), keeping the previous one beside it"
        case .refused:
            "would not be written — \(rule.path) is not a plain file"
        }
    }
}

extension InstallDryRun {
    /// What an install would do to one file, and why when that is anything but writing it.
    private struct TargetState {
        static let write = TargetState(verb: "would write", reason: nil)
        static let installed = TargetState(verb: "already installed", reason: nil)

        let verb: String
        let reason: String?

        /// The state `read` finds, or the refusal the install would stop on: a file that cannot be read or merged is said, never thrown.
        static func reading(_ read: () throws -> TargetState) -> TargetState {
            do {
                return try read()
            } catch let refused as CursorInstall.Refused {
                return TargetState(verb: "would be refused", reason: refused.reason)
            } catch {
                return TargetState(verb: "would be refused", reason: String(describing: error))
            }
        }

        /// The line beneath the agent's, `would write` reading exactly as detection has it.
        func line(_ target: AgentDetection.Target) -> String {
            "    \(verb) \(target.url.path) (\(target.what))" + (reason.map { " — \($0)" } ?? "")
        }
    }
}
