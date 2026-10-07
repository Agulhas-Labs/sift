//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A removal is read back against every server entry in `.claude.json`, so a `claude` that took out another project's entry, or any other, is never reported as the one asked for; and a project `claude` would not find by its own key is never run in.
@Suite(.temporaryDirectories)
struct UninstallReadBackTests {
    private typealias Fixture = UninstallCommandTests
    private typealias Local = UninstallLocalScopeTests

    /// Another project's entry went with the one asked for: that is what a `claude` keyed to the wrong project would do, so nothing is reported removed.
    @Test
    func anotherEntryChangingDuringALocalRemovalIsCountedAsNotRemoved() throws {
        let installed = try Fixture.install()
        let project = try Local.project()
        let neighbour = try Local.project()
        let foreign: [String: Any] = ["command": "/bin/other", "args": []]
        let before: [String: Any] = ["mcpServers": [:], "projects": [project: ["mcpServers": ["sift": Local.registration]], neighbour: ["mcpServers": ["sift": foreign]]]]
        let after: [String: Any] = ["mcpServers": [:], "projects": [project: ["mcpServers": [:]], neighbour: ["mcpServers": [:]]]]
        let claude = try Self.fakeClaude(installed, before: before, after: JSONSerialization.data(withJSONObject: after))

        let (lines, status) = try Local.uninstall(installed, bin: claude.bin)

        #expect(status == 1, "\(lines)")
        #expect(!lines.contains { $0.hasPrefix("mcp: removed the local-scope server") }, "\(lines)")
        let named = "mcp: not removed — while `claude mcp remove sift --scope local` ran in \(project), projects[\"\(neighbour)\"].mcpServers.sift changed in \(installed.claudeConfig.path) as well (the sift entry went too); claude may have removed the wrong entry, so check that entry there"
        #expect(lines.contains(named), "\(lines)")
    }

    /// A project key inside a git repository rooted elsewhere is where `claude` would reach the root's entry, so it never runs there.
    @Test
    func aProjectInsideAnotherRepositoryIsNamedAndNeverRunIn() throws {
        let installed = try Fixture.install()
        let repository = try Local.project()
        try RunWithoutCommandTests.git(["init", "-q"], in: URL(fileURLWithPath: repository))
        let project = repository + "/app"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        let before: [String: Any] = ["mcpServers": [:], "projects": [project: ["mcpServers": ["sift": Local.registration]]]]
        let claude = try Self.fakeClaude(installed, before: before, after: JSONSerialization.data(withJSONObject: ["mcpServers": [:]]))

        let (lines, status) = try Local.uninstall(installed, bin: claude.bin)

        #expect(status == 1, "\(lines)")
        #expect(!FileManager.default.fileExists(atPath: claude.log.path))
        let named = "mcp: not removed — the local-scope server in \(project) runs npx --yes @agulhas-labs/sift mcp; \(project) is inside the git repository at \(repository), and claude keys a local-scope server by that root, so `claude mcp remove sift --scope local` run there would reach \(repository)'s entry: remove projects[\"\(project)\"].mcpServers.sift from \(installed.claudeConfig.path) by hand"
        #expect(lines.contains(named), "\(lines)")
    }

    /// A config that cannot be parsed after the user-scope removal holds no server anyone read, so the removal is not known to have happened.
    @Test
    func aUserScopeRemovalThatLeavesAnUnreadableConfigIsNotCountedAsRemoved() throws {
        let installed = try Fixture.install()
        let before: [String: Any] = ["mcpServers": ["sift": ["type": "stdio", "command": "/bin/sift", "args": ["mcp"]]]]
        let claude = try Self.fakeClaude(installed, before: before, after: Data("{ not json".utf8))

        let (lines, status) = try Local.uninstall(installed, bin: claude.bin)

        #expect(status == 1, "\(lines)")
        #expect(!lines.contains { $0.hasPrefix("mcp: removed the user-scope server") }, "\(lines)")
        let unknown = "mcp: not removed — `claude mcp remove sift --scope user` succeeded and \(installed.claudeConfig.path) could not be read back, so whether the server went is not known"
        #expect(lines.contains(unknown), "\(lines)")
    }
}

extension UninstallReadBackTests {
    /// Writes `before` as the config and a stand-in `claude` that logs its arguments, working directory and HOME, then replaces the config with `after` byte for byte.
    static func fakeClaude(_ installed: UninstallCommandTests.Installed, before: [String: Any], after: Data) throws -> (bin: URL, log: URL) {
        let scratch = try TemporaryDirectory.make("uninstall-read-back")
        try JSONSerialization.data(withJSONObject: before).write(to: installed.claudeConfig)
        let replacement = scratch.appendingPathComponent("after.json")
        try after.write(to: replacement)
        let log = scratch.appendingPathComponent("claude.log")
        let bin = scratch.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" "$(pwd -P)" "$HOME" >> '\(log.path)'
        /bin/cp '\(replacement.path)' '\(installed.claudeConfig.path)'
        """
        let claude = bin.appendingPathComponent("claude")
        try (script + "\n").write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        return (bin, log)
    }
}
