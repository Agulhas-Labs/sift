//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Names the agent definitions that would spawn a context this server's tools cannot reach — before a session spends a hundred refusals discovering it.
///
/// The failure this exists to catch leaves no trace anyone reads. A context with an explicit `tools:` allowlist receives the guidance, takes the refusals, and correctly re-runs each refused command as the escape hatch prescribes; the session finishes, and the only record is a share that is lower than it looks and a `sift audit` row it takes a person to interpret. One such file can cost hundreds of refusals across many sessions. Reading it off the definitions takes one directory listing and answers before any of that.
///
/// Printed by `status` — the doctor, re-read every time something looks wrong — and by `install-hook`, which is the moment the tools are wired up and the moment the allowlists that exist today can be named. Neither is a config framework: this reads two directories of frontmatter and prints what it found, or nothing.
public struct AgentAllowlistReport {
    /// What to print about the agent definitions in scope, or `nil` when none of them shuts this server out.
    public static func text(
        root: String?,
        home: URL = SiftPaths.userHome()
    ) -> String? {
        let all = AgentAllowlist.definitions(root: root, home: home)
        let blind = all.filter(\.shutsTheIndexOut)
        guard !blind.isEmpty else { return nil }

        let searched = AgentAllowlist.directories(root: root, home: home)
            .map { display($0.path, root: root, home: home) }
            .joined(separator: " and ")
        let width = blind.map(\.name.count).max() ?? 0
        // The noun agrees with how many were read and the verb with how many are named, because "1 of 1
        // definitions name" is the shape of sentence that makes a reader doubt the number in front of it.
        var lines = [
            "agents: \(blind.count) of \(all.count) definition\(all.count == 1 ? "" : "s") "
                + "\(blind.count == 1 ? "has" : "have") a tools: allowlist without sift in it",
        ]
        for agent in blind {
            lines.append("  \(agent.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(display(agent.path.path, root: root, home: home))")
            lines.append("  \(String(repeating: " ", count: width))  tools: \((agent.tools ?? []).joined(separator: ", "))")
        }
        lines.append("  an explicit tools: list drops every MCP server, so a context spawned from one of these is")
        lines.append("  given this tool's guidance and holds nothing it names. Add these four to the line — or take")
        lines.append("  the line out, since an agent that names no tools inherits them all:")
        lines.append("      \(IndexToolName.qualified.joined(separator: ", "))")
        // What was searched, because "none found" and "nowhere looked" are the same sentence otherwise.
        lines.append("  (searched \(searched); a definition with no tools: line at all is not counted)")
        return lines.joined(separator: "\n")
    }

    /// A path as an answer may carry it: repository-relative inside the repo, and `~` for the user's own.
    static func display(_ path: String, root: String?, home: URL) -> String {
        if let root, !root.isEmpty, let relative = under(path, root), !relative.isEmpty {
            return relative
        }
        guard let relative = under(path, home.path) else { return CanonicalPath.of(path) }
        return relative.isEmpty ? "~" : "~/" + relative
    }

    /// The part of `path` below `base`, or `nil` when it is not below it.
    ///
    /// Tried under both spellings, and canonicalised at the moment of comparing rather than on the way in. Canonicalising can only resolve a path that exists — `/var/folders/…` becomes `/private/var/folders/…` for a directory that is there and stays as written for one that is not — so a repository root and an agents directory inside it that has never been created come back spelled two different ways, and comparing either spelling alone prints an absolute path where a relative one was the whole point.
    private static func under(_ path: String, _ base: String) -> String? {
        let spellings = [
            (CanonicalPath.of(path), CanonicalPath.of(base)),
            (URL(fileURLWithPath: path).standardizedFileURL.path, URL(fileURLWithPath: base).standardizedFileURL.path),
        ]
        for (candidate, prefix) in spellings {
            if candidate == prefix {
                return ""
            }
            if candidate.hasPrefix(prefix + "/") {
                return String(candidate.dropFirst(prefix.count + 1))
            }
        }
        return nil
    }
}
