//
// Copyright © Agulhas Labs
//

import Foundation

/// `install-hook --agent cursor` and its inverse: the MCP server in the Cursor directory's `mcp.json` and the hooks in its `hooks.json`, with the guarantees `settings.json` gets.
///
/// Both files are read and merged before either is written, so a refusal of one leaves both as they were. A file that is there and cannot be read, or leads nowhere, is refused rather than read as empty; a rewrite keeps a `.bak-sift` copy beside the file it changes and writes through a symlink, keeping the link (``SettingsFile``). A run with nothing to change writes nothing.
public struct CursorInstall {
    /// What the install output names as not carried over to Cursor, one line each.
    public static var unsupported: [String] {
        [
            "unsupported on Cursor: sift audit — Cursor's transcript format is not a documented interface",
            "unsupported on Cursor: the subagent primer — no Cursor hook for a subagent's start has been verified",
            "unsupported on Cursor: a machine-wide Swift rule — Cursor's rules are per project",
        ]
    }

    /// Registers the server and the hooks in `directory`: the absolute path `mcp.json` names, and the same path as the first word of each hook's shell command.
    public static func install(directory: URL, binary: String, binaryWord: String) throws -> Outcome {
        let mcpURL = directory.appendingPathComponent(CursorMcpFile.fileName)
        let hooksURL = directory.appendingPathComponent(CursorHooksFile.fileName)
        let mcpOriginal = try read(mcpURL)
        let hooksOriginal = try read(hooksURL)
        let server = try merge(mcpURL) { try CursorMcpFile.apply(to: mcpOriginal, binary: binary) }
        let hooks = try merge(hooksURL) { try CursorHooksFile.apply(to: hooksOriginal, binaryWord: binaryWord) }

        var lines: [String] = []
        let registered = "\(binary) \(CursorMcpFile.arguments.joined(separator: " "))"
        switch server.outcome {
        case .registered:
            lines.append("mcp: registered \(CursorMcpFile.serverName) — \(registered)")
        case let .replaced(previous):
            lines.append("mcp: replaced stale registration (\(previous))")
            lines.append("mcp: registered \(CursorMcpFile.serverName) — \(registered)")
        case .unchanged, .removed:
            lines.append("mcp: already registered — \(registered)")
        case let .foreign(existing):
            lines.append("mcp: left alone — a server named \(CursorMcpFile.serverName) runs something else (\(existing))")
        }
        if hooks.changed {
            lines += hooks.replaced.map { "hooks: replaced stale registration (\($0))" }
            lines += CursorHooksFile.hooks.map { "hooks: registered \($0.event) — \(CursorHooksFile.command(for: $0, binaryWord: binaryWord))" }
        } else {
            lines.append("hooks: already registered — \(CursorHooksFile.hooks.map(\.event).joined(separator: ", "))")
        }

        var outcome = Outcome(lines: lines, notes: [], written: [])
        try outcome.write(mcpURL, server.data, original: mcpOriginal, if: server.changed)
        try outcome.write(hooksURL, hooks.data, original: hooksOriginal, if: hooks.changed)
        return outcome
    }

    /// Takes out what the install wrote, and nothing else: a foreign `sift` server and every foreign hook stay, and a file with nothing of ours in it is not rewritten.
    public static func uninstall(directory: URL) throws -> Outcome {
        let mcpURL = directory.appendingPathComponent(CursorMcpFile.fileName)
        let hooksURL = directory.appendingPathComponent(CursorHooksFile.fileName)
        let mcpOriginal = try read(mcpURL)
        let hooksOriginal = try read(hooksURL)
        let server = try merge(mcpURL) { try CursorMcpFile.remove(from: mcpOriginal) }
        let hooks = try merge(hooksURL) { try CursorHooksFile.remove(from: hooksOriginal) }

        var lines: [String] = []
        var notes: [String] = []
        switch server.outcome {
        case let .removed(existing):
            lines.append("mcp: removed \(CursorMcpFile.serverName) — \(existing)")
        case let .foreign(existing):
            notes.append("mcp: not ours, left alone — a server named \(CursorMcpFile.serverName) in \(mcpURL.path) runs something else (\(existing))")
        case .registered, .replaced, .unchanged:
            break
        }
        lines += hooks.removed.map { "hooks: removed \($0)" }

        var outcome = Outcome(lines: lines, notes: notes, written: [])
        try outcome.write(mcpURL, server.data, original: mcpOriginal, if: server.changed)
        try outcome.write(hooksURL, hooks.data, original: hooksOriginal, if: hooks.changed)
        return outcome
    }

    /// The bytes at `url`, `nil` when nothing is there; a file that cannot be read, or a link that leads nowhere, is refused, since reading it as empty would replace it.
    ///
    /// `agent` is the harness a refusal names and `flag` the option that points the install at another directory.
    public static func read(_ url: URL, agent: String = "cursor", flag: String = "--cursor-dir") throws -> Data? {
        do {
            _ = try SettingsFile.target(of: url)
        } catch let unresolved as SettingsFile.Unresolved {
            throw Refused(path: url.path, reason: "is \(unresolved.reason) — repair the link, or point \(flag) at another directory", agent: agent)
        }
        guard PathKind.of(url) != .absent else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw Refused(path: url.path, reason: "could not be read: \(error.localizedDescription)", agent: agent)
        }
    }

    /// Runs one file's merge, naming the file's path in a refusal of its shape.
    static func merge<Result>(_ url: URL, agent: String = "cursor", _ body: () throws -> Result) throws -> Result {
        do {
            return try body()
        } catch let unmergeable as CursorConfigJSON.Unmergeable {
            throw Refused(path: url.path, reason: "cannot be merged: \(unmergeable.description)", agent: agent)
        }
    }
}

public extension CursorInstall {
    /// What a run did: the registrations it made or took out, what it left alone, and the files it rewrote.
    struct Outcome: Equatable, Sendable {
        /// One line per registration made, repointed, found already in place, or taken out.
        public var lines: [String]
        /// What was left alone and why, and any backup that could not be kept.
        public var notes: [String]
        /// Each file rewritten, as an answer names it (with the file a symlink leads to).
        public var written: [String]
        /// What the run set out to do and could not, one line each; a command that says any exits non-zero.
        public var failures: [String] = []

        /// Whether any file was rewritten.
        public var changed: Bool {
            !written.isEmpty
        }

        mutating func write(_ url: URL, _ data: Data, original: Data?, if changed: Bool) throws {
            guard changed else { return }
            if let backupNote = try SettingsFile.rewrite(url, with: data, original: original) {
                notes.append(backupNote)
            }
            written.append(SettingsFile.named(url))
        }
    }

    /// A harness's file that is there and could not be read, leads nowhere, or is not a shape a merge can build on, so nothing was written.
    struct Refused: Error, CustomStringConvertible, Sendable {
        public let path: String
        public let reason: String
        /// The harness the file configures, as the refusal's first word.
        public var agent = "cursor"

        public var description: String {
            "\(agent): nothing written — \(path) \(reason)"
        }
    }
}
