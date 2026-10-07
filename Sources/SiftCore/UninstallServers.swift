//
// Copyright © Agulhas Labs
//

import Foundation

/// The uninstall's MCP step: every server named `sift` that Claude Code will start — the user-scope one `install.sh` registers, a local-scope one per project, a project's `.mcp.json` — and which of them run this tool.
///
/// The user-scope server and each local-scope one are taken out through `claude mcp remove`, a local-scope one from its project's directory and only where that directory is there under the very path Claude Code keys it by, which a linked worktree's is not; any other registration of this tool, a repository's `.mcp.json` included, is named with how to remove it and counted as not removed, and a server of the same name that runs something else is named and left alone.
struct UninstallServers {
    /// The package the README and Guide tell a stranger to run through `npx`.
    static var npmPackage: String {
        "@agulhas-labs/sift"
    }

    /// What the step removed, one answer line each.
    var removed: [String] = []
    /// What it named and did not remove, and why.
    var notes: [String] = []
    /// How many of the registrations it names as this tool's were not removed.
    var failures = 0
    /// Each `.mcp.json` named as registering this tool, with where its note is in `notes` and the command it runs.
    private var ownProjectFiles: [String: (note: Int, command: String)] = [:]

    /// Takes out the user-scope and local-scope servers that run this tool, reading the config again after each so the answer says one went only if it did, and names every other `sift` server in the config and in the `.mcp.json` of each of `roots`.
    static func settle(_ locations: SiftUninstall.Locations, roots: [String], removeServer: (SiftUninstall.ServerScope) -> SiftUninstall.ServerRemoval) -> UninstallServers {
        var step = UninstallServers()
        let config = locations.claudeConfig
        let removal = SiftUninstall.serverRemovalCommand
        // An unreadable config would otherwise read as nothing registered, which is a claim nothing checked.
        if PathKind.of(config) != .absent, jsonObject(at: config) == nil {
            step.failures += 1
            step.notes.append("mcp: not checked — \(config.path) could not be read as a JSON object; if sift is registered there, run: \(removal)")
        }
        switch userServer(in: config) {
        case nil:
            break
        case let entry? where !entry.ours:
            step.notes.append("mcp: the user-scope server named sift runs \(entry.command), \(foreign) — left alone")
        case let entry?:
            step.removeUser(entry, config: config, removeServer: removeServer)
        }
        for (project, entry) in localServers(in: config) {
            if entry.ours {
                step.removeLocal(project, entry, config: config, removeServer: removeServer)
            } else {
                step.notes.append("mcp: the local-scope server named sift in \(project) runs \(entry.command), \(foreign) — left alone")
            }
        }
        // A `.mcp.json` that is there and cannot be read or parsed would otherwise read as naming no server, which is a claim nothing checked.
        for file in unreadableProjectFiles(in: roots) {
            step.failures += 1
            step.notes.append("mcp: not checked — \(file) could not be read as a JSON object; if it registers sift, remove that entry by hand")
        }
        for (file, entry) in projectServers(in: roots) {
            if entry.ours {
                step.failures += 1
                step.ownProjectFiles[file] = (step.notes.count, entry.command)
                step.notes.append(projectFileNote(file, command: entry.command, unrecorded: false))
            } else {
                step.notes.append("mcp: \(file) names a server sift that runs \(entry.command), \(foreign) — left alone")
            }
        }
        return step
    }

    /// Adds to the note on each named `.mcp.json` in one of `roots` that a later run will not find it, since the purge deleted the record naming its repository: one line per file, the one that says what to do.
    mutating func markUnrecorded(_ roots: [String]) {
        for root in roots {
            let file = Self.mcpJSON(in: root).path
            if let own = ownProjectFiles[file] {
                notes[own.note] = Self.projectFileNote(file, command: own.command, unrecorded: true)
            }
        }
    }

    /// The note on a repository's `.mcp.json` that registers this tool, which is never edited; `unrecorded` when no record left names its repository.
    private static func projectFileNote(_ file: String, command: String, unrecorded: Bool) -> String {
        let note = "mcp: not removed — \(file) registers sift (\(command)) for everyone who opens that repository; it is the repository's own file, so remove its sift entry by hand"
        return unrecorded ? note + ": the purge deleted the record naming its repository, so a later `sift uninstall` will not find it" : note
    }

    /// The `.mcp.json` of the repository at `root`.
    static func mcpJSON(in root: String) -> URL {
        URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(".mcp.json")
    }

    /// What a server of this name that runs something else is: not one this tool can tell is its own, which is all that was checked.
    private static var foreign: String {
        "not a registration sift recognises"
    }

