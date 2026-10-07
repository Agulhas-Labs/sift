//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A removal's read-back compares server entries and nothing else: what `claude` rewrites around them on every run is not a change, and a change to another server entry during a user-scope removal is.
@Suite(.temporaryDirectories)
struct UninstallReadBackScopeTests {
    private typealias Fixture = UninstallCommandTests
    private typealias Local = UninstallLocalScopeTests

    /// `claude` counts its start, adds a project for the directory it ran in, and rewrites the file in its own key order and escaping; none of that is a server entry changing.
    @Test
    func claudesOwnRewriteAroundTheServersIsStillARemoval() throws {
        let installed = try Fixture.install()
        let neighbour = try Local.project()
        let ranIn = try Local.project()
        let other: [String: Any] = ["command": "/bin/other", "args": ["a/b"]]
        let before: [String: Any] = ["starts": 1, "mcpServers": ["sift": Self.ours], "projects": [neighbour: ["mcpServers": ["other": other]]]]
        let escaped = { (path: String) in path.replacingOccurrences(of: "/", with: "\\/") }
        let after = #"{"projects":{""# + escaped(ranIn) + #"":{"mcpServers":{}},""# + escaped(neighbour)
            + #"":{"mcpServers":{"other":{"args":["a\/b"],"command":"\/bin\/other"}}}},"mcpServers":{},"starts":2}"#
        let claude = try UninstallReadBackTests.fakeClaude(installed, before: before, after: Data(after.utf8))

        let (lines, status) = try Local.uninstall(installed, bin: claude.bin)

        #expect(status == 0, "\(lines)")
        #expect(lines.contains("mcp: removed the user-scope server — /bin/sift mcp"), "\(lines)")
    }

    /// Another project's server changed while the user-scope one went: the removal is not counted, and the entry is named to check.
    @Test
    func anotherEntryChangingDuringAUserRemovalIsCountedAsNotRemoved() throws {
        let installed = try Fixture.install()
        let neighbour = try Local.project()
        let before: [String: Any] = ["mcpServers": ["sift": Self.ours], "projects": [neighbour: ["mcpServers": ["sift": ["command": "/bin/other", "args": []]]]]]
        let after: [String: Any] = ["mcpServers": [:], "projects": [neighbour: ["mcpServers": ["sift": ["command": "/bin/changed", "args": []]]]]]
        let claude = try UninstallReadBackTests.fakeClaude(installed, before: before, after: JSONSerialization.data(withJSONObject: after))

        let (lines, status) = try Local.uninstall(installed, bin: claude.bin)

        #expect(status == 1, "\(lines)")
        #expect(!lines.contains { $0.hasPrefix("mcp: removed the user-scope server") }, "\(lines)")
        let named = "mcp: not removed — while `claude mcp remove sift --scope user` ran, projects[\"\(neighbour)\"].mcpServers.sift changed in \(installed.claudeConfig.path) as well (the sift entry went too); claude may have removed the wrong entry, so check that entry there"
        #expect(lines.contains(named), "\(lines)")
    }
}

extension UninstallReadBackScopeTests {
    /// The user-scope server `install.sh` registers.
    static var ours: [String: Any] {
        ["type": "stdio", "command": "/bin/sift", "args": ["mcp"]]
    }
}
