//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// What an agent definition's `tools:` frontmatter says about whether this server's tools reach the contexts it spawns.
///
/// A subagent's tool list is decided by a file, and one shape of that file makes every delivery this tool has — the path-scoped rule, the primer, the refusal at the miss — undeliverable at once. `tools: Read, Grep, Glob, Bash` is not a list that happens to omit four things: **an explicit allowlist drops every MCP server**, so the context receives all the guidance, takes all the refusals, and holds nothing any of them names. An agent reading exactly that line can take hundreds of refusals across many sessions before anything notices.
///
/// **Three shapes, and only one of them is the defect** — which is why this reads the frontmatter rather than grepping for a word. A `tools:` line that is absent entirely inherits every tool and is correct. `tools: "*"` is correct. An explicit list without this server's tools in it is the one that shuts the door, and it is the only one named.
///
/// Judged leniently wherever the reading is uncertain: a wildcard over this server's prefix, or the bare server name, counts as naming its tools. The cost of being wrong in that direction is a defect not reported; the cost of being wrong in the other is a file named as broken that is not, which is the failure a check nobody asked for cannot afford.
public struct AgentAllowlist: Sendable, Equatable {
    /// The agent's `name:`, or its file's stem when it declares none.
    public let name: String

    /// The file that defines it.
    public let path: URL

    /// The tools it names, or `nil` when it names none and so inherits them all.
    public let tools: [String]?

    public init(name: String, path: URL, tools: [String]?) {
        self.name = name
        self.path = path
        self.tools = tools
    }

    /// This server's tools that this definition's allowlist leaves out — empty for a definition that has no allowlist at all.
    public var missing: [String] {
        guard let tools else { return [] }
        return IndexToolName.qualified.filter { tool in
            !tools.contains { Self.admits($0, tool) }
        }
    }

    /// Whether a context spawned from this definition would hold none of this server's tools.
    public var shutsTheIndexOut: Bool {
        tools != nil && missing.count == IndexToolName.qualified.count
    }

    /// Whether `token`, as written in a `tools:` list, admits `tool`.
    private static func admits(_ token: String, _ tool: String) -> Bool {
        if token == "*" || token == tool {
            return true
        }
        // A trailing `*` — `mcp__sift__*` — and the bare server name are both read as "all of it".
        if token.hasSuffix("*"), tool.hasPrefix(String(token.dropLast())) {
            return true
        }
        return token == String(IndexToolName.prefix.dropLast(2))
    }
}

public extension AgentAllowlist {
    /// The directories an agent definition can be written in, this repository's first.
    ///
    /// Exactly two, and the answers that quote this say which two they looked in. Guessing at a plugin's layout would let "nothing defines this agent" mean "nothing defines it *where I looked*" without either half being stated, and that sentence is the load-bearing one in the diagnosis this feeds.
    static func directories(root: String?, home: URL = SiftPaths.userHome()) -> [URL] {
        let user = home.appendingPathComponent(".claude/agents", isDirectory: true)
        guard let root, !root.isEmpty else { return [user] }
        return [URL(fileURLWithPath: root).appendingPathComponent(".claude/agents", isDirectory: true), user]
    }

    /// Every agent definition in scope, in the order the directories are searched.
    ///
    /// Walked to the bottom rather than one level deep: an agents directory grouped into subfolders is ordinary, and a definition in one read as no definition at all would land in the diagnosis as "it is the harness's own: there is nothing here to edit", a remedy that sends someone looking for a file that is sitting right there.
    static func definitions(root: String?, home: URL = SiftPaths.userHome()) -> [AgentAllowlist] {
        directories(root: root, home: home).flatMap { directory in
            let entries = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )?.compactMap { $0 as? URL } ?? []
            return entries.filter { $0.pathExtension == "md" }.sorted { $0.path < $1.path }.compactMap(read)
        }
    }

    /// The definition of the agent called `name`, or `nil` when neither directory holds one.
    ///
    /// Matched on the declared `name:` first and the file stem second, because the two are conventionally the same and nothing requires them to be.
    static func definition(named name: String, root: String?, home: URL = SiftPaths.userHome()) -> AgentAllowlist? {
        let all = definitions(root: root, home: home)
        return all.first { $0.name == name } ?? all.first { $0.path.deletingPathExtension().lastPathComponent == name }
    }

    /// What `file` defines, or `nil` when it opens with no frontmatter block and so defines nothing.
    static func read(_ file: URL) -> AgentAllowlist? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return parse(text, at: file)
    }

    /// The frontmatter reader: enough YAML for two keys, and deliberately no more.
    ///
    /// A parser is the wrong instrument for a file this tool does not own and cannot validate. What is read is the two keys that decide the question — `name` and `tools` — from the leading `---` block only, in the three spellings a tool list is written in: inline `A, B`, inline `[A, B]`, and an indented block sequence. Anything else in the block is skipped rather than rejected, because a key this does not understand is not a reason to have no opinion about the two it does.
    static func parse(_ text: String, at file: URL) -> AgentAllowlist? {
        var lines = ArraySlice(text.split(separator: "\n", omittingEmptySubsequences: false))
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines = lines.dropFirst()

        var name: String?
        var tools: [String]?
        while let line = lines.first {
            lines = lines.dropFirst()
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                break
            }
            // A top-level key only: an indented line, or one opening a sequence item, belongs to the
            // value above it and is consumed there or skipped here.
            guard let first = line.first, !first.isWhitespace, first != "-", let colon = line.firstIndex(of: ":") else {
                continue
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch String(line[..<colon]) {
            case "name":
                name = unquoted(value)
            case "tools":
                let parsed = value.isEmpty ? sequence(&lines) : inlineList(value)
                // `tools:` with nothing under it is a null, which is no list at all; `tools: []` is an
                // empty one. Only the second is a claim about what is allowed, and only a claim is judged.
                tools = value.isEmpty && parsed.isEmpty ? nil : parsed
            default:
                continue
            }
        }
        return AgentAllowlist(
            name: name ?? file.deletingPathExtension().lastPathComponent,
            path: file,
            tools: tools
        )
    }

    /// A tool list written on the key's own line, bracketed or bare.
    private static func inlineList(_ value: String) -> [String] {
        var text = value
        if text.hasPrefix("["), text.hasSuffix("]") {
            text = String(text.dropFirst().dropLast())
        }
        return text.split(separator: ",")
            .map { unquoted($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    /// A tool list written as an indented block sequence beneath the key, consuming the lines it spans.
    private static func sequence(_ lines: inout ArraySlice<Substring>) -> [String] {
        var tools: [String] = []
        while let line = lines.first {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed == "-" || trimmed.hasPrefix("- ") else { break }
            lines = lines.dropFirst()
            let item = unquoted(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            if !item.isEmpty {
                tools.append(item)
            }
        }
        return tools
    }

    private static func unquoted(_ value: String) -> String {
        guard let first = value.first, first == "\"" || first == "'", value.count >= 2, value.last == first else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }
}
