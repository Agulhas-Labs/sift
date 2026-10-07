//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// The tools are marked to load up front exactly where the session-start primer speaks, and left deferred to their names everywhere else.
@Suite(.temporaryDirectories)
struct AlwaysLoadWhereSwiftTests {
    @Test
    func aSwiftRepositoryMarksEveryTool() throws {
        let repo = try MCPTestRepo.make()

        #expect(Self.marked(sessionIn: repo, knownRoots: []) == Self.toolCount)
    }

    @Test
    func aRepositoryWithNoSwiftUnderNoRootMarksNone() throws {
        let repo = try TemporaryDirectory.make("no-swift")
        // A `.git` entry is all the primer reads to call a directory a repository.
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "# Notes\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        #expect(Self.marked(sessionIn: repo, knownRoots: []) == 0)
    }

    @Test
    func aFolderAboveAnIndexedRootMarksEveryTool() throws {
        let folder = try TemporaryDirectory.make("portfolio")
        let root = folder.appendingPathComponent("App")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        #expect(Self.marked(sessionIn: folder, knownRoots: [root.path]) == Self.toolCount)
    }

    @Test
    func aDirectoryInsideAnIndexedRootMarksEveryTool() throws {
        let root = try TemporaryDirectory.make("indexed")
        let inside = root.appendingPathComponent("Sources/Core")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)

        #expect(Self.marked(sessionIn: inside, knownRoots: [root.path]) == Self.toolCount)
    }

    @Test
    func aPlainDirectoryMarksNone() throws {
        let plain = try TemporaryDirectory.make("plain")

        #expect(Self.marked(sessionIn: plain, knownRoots: []) == 0)
    }

    @Test
    func aPlainDirectoryPointedAtASwiftRepositoryByRootMarksEveryTool() throws {
        let plain = try TemporaryDirectory.make("plain")
        let repo = try MCPTestRepo.make()

        #expect(MCPToolCatalog.loadsUpFront(sessionIn: plain.path, knownRoots: []) == false)
        #expect(MCPToolCatalog.loadsUpFront(sessionIn: plain.path, root: repo.path, knownRoots: []))
    }

    @Test
    func aPlainDirectoryPointedAtAPlainRootMarksNone() throws {
        let plain = try TemporaryDirectory.make("plain")
        let other = try TemporaryDirectory.make("other")

        #expect(!MCPToolCatalog.loadsUpFront(sessionIn: plain.path, root: other.path, knownRoots: []))
    }
}

private extension AlwaysLoadWhereSwiftTests {
    static var toolCount: Int {
        MCPToolCatalog.tools(loadUpFront: false).count
    }

    /// How many tools a server started in `directory` would mark to load with the tool list.
    static func marked(sessionIn directory: URL, knownRoots: [String]) -> Int {
        let loadUpFront = MCPToolCatalog.loadsUpFront(sessionIn: directory.path, knownRoots: knownRoots)
        return MCPToolCatalog.tools(loadUpFront: loadUpFront).count { tool in
            (tool["_meta"] as? [String: Any])?[MCPToolCatalog.alwaysLoadKey] as? Bool == true
        }
    }
}
