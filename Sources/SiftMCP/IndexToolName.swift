//
// Copyright © Agulhas Labs
//

/// The names this server's tools go by outside this process — in a transcript, in a hook payload, in a `PreToolUse` matcher.
///
/// One place, because the readers are as far apart as this package gets and every one of them has to agree: the transcript scanner deciding whether a recorded call was an index call, and the `PreToolUse` hook deciding whether the call in front of it is this context taking the advice. A name known to one of those and not the others is not a disagreement anyone sees — it is a rule that silently does not apply.
public struct IndexToolName {
    /// The name this server is registered under, which is how the harness reports on it — a server that failed to start, say — as distinct from the tools it serves.
    public static var server: String {
        "sift"
    }

    /// The prefix this server's calls appear under now: the harness's spelling of a tool from the server above.
    public static var prefix: String {
        "mcp__\(server)__"
    }

    /// The tools as anything outside this process has to spell them — an agent's `tools:` allowlist, a settings file.
    ///
    /// Built from the catalog the server actually advertises rather than written out beside it, so a tool added there cannot leave a check asking after a list that is no longer the list.
    public static var qualified: [String] {
        MCPToolCatalog.tools(loadUpFront: false).compactMap { $0["name"] as? String }.map { prefix + $0 }
    }

    /// The tool named by an MCP call of this server's, or `nil` for anyone else's.
    public static func tool(named name: String) -> String? {
        guard name.hasPrefix(prefix) else { return nil }
        return String(name.dropFirst(prefix.count))
    }

    /// The tool named by a Cursor MCP call of this server's, or `nil` for anyone else's and wherever that cannot be told.
    ///
    /// Cursor spells an MCP call `MCP:<tool>` with no server in it, so another server's `digest` reads the same, and the arguments decide: every one a name this server's tool takes, its required ones present as text, and a `digest` naming a target.
    public static func tool(namedByCursor name: String, input: [String: Any]) -> String? {
        guard name.hasPrefix(cursorPrefix) else { return nil }
        let tool = String(name.dropFirst(cursorPrefix.count))
        guard let schema = MCPToolCatalog.tools(loadUpFront: false).first(where: { $0["name"] as? String == tool })?["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any],
              Set(input.keys).isSubset(of: properties.keys),
              (schema["required"] as? [String] ?? []).allSatisfy({ input[$0] is String })
        else {
            return nil
        }
        guard tool == "digest" else { return tool }
        return input["target"] is String || input["targets"] is [String] ? tool : nil
    }

    private static var cursorPrefix: String {
        "MCP:"
    }
}
