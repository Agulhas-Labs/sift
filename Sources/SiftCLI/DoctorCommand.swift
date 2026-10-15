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
            One line per check. With no --agent, only the agents found on this machine are checked; one not found is named on a line and skipped, neither counted nor failed. An agent found with nothing of sift's in it is named on a line and not counted; one with some of sift's installed but broken still fails. --agent names the agents to check, found or not. Exits 1 when any check failed, or when no agent has sift installed.
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
        if report.failsTheRun {
            throw ExitCode(1)
        }
    }

    /// Every check of every agent asked about: the agents found with no `--agent`, those named with it.
    ///
    /// The skipped are the agents left out for not being found; the not installed are those found with nothing of sift's in them, left out of the checks and the verdict unless named.
    func diagnose() throws -> DoctorReport {
        let detection = AgentDetection.detect(machine)
        let asked = agents.isEmpty ? InstallAgent.allCases : InstallAgent.allCases.filter { agent in agents.contains { $0.rawValue == agent.rawValue } }
        let probe = try DoctorProbe(environment: machine.environment)
        defer { probe.close() }
        var checks: [DoctorCheck] = []
        var skipped: [(agent: InstallAgent, lookedFor: [String])] = []
        var notInstalled: [InstallAgent] = []
        for agent in asked {
            let finding = detection.finding(agent)
            guard finding.isDetected || !agents.isEmpty || (agent == .cursor && cursorDirectory != nil) || (agent == .codex && codexDirectory != nil) else {
                skipped.append((agent, finding.lookedFor))
                continue
            }
            let named = !agents.isEmpty || (agent == .cursor && cursorDirectory != nil) || (agent == .codex && codexDirectory != nil)
            switch agent {
            case .claude:
                var doctor = DoctorClaude(environment: machine.environment, probe: probe)
                if machine.pathLookup("claude") == nil {
                    let binary = InstallHookCommand.binaryPath(invokedAs: CommandLine.arguments.first ?? SiftPaths.binaryName, environment: machine.environment, executable: Bundle.main.executablePath)
                    doctor.manualRegistration = ClaudeMcpInstall.manual(binary: binary)
                }
                if !named, doctor.hasNothingOfSift {
                    notInstalled.append(agent)
                    continue
                }
                checks += doctor.checks()
            case .cursor:
                let directory = cursorDirectory.map { URL(fileURLWithPath: $0) } ?? SiftPaths.cursorDirectory(environment: machine.environment)
                let doctor = DoctorCursor(directory: directory, probe: probe)
                if !named, doctor.hasNothingOfSift {
                    notInstalled.append(agent)
                    continue
                }
                checks += doctor.checks()
            case .codex:
                let home = CodexInstall.home(flag: codexDirectory, environment: machine.environment)
                let doctor = DoctorCodex(home: home, runner: codex ?? CodexCLI(environment: machine.environment), probe: probe)
                if !named, doctor.hasNothingOfSift {
                    notInstalled.append(agent)
                    continue
                }
                checks += doctor.checks()
            }
        }
        return DoctorReport(checks: checks, skipped: skipped, notInstalled: notInstalled)
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