    /// Takes this tool's user-scope server out through `claude mcp remove`, and reads every server entry back against how they stood just before, so it is reported removed only when it went and nothing else changed.
    private mutating func removeUser(_ entry: Entry, config: URL, removeServer: (SiftUninstall.ServerScope) -> SiftUninstall.ServerRemoval) {
        let removal = SiftUninstall.serverRemovalCommand
        guard let before = McpRegistrations(config: config) else {
            failures += 1
            notes.append("mcp: not removed — \(config.path) could not be read just before `\(removal)` would run, so it was not run; run it yourself")
            return
        }
        switch removeServer(.user) {
        case .removed:
            switch McpRegistrations.readBack(config, before: before, target: McpRegistrations.key(project: nil, name: "sift")) {
            case .removed:
                removed.append("mcp: removed the user-scope server — \(entry.command)")
            case .stillRegistered:
                failures += 1
                notes.append("mcp: not removed — `\(removal)` succeeded and the server is still registered (\(config.path))")
            case .unreadable:
                failures += 1
                notes.append("mcp: not removed — `\(removal)` succeeded and \(config.path) could not be read back, so whether the server went is not known")
            case let .othersChanged(others, gone):
                failures += 1
                notes.append(Self.othersChanged(others, targetGone: gone, command: "`\(removal)` ran", config: config))
            }
        case let .failed(reason):
            failures += 1
            notes.append("mcp: not removed — `\(removal)` failed: \(reason)")
        case .noClaude:
            failures += 1
            notes.append("mcp: not removed — `claude` is not on PATH; run: \(removal)")
        }
    }

    /// Takes this tool's local-scope server in `project` out by running `claude mcp remove` in that directory, only where it is a directory whose resolved path is `project` itself, is not inside a git repository rooted elsewhere and is not a linked worktree, so the entry Claude Code finds from there is the one read here; anything else is named with how to remove it by hand and counted, and so is a removal during which any other entry changed.
    private mutating func removeLocal(_ project: String, _ entry: Entry, config: URL, removeServer: (SiftUninstall.ServerScope) -> SiftUninstall.ServerRemoval) {
        let directory = URL(fileURLWithPath: project, isDirectory: true)
        let command = (["claude"] + SiftUninstall.ServerScope.local(directory).removalArguments).joined(separator: " ")
        let byHand = "remove projects[\"\(project)\"].mcpServers.sift from \(config.path) by hand"
        let resolved = BinaryRemoval.resolvedPath(project)
        guard project.hasPrefix("/"), PathKind.of(directory) == .directory, resolved == project else {
            failures += 1
            var isDirectory: ObjCBool = false
            let throughALink = project.hasPrefix("/") && FileManager.default.fileExists(atPath: project, isDirectory: &isDirectory) && isDirectory.boolValue
            let why = throughALink
                ?"that path resolves to \(resolved), so `\(command)` run there could reach another project's entry"
                : "\(project) is not a directory here, so `\(command)` cannot be run from it"
            notes.append("mcp: not removed — the local-scope server in \(project) runs \(entry.command); \(why): \(byHand)")
            return
        }
        // Claude Code keys a local-scope server anywhere in a linked worktree by the main repository, so this goes first, for the worktree's root and every directory under it; a submodule, whose two git directories are one, it keys by its own root.
        if let git = GitContext.directories(of: directory), git.own != git.common {
            failures += 1
            notes.append("mcp: not removed — the local-scope server in \(project) runs \(entry.command); \(project) is in a linked git worktree (its repository's shared git directory is \(CanonicalPath.of(git.common.path))), and Claude Code keys a worktree's local-scope server by the main repository, so `\(command)` run there would reach the main repository's entry: \(byHand)")
            return
        }
        // Claude Code keys a local-scope server by the git root of the directory it runs in, so from inside another repository's tree it would reach that root's entry.
        if let root = GitContext.discoverRoot(from: directory).map({ CanonicalPath.of($0.path) }), root != project {
            failures += 1
            notes.append("mcp: not removed — the local-scope server in \(project) runs \(entry.command); \(project) is inside the git repository at \(root), and claude keys a local-scope server by that root, so `\(command)` run there would reach \(root)'s entry: \(byHand)")
            return
        }
        guard let before = McpRegistrations(config: config) else {
            failures += 1
            notes.append("mcp: not removed — \(config.path) could not be read just before `\(command)` would run in \(project), so it was not run: \(byHand)")
            return
        }
        switch removeServer(.local(directory)) {
        case .removed:
            let target = McpRegistrations.key(project: project, name: "sift")
            switch McpRegistrations.readBack(config, before: before, target: target) {
            case .removed:
                removed.append("mcp: removed the local-scope server in \(project) — \(entry.command)")
            case .stillRegistered:
                failures += 1
                notes.append("mcp: not removed — `\(command)` run in \(project) succeeded and the server is still registered (\(config.path))")
            case .unreadable:
                failures += 1
                notes.append("mcp: not removed — `\(command)` run in \(project) succeeded and \(config.path) could not be read back, so whether the server went is not known")
            case let .othersChanged(others, gone):
                failures += 1
                notes.append(Self.othersChanged(others, targetGone: gone, command: "`\(command)` ran in \(project)", config: config))
            }
        case let .failed(reason):
            failures += 1
            notes.append("mcp: not removed — `\(command)` run in \(project) failed: \(reason)")
        case .noClaude:
            failures += 1
            notes.append("mcp: not removed — `claude` is not on PATH; from \(project) run: \(command)")
        }
    }

