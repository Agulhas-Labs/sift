//
// Copyright © Agulhas Labs
//

import Foundation

/// Every MCP server registration in Claude Code's config, keyed by the path that names it in the file — `mcpServers.<name>` at user scope, `projects["<path>"].mcpServers.<name>` for a project's local scope — so a removal can be read back as having taken out its one entry and changed no other.
struct McpRegistrations: Equatable {
    /// Each registration's key, with its value as sorted-key JSON so two readings compare byte for byte.
    let entries: [String: Data]

    /// The registrations in `config`, or `nil` when it cannot be read as a JSON object.
    init?(config: URL) {
        guard let object = UninstallServers.jsonObject(at: config) else { return nil }
        var entries: [String: Data] = [:]
        for (name, value) in object["mcpServers"] as? [String: Any] ?? [:] {
            entries[Self.key(project: nil, name: name)] = Self.json(value)
        }
        for (project, settings) in object["projects"] as? [String: Any] ?? [:] {
            for (name, value) in (settings as? [String: Any])?["mcpServers"] as? [String: Any] ?? [:] {
                entries[Self.key(project: project, name: name)] = Self.json(value)
            }
        }
        self.entries = entries
    }

    /// The key of the server `name`: at user scope for a `nil` project, else in that project's local scope.
    static func key(project: String?, name: String) -> String {
        project.map { "projects[\"\($0)\"].mcpServers.\(name)" } ?? "mcpServers.\(name)"
    }

    /// What `config` holds now against `before`, for a removal of the entry at `target` alone.
    static func readBack(_ config: URL, before: McpRegistrations, target: String) -> ReadBack {
        guard let after = McpRegistrations(config: config) else { return .unreadable }
        let gone = after.entries[target] == nil
        let others = Set(before.entries.keys).union(after.entries.keys)
            .filter { $0 != target && before.entries[$0] != after.entries[$0] }
            .sorted()
        if !others.isEmpty {
            return .othersChanged(others, targetGone: gone)
        }
        return gone ? .removed : .stillRegistered
    }

    private static func json(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
    }
}

extension McpRegistrations {
    /// What reading the config back after a removal showed.
    enum ReadBack: Equatable {
        /// The target is gone and nothing else changed.
        case removed
        /// Nothing changed; the target is still there.
        case stillRegistered
        /// The config could not be read as a JSON object, so whether the target went is not known.
        case unreadable
        /// Entries other than the target changed while the removal ran, whichever way the target went.
        case othersChanged([String], targetGone: Bool)
    }
}
