//
// Copyright © Agulhas Labs
//

import Foundation

/// The MCP server half of the Claude Code install: registers the binary as the user-scope server named `sift` through `claude mcp`, deciding what is there by reading `.claude.json` with the recognition `sift uninstall` uses, never by parsing `claude mcp get`.
///
/// A server of that name that runs something else is left alone and named; one of this tool's at another path is removed and registered again; without a `claude` to run, the answer is the command to paste.
public struct ClaudeMcpInstall {
    /// The arguments to `claude` that register `binary` as the user-scope server named `sift`, exactly.
    public static func addArguments(binary: String) -> [String] {
        ["mcp", "add", "--transport", "stdio", "--scope", "user", "sift", "--", binary, "mcp"]
    }

    /// The registration as a person pastes it.
    public static func manual(binary: String) -> String {
        (["claude"] + addArguments(binary: binary).map(ShellWord.quoted)).joined(separator: " ")
    }

    /// Reads what the user-scope server named `sift` in `config` is, for `binary`; writes nothing and runs nothing.
    public static func plan(config: URL, binary: String) -> Plan {
        if let reason = unreadable(config) {
            return .unreadable(reason)
        }
        guard let entry = UninstallServers.userServer(in: config) else { return .absent }
        guard entry.ours else { return .foreign(entry.command) }
        return entry.command == registered(binary) ? .current : .stale(entry.command)
    }

    /// Registers `binary` in `config` through `runner`, unless it is already there or a foreign server holds the name, and reads the config back to confirm it.
    public static func install(config: URL, binary: String, runner: any ClaudeMcpRunner) throws -> CursorInstall.Outcome {
        var outcome = CursorInstall.Outcome(lines: [], notes: [], written: [])
        let plan = plan(config: config, binary: binary)
        switch plan {
        case let .unreadable(reason):
            outcome.failures.append("mcp: not registered — \(config.path) \(reason); repair it, then run: \(manual(binary: binary))")
            return outcome
        case .current:
            outcome.lines.append("mcp: already registered — \(registered(binary))")
            return outcome
        case let .foreign(existing):
            outcome.lines.append("mcp: left alone — a server named sift runs something else (\(existing))")
            return outcome
        case let .stale(previous):
            guard let removed = try runner.run(SiftUninstall.ServerScope.user.removalArguments) else {
                outcome.lines.append("mcp: `claude` is not on PATH — replace the stale registration (\(previous)) with: \(SiftUninstall.serverRemovalCommand); \(manual(binary: binary))")
                return outcome
            }
            guard removed.succeeded else {
                outcome.failures.append("mcp: not replaced — `\(SiftUninstall.serverRemovalCommand)` failed: \(CodexMcpServer.failureReason(of: removed)); run it, then: \(manual(binary: binary))")
                return outcome
            }
            outcome.lines.append("mcp: replaced stale registration (\(previous))")
        case .absent:
            break
        }
        guard let added = try runner.run(addArguments(binary: binary)) else {
            outcome.lines.append("mcp: `claude` is not on PATH — register the server with: \(manual(binary: binary))")
            return outcome
        }
        guard added.succeeded else {
            outcome.failures.append("mcp: not registered — `claude mcp add` failed: \(CodexMcpServer.failureReason(of: added)); run: \(manual(binary: binary))")
            return outcome
        }
        guard Self.plan(config: config, binary: binary) == .current else {
            outcome.failures.append("mcp: not registered — `claude mcp add` succeeded but \(config.path) does not name \(registered(binary)); run: \(manual(binary: binary))")
            return outcome
        }
        outcome.lines.append("mcp: registered sift — \(registered(binary))")
        outcome.written.append(config.path)
        return outcome
    }

    /// Why `config` is there and cannot be read as the JSON object Claude Code keeps, or `nil` where it can or is not there at all: read as absent, it would send `claude mcp add` at a file nothing checked.
    ///
    /// A file holding nothing but whitespace holds nothing to lose, so it reads as absent, as it did before anything was refused; everything else that is not a JSON object is refused.
    private static func unreadable(_ config: URL) -> String? {
        guard PathKind.of(config) != .absent else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: config)
        } catch {
            return "could not be read: \(error.localizedDescription)"
        }
        guard !data.allSatisfy([0x20, 0x09, 0x0A, 0x0D].contains) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) is [String: Any] ? nil : "could not be read as a JSON object"
    }

    /// The server as the config spells it once registered: the binary, then its one argument.
    private static func registered(_ binary: String) -> String {
        "\(binary) mcp"
    }
}

public extension ClaudeMcpInstall {
    /// What the user-scope server named `sift` is, as the config holds it.
    enum Plan: Equatable, Sendable {
        /// Nothing is registered under the name.
        case absent
        /// This tool's server, running this binary.
        case current
        /// This tool's server running another binary, spelled as the config holds it.
        case stale(String)
        /// Something else, spelled as the config holds it.
        case foreign(String)
        /// A config that is there and cannot be read as a JSON object, with why: nothing about the server is known, so nothing is run.
        case unreadable(String)
    }
}
