//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore

/// `sift install` — finds Claude Code, Cursor and Codex on this machine and installs into each one chosen, through the same installers as `install-hook`, ending with one summary.
///
/// One agent's failure is said and the others still run; the exit status is 1 when any failed. A second run changes nothing and says so.
struct InstallCommand: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "install",
            abstract: "Set sift up in every agent found on this machine — Claude Code, Cursor, Codex — asking once per agent (idempotent; re-run to upgrade).",
            discussion: """
            Without a terminal to ask on, nothing is installed unless --yes, --all or --agent says what to install into.
            Exits 1 when any agent's install failed; the others are still installed.
            """
        )
    }

    @Option(name: .customLong("agent"), help: "Install into this agent — claude, cursor or codex — whether or not it was found, without asking; repeat for more than one.")
    var agents: [InstallHookCommand.Agent] = []

    @Flag(name: .customLong("all"), help: "Install into all three agents, whether or not each was found, without asking.")
    var all = false

    @Flag(name: .customLong("yes"), help: "Install into every agent found, without asking.")
    var yes = false

    @Flag(name: .customLong("dry-run"), help: "Say what was found and what an install would write; write nothing and run nothing.")
    var dryRun = false

    /// Where the answer goes, injected so a test can read what the install printed.
    var output: CommandOutput = .standard

    /// Everything detection reads and every path is resolved from, injected so a test stands in for the whole machine.
    var machine = AgentDetection.Machine(environment: ProcessInfo.processInfo.environment)

    /// Who is asked whether to install into each agent found and whether to add Claude Code's allow rules, and whether anyone is there to ask, injected so a test answers for the terminal or its absence.
    var prompt: AllowRunPrompt = .standard

    /// Who runs `claude mcp`, injected so a test never runs the real `claude`; `nil` runs the one on the PATH the machine's environment names.
    var claude: (any ClaudeMcpRunner)?

    /// Who runs `codex mcp`, injected so a test never runs the real `codex`; `nil` runs the one on the PATH the machine's environment names.
    var codex: (any CodexMcpRunner)?

    /// The command line this process was started with, injected so a test can say how the binary was invoked.
    var arguments: [String] = CommandLine.arguments

    /// This process's own executable, injected so a test can say which file is running.
    var executable: String? = Bundle.main.executablePath

    func run() throws {
        let environment = machine.environment
        let binary = InstallHookCommand.binaryPath(invokedAs: arguments.first ?? SiftPaths.binaryName, environment: environment, executable: executable)
        if InvokedBinary.isInNpxCache(binary) {
            throw InstallHookCommand.npxCacheRefusal(binary, rerun: "sift install")
        }
        let detection = AgentDetection.detect(machine)
        let flags = AgentSelection.Flags(agents: agents.compactMap { InstallAgent(rawValue: $0.rawValue) }, all: all, yes: yes, dryRun: dryRun)
        var selection = AgentSelection.decide(flags, detection: detection, isInteractive: prompt.isInteractive)
        if case let .ask(found) = selection {
            output.emit(detection.text)
            selection = AgentSelection.afterAsking(accepted: InstallPrompt(ask: prompt.ask).choose(found))
        }
        switch selection {
        case .needsFlags:
            output.emit(AgentSelection.needsFlagsText(detected: detection))
        case .nothingDetected:
            output.emit(AgentSelection.nothingDetectedText(detection))
        case let .nothingToDo(reason):
            output.emit(reason)
        case .ask:
            break
        case let .install(picks) where dryRun:
            for line in InstallDryRun.lines(picks, detection: detection, binary: binary, environment: environment) {
                output.emit(line)
            }
        case let .install(picks):
            try install(picks, binary: binary)
        }
    }

    /// Runs each pick's step, printing its note, its section and then the summary; exits 1 when any step failed.
    private func install(_ picks: [AgentSelection.Pick], binary: String) throws {
        var reports: [InstallStepReport] = []
        for pick in picks {
            if let note = pick.note {
                output.emit(note)
            }
            let report = step(pick.agent, binary: binary)
            for line in InstallSummary.section(report) {
                output.emit(line)
            }
            reports.append(report)
        }
        for line in InstallSummary.summary(reports) {
            output.emit(line)
        }
        if reports.contains(where: { !$0.failures.isEmpty }) {
            throw ExitCode(1)
        }
    }

    /// One agent's step, its lines captured and its failure kept to itself.
    private func step(_ agent: InstallAgent, binary: String) -> InstallStepReport {
        let environment = machine.environment
        let capture = InstallCapture()
        return InstallStepReport.attempt(agent, capture: capture) {
            switch agent {
            case .claude:
                try ClaudeInstallStep(
                    binary: binary,
                    environment: environment,
                    arguments: arguments,
                    executable: executable,
                    runner: claude ?? ClaudeCLI(environment: environment),
                    prompt: prompt
                ).run(output: capture.output)
            case .cursor:
                try CursorInstallStep.run(binary: binary, environment: environment, output: capture.output)
            case .codex:
                try CodexInstallStep.run(binary: binary, environment: environment, runner: codex ?? CodexCLI(environment: environment), output: capture.output)
            }
        }
    }
}

extension InstallCommand {
    /// Only the flags come off the command line; the injected parts keep their defaults on the parse path.
    enum CodingKeys: String, CodingKey {
        case agents
        case all
        case yes
        case dryRun
    }
}