    /// The note for a removal during which entries other than its own changed: not counted as removed, since `claude` may have taken out the wrong one, with the entries to check.
    static func othersChanged(_ others: [String], targetGone: Bool, command: String, config: URL) -> String {
        let which = others.joined(separator: ", ")
        let target = targetGone ? "the sift entry went too" : "the sift entry is still there"
        return "mcp: not removed — while \(command), \(which) changed in \(config.path) as well (\(target)); claude may have removed the wrong entry, so check \(others.count == 1 ? "that entry" : "those entries") there"
    }

    /// The user-scope server named `sift` in Claude Code's config.
    static func userServer(in config: URL) -> Entry? {
        entry((jsonObject(at: config)?["mcpServers"] as? [String: Any])?["sift"])
    }

    /// Every project with a local-scope server named `sift`, in path order.
    static func localServers(in config: URL) -> [(project: String, entry: Entry)] {
        guard let projects = jsonObject(at: config)?["projects"] as? [String: Any] else { return [] }
        return projects.compactMap { path, value in
            let servers = (value as? [String: Any])?["mcpServers"] as? [String: Any]
            return entry(servers?["sift"]).map { (path, $0) }
        }
        .sorted { $0.project < $1.project }
    }

    /// Every `.mcp.json` in `roots` that names a server `sift`: read only, since the file is the repository's and is shared with everyone who clones it.
    static func projectServers(in roots: [String]) -> [(file: String, entry: Entry)] {
        roots.compactMap { root in
            let file = mcpJSON(in: root)
            return entry((jsonObject(at: file)?["mcpServers"] as? [String: Any])?["sift"]).map { (file.path, $0) }
        }
    }

    /// Every `.mcp.json` in `roots` that exists and cannot be read as a JSON object; a missing one is not among them.
    static func unreadableProjectFiles(in roots: [String]) -> [String] {
        roots.compactMap { root in
            let file = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(".mcp.json")
            return PathKind.of(file) != .absent && jsonObject(at: file) == nil ? file.path : nil
        }
    }

    /// A server entry, as the command it runs and whether that is a registration this tool's own docs make.
    static func entry(_ value: Any?) -> Entry? {
        guard let value = value as? [String: Any] else { return nil }
        let command = value["command"] as? String ?? ""
        let arguments = value["args"] as? [String] ?? []
        return Entry(command: ([command] + arguments).joined(separator: " "), ours: recognises(command: command, arguments: arguments))
    }

    /// Whether `command` run with `arguments` is this tool's MCP server as `install.sh` or the README registers it: an executable named `sift` run with `mcp` alone, or `npx` running this package's `mcp`.
    ///
    /// Anything else — a path that merely contains the name, another package whose name starts with this one's, other arguments — is someone else's.
    static func recognises(command: String, arguments: [String]) -> Bool {
        let name = URL(fileURLWithPath: command).lastPathComponent
        if name == SiftPaths.binaryName, arguments == ["mcp"] {
            return true
        }
        if name == "npx", npxRunsServer(arguments) {
            return true
        }
        return false
    }

    /// `npx` arguments that run this package's `mcp` and nothing else: `-y` or `--yes` any number of times, the package (optionally at a version), then `mcp`.
    private static func npxRunsServer(_ arguments: [String]) -> Bool {
        let rest = arguments.drop { $0 == "-y" || $0 == "--yes" }
        guard rest.count == 2, rest.last == "mcp", let package = rest.first else { return false }
        return package == npmPackage || package.hasPrefix(npmPackage + "@")
    }

    static func jsonObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

extension UninstallServers {
    /// One server entry named `sift`: the command it runs, spelled as a person would type it, and whether it is this tool's.
    struct Entry: Equatable {
        let command: String
        let ours: Bool
    }
}
