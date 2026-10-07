//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore
import SiftMCP

/// `sift uninstall` — the one command that takes the tool back out: hooks, status line, MCP server, band plugin and agent rule, with every `.sift/` directory and `.bak-sift` backup it left listed, and deleted under `--purge`.
struct UninstallCommand: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "uninstall",
            abstract: "Remove sift from Claude Code — hooks, status line, MCP server, agent rule, the band plugin — and from Cursor's ~/.cursor and the Codex home ($CODEX_HOME, else ~/.codex), and list the .sift/ directories it left (idempotent).",
            discussion: """
            Nothing is deleted from a repository without --purge. The binary is left in place; the last line is the command that removes it.
            Exits 1 when anything the answer names was not removed or was refused (the verdict counts them as "not removed"), 0 otherwise.
            """
        )
    }

    @Option(name: .customLong("settings"), help: "Settings file to edit (defaults to ~/.claude/settings.json); the band plugin, which `claude plugin` registers in the user's own settings, is then left alone.")
    var settings: String?

    @Flag(name: .customLong("purge"), help: "Also delete every listed .sift/ directory (each repository's index and run logs, and ~/.sift with the usage log) and every listed *.bak-sift backup (of settings.json, Cursor's mcp.json and hooks.json, and Codex's hooks.json).")
    var purge = false

    /// Where the answer goes, injected so a test can read what the uninstall printed.
    var output: CommandOutput = .standard

    /// The environment every path is resolved from, injected so a test runs the whole uninstall under a scratch home.
    var environment: [String: String] = ProcessInfo.processInfo.environment

    /// Who takes the MCP server out, injected so a test never runs the real `claude` against the real config.
    var removeServer: @Sendable ([String: String], SiftUninstall.ServerScope) -> SiftUninstall.ServerRemoval = claudeRemovesServer

    /// Who runs `claude plugin`, injected so a test never runs the real `claude` against the real settings.
    var runPlugin: @Sendable ([String: String], [String]) -> SiftUninstall.PluginRun = claudeRunsPlugin

    /// Who runs `codex mcp`, injected so a test never runs the real `codex`; `nil` runs the one on the PATH ``environment`` names.
    var codex: (any CodexMcpRunner)?

    /// The command line this process was started with, injected so a test can say how the binary was invoked.
    var arguments: [String] = CommandLine.arguments

    func run() throws {
        var locations = SiftUninstall.Locations.standard(
            environment: environment,
            usageLog: UsageLog.standardFileURL(environment: environment)
        )
        if let settings {
            locations.settings = URL(fileURLWithPath: settings)
        }
        let environment = environment
        let binary = Self.binaryToRemove(invokedAs: arguments.first ?? SiftPaths.binaryName, environment: environment, executable: Bundle.main.executablePath)
        let runPlugin = runPlugin
        let answer = try SiftUninstall.run(locations, purge: purge, binary: binary, codex: codex ?? CodexCLI(environment: environment), bandSkipped: settings != nil) { scope in
            removeServer(environment, scope)
        } band: { arguments in
            runPlugin(environment, arguments)
        }
        for line in answer.lines {
            output.emit(line)
        }
        if answer.failures > 0 {
            throw ExitCode(1)
        }
    }

    /// The binary the last line removes: the path it was invoked by, or for a bare name the first match on PATH, as the shell found it, else this process's own executable.
    ///
    /// The same path `install-hook` records for the hooks, so the line names the binary they run; the bare name only where nothing at all resolves.
    static func binaryToRemove(invokedAs argument0: String, environment: [String: String], executable: String?) -> String {
        InvokedBinary.path(invokedAs: argument0, environment: environment, executable: executable) ?? argument0
    }

    /// Runs `claude mcp remove sift` at `scope` — the inverse of the registration `install.sh` makes at user scope, or of the README's at local scope, run from that project's directory; `claude` rewrites its own config file, which is live under every running session.
    @Sendable
    static func claudeRemovesServer(environment: [String: String], scope: SiftUninstall.ServerScope) -> SiftUninstall.ServerRemoval {
        guard let claude = InvokedBinary.onPath("claude", environment: environment) else {
            return .noClaude
        }
        let (directory, childEnvironment) = claudeInvocation(scope: scope, environment: environment)
        return switch spawn(claude, scope.removalArguments, in: directory, environment: childEnvironment) {
        case .succeeded:
            .removed
        case let .failed(reason):
            .failed(reason)
        case .noClaude:
            .noClaude
        }
    }

    /// Runs `claude plugin …` with `arguments`, the inverse of the plugin `install.sh` enables at user scope, under the home the environment names.
    @Sendable
    static func claudeRunsPlugin(environment: [String: String], arguments: [String]) -> SiftUninstall.PluginRun {
        guard let claude = InvokedBinary.onPath("claude", environment: environment) else {
            return .noClaude
        }
        let (directory, childEnvironment) = claudeInvocation(scope: .user, environment: environment)
        return spawn(claude, arguments, in: directory, environment: childEnvironment)
    }

    /// Runs `claude` and says how it ended: the first line of what it printed when it did not succeed.
    private static func spawn(_ claude: String, _ arguments: [String], in directory: URL?, environment: [String: String]) -> SiftUninstall.PluginRun {
        do {
            let result = try SimulatorAccessibility.spawn(claude, arguments, deadline: 60, in: directory, environment: environment)
            guard result.succeeded else {
                let reason = [result.standardError, result.standardOutput]
                    .compactMap { $0.split(separator: "\n").first.map(String.init) }
                    .first ?? "no output"
                return .failed(reason)
            }
            return .succeeded
        } catch {
            return .failed("\(error)")
        }
    }

    /// Where `claude` runs for `scope` and with what environment: for a local-scope removal in the project's directory, with `PWD` naming it, so a `claude` that reads either finds that project and not the one this ran from.
    ///
    /// `claude` finds its config through HOME, and every path here was resolved from the home `CFFIXED_USER_HOME` names first, so the child is handed that home: the file it edits is the one read back to confirm the removal.
    static func claudeInvocation(scope: SiftUninstall.ServerScope, environment: [String: String]) -> (directory: URL?, environment: [String: String]) {
        var childEnvironment = environment
        childEnvironment["HOME"] = SiftPaths.userHome(environment: environment).path
        guard case let .local(project) = scope else {
            return (nil, childEnvironment)
        }
        childEnvironment["PWD"] = project.path
        return (project, childEnvironment)
    }
}

extension UninstallCommand {
    /// Only the flags come off the command line; ``output``, ``environment``, ``removeServer``, ``runPlugin`` and ``arguments`` keep their defaults on the parse path.
    enum CodingKeys: String, CodingKey {
        case settings
        case purge
    }
}
