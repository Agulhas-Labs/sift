//
// Copyright © Agulhas Labs
//

import Foundation

/// What `sift install` finds on a machine for each agent it can install into: whether the agent is there and by which sign, and every file an install into it would write.
///
/// Everything it looks at comes through a ``Machine``, so a test names the whole machine and never reads the real one.
public struct AgentDetection: Equatable, Sendable {
    /// One finding per agent, in ``InstallAgent`` order.
    public let findings: [Finding]

    /// The agents found, in ``InstallAgent`` order.
    public var detected: [InstallAgent] {
        findings.filter(\.isDetected).map(\.agent)
    }

    /// Looks for every agent on `machine`.
    public static func detect(_ machine: Machine) -> AgentDetection {
        AgentDetection(findings: InstallAgent.allCases.map { finding($0, on: machine) })
    }

    /// The finding for `agent`.
    public func finding(_ agent: InstallAgent) -> Finding {
        findings.first { $0.agent == agent } ?? Finding(agent: agent, reason: nil, lookedFor: [], targets: [])
    }

    /// One line per agent — found and by which sign, or not found and what was looked for — with the files an install would write indented beneath it.
    public var text: String {
        findings.flatMap { finding in
            [finding.line] + finding.targets.map { "    would write \($0.url.path) (\($0.what))" }
        }
        .joined(separator: "\n")
    }

    /// The signs of `agent` looked for on `machine`, in the order a reason is taken from.
    static func signs(of agent: InstallAgent, on machine: Machine) -> [Sign] {
        let environment = machine.environment
        return switch agent {
        case .claude:
            [
                .onPath("claude"),
                .exists(SiftPaths.claudeDirectory(environment: environment), variable: variable("CLAUDE_CONFIG_DIR", in: environment)),
            ]
        case .cursor:
            [
                .exists(SiftPaths.cursorDirectory(environment: environment), variable: nil),
                .exists(machine.applications.appendingPathComponent("Cursor.app", isDirectory: true), variable: nil),
                .onPath("agent"),
                .onPath("cursor-agent"),
            ]
        case .codex:
            [
                .onPath("codex"),
                .exists(SiftPaths.codexDirectory(environment: environment), variable: variable("CODEX_HOME", in: environment)),
            ]
        }
    }

    /// The files an install into `agent` writes, resolved from `environment` exactly as the installers resolve them.
    static func targets(of agent: InstallAgent, environment: [String: String]) -> [Target] {
        switch agent {
        case .claude:
            return [
                Target(url: SiftPaths.claudeSettings(environment: environment), what: "hooks"),
                Target(url: SiftPaths.claudeConfig(environment: environment), what: "the MCP server at user scope, through `claude mcp add`"),
                Target(url: SiftPaths.claudeRule(environment: environment), what: "the agent rule"),
            ]
        case .cursor:
            let directory = SiftPaths.cursorDirectory(environment: environment)
            return [
                Target(url: directory.appendingPathComponent(CursorMcpFile.fileName), what: "the MCP server"),
                Target(url: directory.appendingPathComponent(CursorHooksFile.fileName), what: "hooks"),
            ]
        case .codex:
            let home = CodexInstall.home(flag: nil, environment: environment)
            return [
                Target(url: home.directory.appendingPathComponent(CodexHooksFile.fileName), what: "hooks, in the Codex home from \(home.source)"),
                Target(url: home.directory.appendingPathComponent("config.toml"), what: "the MCP server, through `codex mcp add`"),
            ]
        }
    }

    private static func finding(_ agent: InstallAgent, on machine: Machine) -> Finding {
        let home = SiftPaths.userHome(environment: machine.environment)
        let signs = signs(of: agent, on: machine)
        let found = signs.first { sign in
            switch sign {
            case let .onPath(name):
                machine.pathLookup(name) != nil
            case let .exists(url, _):
                machine.fileExists(url)
            }
        }
        return Finding(
            agent: agent,
            reason: found.map { $0.reason(home: home) },
            lookedFor: signs.map { $0.label(home: home) },
            targets: targets(of: agent, environment: machine.environment)
        )
    }

    /// `name` when `environment` sets it to something, so a sign found through it says so.
    private static func variable(_ name: String, in environment: [String: String]) -> String? {
        guard let value = environment[name], !value.isEmpty else { return nil }
        return name
    }
}

public extension AgentDetection {
    /// Everything detection reads, each part injectable so a test stands in for the whole machine.
    struct Machine: Sendable {
        /// The environment every path is resolved from, the home included (``SiftPaths/userHome(environment:)``), so detection names the directories the installers write.
        public var environment: [String: String]
        /// Where applications are installed: `/Applications` unless a test moves it.
        public var applications: URL
        /// The executable a name resolves to on the PATH, or `nil`.
        public var pathLookup: @Sendable (String) -> URL?
        /// Whether a file or directory is there.
        public var fileExists: @Sendable (URL) -> Bool

        /// A machine whose PATH lookup and file checks default to the real ones, read through `environment`'s PATH.
        public init(
            environment: [String: String],
            applications: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
            pathLookup: (@Sendable (String) -> URL?)? = nil,
            fileExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
        ) {
            self.environment = environment
            self.applications = applications
            self.pathLookup = pathLookup ?? { name in
                InvokedBinary.onPath(name, environment: environment).map { URL(fileURLWithPath: $0) }
            }
            self.fileExists = fileExists
        }
    }

    /// Whether one agent was found, by which sign, and what an install into it would write.
    struct Finding: Equatable, Sendable {
        public let agent: InstallAgent
        /// The first sign found, as a person reads it, or `nil` when the agent was not found.
        public let reason: String?
        /// Every sign looked for, in order.
        public let lookedFor: [String]
        /// Every file an install would write.
        public let targets: [Target]

        public var isDetected: Bool {
            reason != nil
        }

        /// The finding's line in `text`.
        public var line: String {
            if let reason {
                return "\(agent.harness): found — \(reason)"
            }
            return "\(agent.harness): not found — looked for \(lookedFor.joined(separator: ", "))"
        }
    }

    /// A file an install writes, and what it holds.
    struct Target: Equatable, Sendable {
        public let url: URL
        public let what: String
    }
}

extension AgentDetection {
    /// A sign that an agent is installed.
    enum Sign: Equatable {
        /// An executable of this name on the PATH.
        case onPath(String)
        /// A file or directory at this path, and the environment variable that chose it, if one did.
        case exists(URL, variable: String?)

        /// The sign as a person reads it, a path under the home shortened to `~`.
        func label(home: URL) -> String {
            switch self {
            case let .onPath(name):
                "`\(name)` on PATH"
            case let .exists(url, variable):
                variable.map { "$\($0) (\(url.path))" } ?? Self.shortened(url, home: home)
            }
        }

        /// The sign found, as the reason an agent was detected.
        func reason(home: URL) -> String {
            switch self {
            case .onPath:
                label(home: home)
            case .exists:
                "\(label(home: home)) exists"
            }
        }

        private static func shortened(_ url: URL, home: URL) -> String {
            let prefix = home.standardizedFileURL.path + "/"
            let path = url.standardizedFileURL.path
            return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
        }
    }
}
