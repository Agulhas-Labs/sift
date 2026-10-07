//
// Copyright © Agulhas Labs
//

import Foundation

/// The MCP server this tool registers in Cursor's `~/.cursor/mcp.json`, and the merge that adds it to or takes it out of that file.
///
/// The entry is `mcpServers.sift = {"command": <absolute binary path>, "args": ["mcp"]}`. The path is absolute because a GUI app does not inherit the shell's PATH, and it is not shell-quoted because the command and its arguments are separate fields. There is no `--root`: where Cursor launches the server is not known, so the `preToolUse` hook supplies each call's root. A server named `sift` is this tool's only when its command is an executable named `sift` and its arguments are exactly `mcp`; any other is reported and left alone.
public struct CursorMcpFile {
    /// The file's name inside the Cursor directory.
    public static var fileName: String {
        "mcp.json"
    }

    /// The server's name in `mcpServers`.
    public static var serverName: String {
        SiftPaths.binaryName
    }

    /// The arguments the server is registered with.
    public static var arguments: [String] {
        ["mcp"]
    }

    /// Whether a server entry is this tool's registration, at any path.
    public static func isOurs(_ value: Any?) -> Bool {
        guard let entry = value as? [String: Any], let command = entry["command"] as? String else { return false }
        return URL(fileURLWithPath: command).lastPathComponent == SiftPaths.binaryName && entry["args"] as? [String] == arguments
    }

    /// Registers the server in `data` (nil or empty meaning no file yet), repointing a registration of ours at another binary and leaving a foreign `sift` server alone.
    public static func apply(to data: Data?, binary: String) throws -> Change {
        var file = try CursorConfigJSON.parse(data, file: fileName)
        var servers = try CursorConfigJSON.object(file["mcpServers"], key: "mcpServers", file: fileName)
        let outcome: Outcome
        switch servers[serverName] {
        case nil:
            servers[serverName] = ["command": binary, "args": arguments]
            outcome = .registered
        case let value? where isOurs(value):
            guard var entry = value as? [String: Any], let previous = entry["command"] as? String, previous != binary else {
                return Change(data: data ?? Data(), outcome: .unchanged)
            }
            // Only the path moves: anything else in the entry, an `env` someone added, is theirs to keep.
            entry["command"] = binary
            servers[serverName] = entry
            outcome = .replaced(previous: "\(previous) mcp")
        case let value?:
            return Change(data: data ?? Data(), outcome: .foreign(describe(value)))
        }
        file["mcpServers"] = servers
        return try Change(data: CursorConfigJSON.encode(file), outcome: outcome)
    }

    /// Takes this tool's server out of `data`, dropping `mcpServers` when nothing is left in it; a foreign `sift` server stays.
    public static func remove(from data: Data?) throws -> Change {
        var file = try CursorConfigJSON.parse(data, file: fileName)
        var servers = try CursorConfigJSON.object(file["mcpServers"], key: "mcpServers", file: fileName)
        guard let value = servers[serverName] else {
            return Change(data: data ?? Data(), outcome: .unchanged)
        }
        guard isOurs(value) else {
            return Change(data: data ?? Data(), outcome: .foreign(describe(value)))
        }
        servers.removeValue(forKey: serverName)
        file["mcpServers"] = servers.isEmpty ? nil : servers
        return try Change(data: CursorConfigJSON.encode(file), outcome: .removed(describe(value)))
    }

    /// A server entry spelled as a person would type it: the command, then its arguments.
    private static func describe(_ value: Any) -> String {
        guard let entry = value as? [String: Any] else { return "not a server entry" }
        let command = entry["command"] as? String ?? entry["url"] as? String ?? "no command"
        let arguments = entry["args"] as? [String] ?? []
        return ([command] + arguments).joined(separator: " ")
    }
}

public extension CursorMcpFile {
    /// What a merge found and did.
    enum Outcome: Equatable, Sendable {
        /// The server was added.
        case registered
        /// Ours was there and named another binary, now repointed; the previous registration as typed.
        case replaced(previous: String)
        /// Ours was taken out; the registration as typed.
        case removed(String)
        /// Nothing to do: ours already registered at this binary, or on removal nothing named `sift`.
        case unchanged
        /// A server named `sift` of another shape, left alone; the registration as typed.
        case foreign(String)
    }

    /// What a merge did to the file.
    struct Change: Equatable, Sendable {
        /// The file as it should be written; the input unchanged when ``changed`` is false.
        public let data: Data
        public let outcome: Outcome

        /// Whether ``data`` differs from what was read.
        public var changed: Bool {
            switch outcome {
            case .registered, .replaced, .removed: true
            case .unchanged, .foreign: false
            }
        }
    }
}
