//
// Copyright © Agulhas Labs
//

import Foundation

/// The server named `sift` in Codex's `config.toml`, read and changed only through `codex mcp`, which owns that file.
///
/// Ownership is judged as in Cursor's `mcp.json` (``CursorMcpFile/isOurs(_:)``): a `sift` binary at any path, run with `mcp`. `codex mcp add` replaces a server of the same name without a word, so what is there is always asked for first.
public struct CodexMcpServer {
    /// The arguments to `codex` that show the server named `sift`, as JSON.
    public static var getArguments: [String] {
        ["mcp", "get", CursorMcpFile.serverName, "--json"]
    }

    /// The arguments to `codex` that register `binary` as the server named `sift`.
    public static func addArguments(binary: String) -> [String] {
        ["mcp", "add", CursorMcpFile.serverName, "--", binary] + CursorMcpFile.arguments
    }

    /// The arguments to `codex` that take the server named `sift` out.
    public static var removeArguments: [String] {
        ["mcp", "remove", CursorMcpFile.serverName]
    }

    /// What `codex mcp get` says is registered under the name in `home`; a failure that is not "no such server" is refused, since reading it as absent would let `add` replace whatever is there.
    public static func find(runner: any CodexMcpRunner, home: URL) throws -> Found {
        guard let output = try runner.run(getArguments, home: home) else { return .noCodex }
        guard output.succeeded else {
            if (output.standardError + output.standardOutput).contains("No MCP server named") {
                return .absent
            }
            throw refusal(home, "could not be read by `codex \(getArguments.joined(separator: " "))`: \(failureReason(of: output))")
        }
        guard let shown = try? JSONSerialization.jsonObject(with: Data(output.standardOutput.utf8)) as? [String: Any],
              let transport = shown["transport"] as? [String: Any]
        else {
            throw refusal(home, "could not be read: `codex \(getArguments.joined(separator: " "))` printed no server transport")
        }
        let command = transport["command"] as? String ?? transport["url"] as? String ?? "?"
        let described = ([command] + (transport["args"] as? [String] ?? [])).joined(separator: " ")
        return CursorMcpFile.isOurs(transport) ? .ours(command) : .foreign(described)
    }

    /// What a failed `codex` or `claude` run said, its error before its output: the first line, then each line of a `Caused by:` chain after it.
    ///
    /// `codex` puts the reason under its first line (`Error: failed to load configuration`, then `Caused by:` and a revoked login), so the first line alone names a failure without its cause.
    static func failureReason(of output: SimulatorAccessibility.Output) -> String {
        guard let said = [output.standardError, output.standardOutput].first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return "no output"
        }
        let lines = said.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var reason = [lines[0]]
        if let causes = lines.firstIndex(of: "Caused by:") {
            reason += lines[(causes + 1)...]
        }
        return reason.joined(separator: ": ")
    }

    private static func refusal(_ home: URL, _ reason: String) -> CursorInstall.Refused {
        CursorInstall.Refused(path: home.appendingPathComponent("config.toml").path, reason: reason, agent: "codex")
    }
}

public extension CodexMcpServer {
    /// What is registered under the name `sift`.
    enum Found: Equatable {
        /// There is no `codex` on PATH to ask.
        case noCodex
        /// Nothing is.
        case absent
        /// This tool's server, running the binary at this path.
        case ours(String)
        /// Something else, spelled as a person would type it.
        case foreign(String)
    }
}
