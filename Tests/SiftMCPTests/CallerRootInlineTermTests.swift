//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// An inline `root:` term in a search query is a stated root for the hook, as it is for the server.
@Suite(.temporaryDirectories)
struct CallerRootInlineTermTests {
    @Test
    func aSearchCarryingAnInlineRootIsLeftAlone() throws {
        let root = try MCPTestRepo.make()

        let amended = CallerRoot.amendment(
            toolName: "mcp__sift__search",
            input: ["query": "name:Foo root:/abs/path"],
            cwd: root.path,
            serverDirectory: nil
        )

        #expect(amended == nil)
    }

    @Test
    func theSameSearchWithoutTheTermIsAmendedToTheCallersRoot() throws {
        let root = try MCPTestRepo.make()

        let amended = try #require(CallerRoot.amendment(
            toolName: "mcp__sift__search",
            input: ["query": "name:Foo"],
            cwd: root.path,
            serverDirectory: nil
        ))

        #expect((amended["root"] as? String).map(CanonicalPath.of) == CanonicalPath.of(root.path))
    }

    @Test
    func anEmptyInlineRootStatesNothingAndIsAmended() throws {
        let root = try MCPTestRepo.make()

        let amended = CallerRoot.amendment(
            toolName: "mcp__sift__search",
            input: ["query": "name:Foo root:"],
            cwd: root.path,
            serverDirectory: nil
        )

        #expect(amended != nil)
    }

    @Test
    func anArgumentAndAnInlineTermTogetherAreLeftAlone() throws {
        let root = try MCPTestRepo.make()

        let amended = CallerRoot.amendment(
            toolName: "mcp__sift__search",
            input: ["query": "name:Foo root:/abs/inline", "root": "/abs/argument"],
            cwd: root.path,
            serverDirectory: nil
        )

        #expect(amended == nil)
    }

    @Test
    func theArgumentBeatsTheInlineTerm() {
        let stated = CallerRoot.statedRoot(
            toolName: "mcp__sift__search",
            input: ["query": "name:Foo root:/abs/inline", "root": "/abs/argument"]
        )

        #expect(stated == "/abs/argument")
    }

    @Test
    func theInlineTermIsTheStatedRootWhenThereIsNoArgument() {
        #expect(CallerRoot.statedRoot(toolName: "mcp__sift__search", input: ["query": "name:Foo root:/abs/inline"]) == "/abs/inline")
    }

    @Test
    func aNonSearchToolIgnoresARootTermInAnyArgument() {
        let input: [String: Any] = ["target": "root:/abs/path", "symbol": "root:/abs/path", "query": "root:/abs/path"]

        #expect(CallerRoot.statedRoot(toolName: "mcp__sift__digest", input: input) == nil)
        #expect(CallerRoot.statedRoot(toolName: "mcp__sift__where", input: input) == nil)
        #expect(CallerRoot.statedRoot(toolName: "mcp__sift__strings", input: input) == nil)
    }
}
