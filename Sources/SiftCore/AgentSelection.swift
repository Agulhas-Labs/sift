//
// Copyright © Agulhas Labs
//

import Foundation

/// Which agents `sift install` installs into, decided from its flags, what was detected and whether anyone is at a terminal to ask.
public enum AgentSelection: Equatable, Sendable {
    /// Install into these, without asking.
    case install([Pick])
    /// Ask once per agent, each one detected.
    case ask([InstallAgent])
    /// Nothing to install, and why.
    case nothingToDo(String)
    /// No terminal to ask on and no flag saying what to install: the caller prints `needsFlagsText(detected:)` and installs nothing.
    case needsFlags
    /// No agent was found and none was named: the caller prints `nothingDetectedText(_:)`.
    case nothingDetected

    /// The decision: `--agent` over `--all` over `--yes`; `--dry-run` alone shows the detected agents, since it writes nothing; otherwise a terminal is asked and its absence refused.
    public static func decide(_ flags: Flags, detection: AgentDetection, isInteractive: Bool) -> AgentSelection {
        if !flags.agents.isEmpty {
            return .install(named(flags.agents, detection: detection))
        }
        if flags.all {
            return .install(InstallAgent.allCases.map { Pick(agent: $0) })
        }
        let detected = detection.detected
        if detected.isEmpty {
            return .nothingDetected
        }
        if flags.yes || flags.dryRun {
            return .install(detected.map { Pick(agent: $0) })
        }
        if !isInteractive {
            return .needsFlags
        }
        return .ask(detected)
    }

    /// What asking came to: the agents accepted, or nothing to do when every one was declined.
    public static func afterAsking(accepted: [InstallAgent]) -> AgentSelection {
        guard !accepted.isEmpty else { return .nothingToDo("every agent was declined, so nothing was installed") }
        return .install(accepted.map { Pick(agent: $0) })
    }

    /// Every agent and the signs it is found by, with the command that installs into it anyway.
    public static func nothingDetectedText(_ detection: AgentDetection) -> String {
        let agents = detection.findings.map { finding in
            "  \(finding.agent.harness), found by \(finding.lookedFor.joined(separator: ", ")): sift install --agent \(finding.agent.rawValue)"
        }
        return (["No agent found to install into. Name one to install into it anyway:"] + agents + ["Or all three: sift install --all"])
            .joined(separator: "\n")
    }

    /// What was found and the command that installs into it, for a run with no terminal to ask on.
    public static func needsFlagsText(detected detection: AgentDetection) -> String {
        let detected = detection.detected
        guard !detected.isEmpty else { return nothingDetectedText(detection) }
        let named = detected.map { "--agent \($0.rawValue)" }.joined(separator: " ")
        return [
            detection.text,
            "Nothing installed: there is no terminal to ask on. To install into what was found: sift install --yes",
            "  or name each one: sift install \(named)",
        ]
        .joined(separator: "\n")
    }

    /// The agents `--agent` named, once each and in ``InstallAgent`` order, each one not detected carrying a note that it is installed because it was named.
    private static func named(_ agents: [InstallAgent], detection: AgentDetection) -> [Pick] {
        InstallAgent.allCases.filter(agents.contains).map { agent in
            let finding = detection.finding(agent)
            guard !finding.isDetected else { return Pick(agent: agent) }
            return Pick(agent: agent, note: "\(agent.harness) was not found (looked for \(finding.lookedFor.joined(separator: ", "))); installing because --agent \(agent.rawValue) named it")
        }
    }
}

public extension AgentSelection {
    /// The selection flags `sift install` was given.
    struct Flags: Equatable, Sendable {
        /// Every `--agent`, as given.
        public var agents: [InstallAgent]
        public var all: Bool
        public var yes: Bool
        public var dryRun: Bool

        public init(agents: [InstallAgent] = [], all: Bool = false, yes: Bool = false, dryRun: Bool = false) {
            self.agents = agents
            self.all = all
            self.yes = yes
            self.dryRun = dryRun
        }
    }

    /// An agent to install into, and a note to print before its step when it was named without being found.
    struct Pick: Equatable, Sendable {
        public let agent: InstallAgent
        public let note: String?

        public init(agent: InstallAgent, note: String? = nil) {
            self.agent = agent
            self.note = note
        }
    }
}
