//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// How `sift install` prints what it did: each agent's installer lines under its name, then one summary saying per agent what was written and the one thing left to do, with what is unsupported and experimental said once.
struct InstallSummary {
    /// The lines an installer prints on every run, left out of its section and said once in the summary instead; the restart lines give way to ``nextStep(_:)``.
    static var gathered: [String] {
        CursorInstall.unsupported + [CursorHookInstaller.experimental]
            + CodexInstall.unsupported + [CodexHookInstaller.experimental]
            + [CursorHookInstaller.restart, CodexHookInstaller.restart]
    }

    /// The section for one agent's step: its name, then every line its installers printed except the gathered ones, indented.
    static func section(_ report: InstallStepReport) -> [String] {
        let gathered = Set(gathered)
        return ["\(report.agent.harness):"] + report.lines.filter { !gathered.contains($0) }.map { "  \($0)" }
    }

    /// The summary of every step: a line per agent, then the unsupported and experimental lines the steps printed, each once.
    static func summary(_ reports: [InstallStepReport]) -> [String] {
        let restarts: Set = [CursorHookInstaller.restart, CodexHookInstaller.restart]
        var caveats: [String] = []
        for line in reports.flatMap(\.lines) where gathered.contains(line) && !restarts.contains(line) && !caveats.contains(line) {
            caveats.append(line)
        }
        return ["", "Summary:"] + reports.map { "  " + verdict($0) } + caveats.map { "  " + $0 }
    }

    /// The one manual step after an install into `agent` that changed something.
    static func nextStep(_ agent: InstallAgent) -> String {
        switch agent {
        case .claude:
            "start a new Claude Code session"
        case .cursor:
            "restart Cursor"
        case .codex:
            "restart Codex; it asks you to trust the sift hooks when it next opens"
        }
    }

    private static func verdict(_ report: InstallStepReport) -> String {
        let name = report.agent.harness
        if !report.failures.isEmpty {
            return "\(name): failed — \(report.failures.joined(separator: "; "))"
        }
        guard report.changed else { return "\(name): already installed, nothing to do" }
        let wrote = report.written.isEmpty ? [] : ["wrote \(report.written.joined(separator: ", "))"]
        let registered = report.registered ? ["registered the MCP server"] : []
        return "\(name): installed — \((wrote + registered).joined(separator: "; ")). Next: \(nextStep(report.agent))."
    }
}
