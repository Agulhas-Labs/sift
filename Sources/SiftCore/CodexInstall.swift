//
// Copyright © Agulhas Labs
//

import Foundation

/// `install-hook --agent codex` and its inverse: the hooks in the Codex home's `hooks.json`, merged here with the guarantees `settings.json` gets, and the MCP server, registered through `codex mcp` (``CodexMcpServer``).
///
/// The hooks file is read and merged, and the server looked up, before anything is written, so a refusal of either leaves both as they were. Codex runs a hook only once the user has trusted it, and nothing here trusts one on their behalf.
public struct CodexInstall {
    /// What the install output names as not carried over to Codex, one line each.
    public static var unsupported: [String] {
        [
            "unsupported on Codex: sift audit — Codex's session log is not a documented interface",
            "unsupported on Codex: a Swift-scoped rule — Codex's AGENTS.md applies to every project, so none is written",
            "unsupported on Codex: the subagent primer — no Codex hook for a subagent's start has been verified",
            "unsupported on Codex: the post-edit note for a file apply_patch moves — no payload of a move has been captured",
        ]
    }

    /// The Codex home a run uses: `flag` (`--codex-dir`) when given, else Codex's own rule (``SiftPaths/codexDirectory(environment:)``).
    public static func home(flag: String?, environment: [String: String]) -> Home {
        if let flag {
            return Home(directory: URL(fileURLWithPath: flag, isDirectory: true), source: "--codex-dir")
        }
        let fromEnvironment = environment["CODEX_HOME"].map { !$0.isEmpty } ?? false
        return Home(directory: SiftPaths.codexDirectory(environment: environment), source: fromEnvironment ? "$CODEX_HOME" : "~/.codex")
    }

    /// Registers the hooks and the server in `home` for `binary`, an absolute path, the same path shell-quoted as the first word of each hook's command.
    public static func install(home: Home, binary: String, binaryWord: String, runner: any CodexMcpRunner) throws -> CursorInstall.Outcome {
        let hooksURL = home.directory.appendingPathComponent(CodexHooksFile.fileName)
        let original = try CursorInstall.read(hooksURL, agent: agent, flag: "--codex-dir")
        let hooks = try CursorInstall.merge(hooksURL, agent: agent) { try CodexHooksFile.apply(to: original, binaryWord: binaryWord) }
        // Codex refuses a CODEX_HOME that is not there, so the directory is made before it is asked anything.
        do {
            try FileManager.default.createDirectory(at: home.directory, withIntermediateDirectories: true)
        } catch {
            throw CursorInstall.Refused(path: home.directory.path, reason: "could not be made: \(error.localizedDescription)", agent: agent)
        }
        let found = try CodexMcpServer.find(runner: runner, home: home.directory)

        var outcome = CursorInstall.Outcome(lines: [], notes: [], written: [])
        if hooks.changed {
            outcome.lines += hooks.replaced.map { "hooks: replaced stale registration (\($0))" }
            outcome.lines += CodexHooksFile.hooks.map { "hooks: registered \($0.event) — \(CodexHooksFile.command(for: $0, binaryWord: binaryWord))" }
        } else {
            outcome.lines.append("hooks: already registered — \(CodexHooksFile.hooks.map(\.event).joined(separator: ", "))")
        }
        try outcome.write(hooksURL, hooks.data, original: original, if: hooks.changed)
        try register(binary, found: found, home: home, runner: runner, into: &outcome)
        return outcome
    }

