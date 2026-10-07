//
// Copyright © Agulhas Labs
//

import SiftCore

/// The four exposed tools with their trigger-phrased descriptions — these are load-bearing (Docs/Design.md §4): a tool the model never invokes is worth nothing.
public struct MCPToolCatalog {
    /// Claude Code's key for a tool that loads with the tool list instead of behind a `ToolSearch`.
    static var alwaysLoadKey: String {
        "anthropic/alwaysLoad"
    }

    /// The tools as `tools/list` serves them, each marked to load up front when `loadUpFront` is set.
    ///
    /// Claude Code defers MCP tools by default: the model sees a name and nothing else until it spends a `ToolSearch` turn loading the schema, so a deferred `digest` is one step behind a `Read` sitting in the list ready to call — and the descriptions below, written as trigger conditions, go unread. Marked, the four cost their ~1k tokens of schema in every session, which is the price the design set for them (Docs/Design.md §4). Unmarked, they cost a name each.
    static func tools(loadUpFront: Bool) -> [[String: Any]] {
        guard loadUpFront else { return definitions }
        return definitions.map { $0.merging(["_meta": [alwaysLoadKey: true]]) { current, _ in current } }
    }

    /// Whether a server started in `directory` marks its tools to load up front: exactly where the session-start primer speaks.
    ///
    /// Inside an indexed root, above indexed roots (a portfolio session, whose every query names a root), or in a repository with Swift sources. Anywhere else the ~1k tokens of schema buy nothing, so the tools stay deferred to their names and a registration at user scope costs a session without Swift nothing.
    public static func loadsUpFront(sessionIn directory: String, knownRoots: [String]) -> Bool {
        SessionPrimer.context(at: directory, knownRoots: knownRoots) != .none
    }

    /// Whether a server marks its tools to load up front when it starts in `directory` and is pointed at `root`.
    ///
    /// Either one qualifying is enough, under the same predicate as the single-directory overload: a session in a plain directory that names a Swift repository with `--root` is about to serve that repository.
    public static func loadsUpFront(sessionIn directory: String, root: String, knownRoots: [String]) -> Bool {
        loadsUpFront(sessionIn: directory, knownRoots: knownRoots) || loadsUpFront(sessionIn: root, knownRoots: knownRoots)
    }

    /// The name of every tool the server lists, in the order it lists them.
    public static var toolNames: [String] {
        definitions.compactMap { $0["name"] as? String }
    }

    private static var definitions: [[String: Any]] {
        [
            [
                "name": "digest",
                "description": "Call this BEFORE opening a Swift file, by Read or in a shell: its declarations with each member's line range, for a ranged Read. Type.member returns that member's source.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "target": ["type": "string", "description": "Type, Type.member, file, File.swift:12-40, module, .md path, or . (repo)."],
                        "targets": ["type": "array", "items": ["type": "string"], "description": "Several at once."],
                        "root": ["type": "string", "description": "Repository root."],
                        "all": ["type": "boolean", "description": "Include private symbols."],
                        "signaturesOnly": ["type": "boolean", "description": "Drop doc summaries and attributes."],
                        "offset": ["type": "integer", "description": "From a truncated: marker."],
                        "at": ["type": "string", "description": "Answer as of a commit."],
                    ],
                ],
            ],
            [
                "name": "where",
                "description": "Call this instead of grepping for a Swift symbol's definition, callers, uses, conformers or overrides: resolved file:line ranges.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "symbol": ["type": "string", "description": "Name or Type.member."],
                        "root": ["type": "string", "description": "Repository root."],
                        "refs": ["type": "boolean", "description": "Every reference site (code only; grep comments and strings)."],
                        "offset": ["type": "integer", "description": "From a truncated: marker."],
                        "at": ["type": "string", "description": "Answer as of a commit."],
                    ],
                    "required": ["symbol"],
                ],
            ],
            [
                "name": "search",
                "description": "Call this instead of grepping for Swift code by shape, across nesting and line breaks.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "field:value terms, ANDed, ! negates. Fields: kind attr name calls uses inherits modifier effect sig imports path owner has (closure/await/try/forceUnwrap/forceTry/forceCast/optionalChain). owner: enclosing type. Any field takes a|b; name/path/sig take /regex/. E.g. kind:func attr:Test calls:Task !has:await"],
                        "root": ["type": "string", "description": "Repository root."],
                        "offset": ["type": "integer", "description": "From a truncated: marker."],
                        "count": ["type": "boolean", "description": "Totals only."],
                    ],
                    "required": ["query"],
                ],
            ],
            [
                "name": "strings",
                "description": "Call this to trace UI text to its localization key or Swift literal, or a key to its text.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Text or key."],
                        "root": ["type": "string", "description": "Repository root."],
                    ],
                    "required": ["query"],
                ],
            ],
        ]
    }
}
