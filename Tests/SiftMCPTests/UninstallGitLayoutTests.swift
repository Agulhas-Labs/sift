//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A local-scope removal runs only in a directory `claude` keys by that same path: a linked worktree it keys by the main repository, so it is named and never run in, and a submodule it keys by its own root, so it is removed there.
@Suite(.temporaryDirectories)
struct UninstallGitLayoutTests {
    private typealias Fixture = UninstallCommandTests
    private typealias Local = UninstallLocalScopeTests

    /// `claude` run in a linked worktree, at its root or below, reaches the main repository's entry, here another tool's, so nothing runs there and that entry survives.
    @Test
    func aLinkedWorktreeIsNamedAndNeverRunIn() throws {
        let installed = try Fixture.install()
        let scratch = try Local.project()
        let main = scratch + "/main"
        let worktree = scratch + "/wt"
        let nested = worktree + "/sub"
        try FileManager.default.createDirectory(atPath: main, withIntermediateDirectories: true)
        try Self.git(["init", "-q"], in: main)
        try Self.git(["commit", "-q", "--allow-empty", "-m", "start"], in: main)
        try Self.git(["worktree", "add", "-q", worktree], in: main)
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        let foreign: [String: Any] = ["command": "node", "args": ["other-sift.js"]]
        let ours: [String: Any] = ["mcpServers": ["sift": Local.registration]]
        let before: [String: Any] = ["mcpServers": [:], "projects": [main: ["mcpServers": ["sift": foreign]], worktree: ours, nested: ours]]
        let after: [String: Any] = ["mcpServers": [:], "projects": [main: ["mcpServers": [:]], worktree: ours, nested: ours]]
        let claude = try UninstallReadBackTests.fakeClaude(installed, before: before, after: JSONSerialization.data(withJSONObject: after))

        let (lines, status) = try Local.uninstall(installed, bin: claude.bin)

        #expect(status == 1, "\(lines)")
        #expect(!FileManager.default.fileExists(atPath: claude.log.path))
        for project in [worktree, nested] {
            let named = "mcp: not removed — the local-scope server in \(project) runs npx --yes @agulhas-labs/sift mcp; \(project) is in a linked git worktree (its repository's shared git directory is \(main)/.git), and Claude Code keys a worktree's local-scope server by the main repository, so `claude mcp remove sift --scope local` run there would reach the main repository's entry: remove projects[\"\(project)\"].mcpServers.sift from \(installed.claudeConfig.path) by hand"
            #expect(lines.contains(named), "\(lines)")
        }
        let projects = try #require(Fixture.object(at: installed.claudeConfig)["projects"] as? [String: Any])
        #expect(((projects[main] as? [String: Any])?["mcpServers"] as? [String: Any])?["sift"] != nil)
    }

    /// A submodule's own git directory is its shared one, and `claude` keys it by its own root, so its entry is removed from there.
    @Test
    func aSubmoduleIsRemovedFromItsOwnDirectory() throws {
        let installed = try Fixture.install()
        let scratch = try Local.project()
        let main = scratch + "/main"
        let other = scratch + "/other"
        for repository in [main, other] {
            try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
            try Self.git(["init", "-q"], in: repository)
            try Self.git(["commit", "-q", "--allow-empty", "-m", "start"], in: repository)
        }
        try Self.git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", other, "sm"], in: main)
        let submodule = main + "/sm"
        let claude = try Local.fakeClaude(installed, registering: [submodule], edits: true)

        let (lines, status) = try Local.uninstall(installed, bin: claude.bin)

        #expect(status == 0, "\(lines)")
        #expect(lines.contains("mcp: removed the local-scope server in \(submodule) — npx --yes @agulhas-labs/sift mcp"), "\(lines)")
        let log = try String(contentsOf: claude.log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(log == ["mcp remove sift --scope local", submodule, installed.home.path], "\(log)")
    }

    /// A project that is a repository's own root is where `claude` keys it, so the guards that refuse other layouts let it through.
    @Test
    func aRepositoryRootIsRemovedFromItsOwnDirectory() throws {
        let installed = try Fixture.install()
        let repository = try Local.project()
        try Self.git(["init", "-q"], in: repository)
        let claude = try Local.fakeClaude(installed, registering: [repository], edits: true)

        let (lines, status) = try Local.uninstall(installed, bin: claude.bin)

        #expect(status == 0, "\(lines)")
        #expect(lines.contains("mcp: removed the local-scope server in \(repository) — npx --yes @agulhas-labs/sift mcp"), "\(lines)")
        #expect(FileManager.default.fileExists(atPath: claude.log.path))
    }
}

extension UninstallGitLayoutTests {
    static func git(_ arguments: [String], in directory: String) throws {
        try RunWithoutCommandTests.git(arguments, in: URL(fileURLWithPath: directory, isDirectory: true))
    }
}