    /// Takes out what the install wrote, and nothing else: a foreign `sift` server and every foreign hook stay, and a Codex home that is not there is not looked into.
    public static func uninstall(home: Home, runner: any CodexMcpRunner) throws -> CursorInstall.Outcome {
        var outcome = CursorInstall.Outcome(lines: [], notes: [], written: [])
        guard PathKind.of(home.directory) != .absent else { return outcome }
        let hooksURL = home.directory.appendingPathComponent(CodexHooksFile.fileName)
        let original = try CursorInstall.read(hooksURL, agent: agent, flag: "--codex-dir")
        let hooks = try CursorInstall.merge(hooksURL, agent: agent) { try CodexHooksFile.remove(from: original) }
        let found = try CodexMcpServer.find(runner: runner, home: home.directory)

        outcome.lines += hooks.removed.map { "hooks: removed \($0)" }
        try outcome.write(hooksURL, hooks.data, original: original, if: hooks.changed)
        switch found {
        case let .ours(command):
            let removal = try runner.run(CodexMcpServer.removeArguments, home: home.directory)
            if let removal, removal.succeeded {
                outcome.lines.append("mcp: removed \(CursorMcpFile.serverName) — \(command) \(CursorMcpFile.arguments.joined(separator: " "))")
            } else {
                let reason = removal.map(CodexMcpServer.firstLine(of:)) ?? "`codex` is no longer on PATH"
                outcome.failures.append("mcp: not removed — `codex \(CodexMcpServer.removeArguments.joined(separator: " "))` failed: \(reason); run: \(manual(CodexMcpServer.removeArguments, home: home))")
            }
        case let .foreign(existing):
            outcome.notes.append("mcp: not ours, left alone — a server named \(CursorMcpFile.serverName) in \(home.directory.path) runs something else (\(existing))")
        case .noCodex where hooks.changed:
            // The hooks say this tool was installed here, so the server most likely was too; without `codex` there is no asking.
            outcome.notes.append("mcp: not checked — `codex` is not on PATH; if Codex runs this tool's server, run: \(manual(CodexMcpServer.removeArguments, home: home))")
        case .absent, .noCodex:
            break
        }
        return outcome
    }

    /// The harness a refusal names.
    private static var agent: String {
        "codex"
    }

    /// Registers the server unless a foreign one holds the name or ours is already there, and says which.
    private static func register(_ binary: String, found: CodexMcpServer.Found, home: Home, runner: any CodexMcpRunner, into outcome: inout CursorInstall.Outcome) throws {
        let name = CursorMcpFile.serverName
        let registered = "\(binary) \(CursorMcpFile.arguments.joined(separator: " "))"
        let arguments = CodexMcpServer.addArguments(binary: binary)
        if case let .foreign(existing) = found {
            return outcome.lines.append("mcp: left alone — a server named \(name) runs something else (\(existing))")
        }
        switch found {
        case .ours(binary):
            return outcome.lines.append("mcp: already registered — \(registered)")
        case let .ours(previous):
            outcome.lines.append("mcp: replaced stale registration (\(previous) \(CursorMcpFile.arguments.joined(separator: " ")))")
        case .noCodex:
            return outcome.lines.append("mcp: `codex` is not on PATH — register the server with: \(manual(arguments, home: home))")
        case .absent, .foreign:
            break
        }
        let added = try runner.run(arguments, home: home.directory)
        guard let added, added.succeeded else {
            let reason = added.map(CodexMcpServer.firstLine(of:)) ?? "`codex` is no longer on PATH"
            return outcome.failures.append("mcp: not registered — `codex \(arguments.prefix(3).joined(separator: " "))` failed: \(reason); run: \(manual(arguments, home: home))")
        }
        outcome.lines.append("mcp: registered \(name) — \(registered)")
    }

    /// `codex` with `arguments` as a person pastes it, naming the home in `CODEX_HOME` when it came from `--codex-dir`, where a plain `codex` would not look.
    private static func manual(_ arguments: [String], home: Home) -> String {
        let command = (["codex"] + arguments.map(ShellWord.quoted)).joined(separator: " ")
        guard home.source == "--codex-dir" else { return command }
        return "CODEX_HOME=\(ShellWord.quoted(home.directory.path)) \(command)"
    }
}

public extension CodexInstall {
    /// The Codex home a run uses and where that came from, which every answer names, since `CODEX_HOME` often points somewhere a person would not look.
    struct Home: Equatable, Sendable {
        public let directory: URL
        /// `--codex-dir`, `$CODEX_HOME` or `~/.codex`.
        public let source: String

        public init(directory: URL, source: String) {
            self.directory = directory
            self.source = source
        }

        /// The line every answer opens with.
        public var line: String {
            "codex home: \(directory.path) (\(source))"
        }
    }
}
