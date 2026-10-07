//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore

/// `sift doctor` — proves each agent `sift install` would find is wired end to end: the registration, the registered binary, each hook fed a payload of that agent's shape, and the server's tool list.
///
/// Detection and every path come from the same ``AgentDetection/Machine`` and ``SiftPaths`` the install uses, so the two cannot disagree about where an agent lives. Everything it runs runs in a scratch directory with every per-user path pointed into it, removed before it answers.
struct DoctorCommand: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "doctor",
            abstract: "Check that each agent sift is installed into really runs it: registration, binary, hooks, MCP server, version.",
            discussion: """
            One line per check. With no --agent, only the agents found on this machine are checked; one not found is named on a line and skipped, neither counted nor failed. An agent found without sift installed still fails. --agent names the agents to check, found or not. Exits 1 when any check failed.
            """
        )
    }

    @Option(name: .customLong("agent"), help: "Check only this agent, found on this machine or not — claude, cursor or codex; repeat for more than one.")
    var agents: [InstallHookCommand.Agent] = []

    @Option(name: .customLong("cursor-dir"), help: "The directory holding Cursor's mcp.json and hooks.json (defaults to ~/.cursor); checks Cursor whether or not it was found.")
    var cursorDirectory: String?

    @Flag(name: .customLong("json"), help: "Print the answer as one JSON object.")
    var json = false

    @Option(name: .customLong("codex-dir"), help: "The Codex home to check, holding hooks.json and config.toml (defaults to $CODEX_HOME, else ~/.codex); checks Codex whether or not it was found.")
    var codexDirectory: String?

    /// Where the answer goes, injected so a test can read what doctor printed.
    var output: CommandOutput = .standard

    /// Who runs `codex mcp get`, injected so a test never runs the real `codex`; `nil` runs the one on the PATH the machine's environment names.
    var codex: (any CodexMcpRunner)?

    /// Everything detection reads and every path is resolved from, injected so a test stands in for the whole machine.
    var machine = AgentDetection.Machine(environment: ProcessInfo.processInfo.environment)

    /// Refuses `--cursor-dir` when the agents named leave Cursor out, so the flag is never silently ignored.
    func validate() throws {
        guard cursorDirectory == nil || agents.isEmpty || agents.contains(.cursor) else {
            throw ValidationError("--cursor-dir applies only when Cursor is checked — add --agent cursor")
        }
        guard codexDirectory == nil || agents.isEmpty || agents.contains(.codex) else {
            throw ValidationError("--codex-dir applies only with --agent codex")
        }
    }

    func run() throws {
        let report = try diagnose()
        if json {
            let data = try JSONSerialization.data(withJSONObject: report.json, options: [.sortedKeys])
            output.emit(String(bytes: data, encoding: .utf8) ?? "{}")
        } else {
            for line in report.lines {
                output.emit(line)
            }
        }
        if !report.failed.isEmpty {
            throw ExitCode(1)
        }
    }

    /// Every check of every agent asked about: the agents found with no `--agent`, those named with it.
    ///
    /// The skipped are the agents left out for not being found.
    func diagnose() throws -> DoctorReport {
        let detection = AgentDetection.detect(machine)
        let asked = agents.isEmpty ? InstallAgent.allCases : InstallAgent.allCases.filter { agent in agents.contains { $0.rawValue == agent.rawValue } }
        let probe = try DoctorProbe(environment: machine.environment)
        defer { probe.close() }
        var checks: [DoctorCheck] = []
        var skipped: [(agent: InstallAgent, lookedFor: [String])] = []
        for agent in asked {
            let finding = detection.finding(agent)
            guard finding.isDetected || !agents.isEmpty || (agent == .cursor && cursorDirectory != nil) || (agent == .codex && codexDirectory != nil) else {
                skipped.append((agent, finding.lookedFor))
                continue
            }
            switch agent {
            case .claude:
                checks += DoctorClaude(environment: machine.environment, probe: probe).checks()
            case .cursor:
                let directory = cursorDirectory.map { URL(fileURLWithPath: $0) } ?? SiftPaths.cursorDirectory(environment: machine.environment)
                checks += DoctorCursor(directory: directory, probe: probe).checks()
            case .codex:
                let home = CodexInstall.home(flag: codexDirectory, environment: machine.environment)
                checks += DoctorCodex(home: home, runner: codex ?? CodexCLI(environment: machine.environment), probe: probe).checks()
            }
        }
        return DoctorReport(checks: checks, skipped: skipped)
    }
}

extension DoctorCommand {
    /// Only the flags come off the command line; the injected parts keep their defaults on the parse path.
    enum CodingKeys: String, CodingKey {
        case agents
        case cursorDirectory
        case json
        case codexDirectory
    }
}
