//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the check that finds a blind agent before a session spends a hundred refusals discovering it — and, just as load-bearing, the two shapes it must never name.
@Suite(.temporaryDirectories)
struct AgentAllowlistTests {
    /// A definition with no `tools:` line inherits every tool the session has, and naming it would be a false accusation.
    @Test
    func anAbsentToolsLineInheritsEverythingAndIsNotADefect() throws {
        let tree = try Tree()
        defer { tree.cleanup() }
        try tree.userAgent("reviewer", frontmatter: ["name: reviewer", "model: opus"])

        let definition = try #require(AgentAllowlist.definition(named: "reviewer", root: tree.root.path, home: tree.home))

        #expect(definition.tools == nil)
        #expect(!definition.shutsTheIndexOut)
        #expect(AgentAllowlistReport.text(root: tree.root.path, home: tree.home) == nil)
    }

    /// So does `tools: "*"`, which is an allowlist that allows everything.
    @Test
    func aWildcardAllowlistIsNotADefect() throws {
        let tree = try Tree()
        defer { tree.cleanup() }
        try tree.userAgent("everything", frontmatter: ["name: everything", "tools: \"*\""])

        let definition = try #require(AgentAllowlist.definition(named: "everything", root: tree.root.path, home: tree.home))

        #expect(definition.missing.isEmpty)
        #expect(!definition.shutsTheIndexOut)
    }

    /// The defect, in the exact spelling it most often takes.
    ///
    /// `tools: Read, Grep, Glob, Bash` is not a list that happens to omit four things — an explicit allowlist drops every MCP server, so the context is given the guidance and holds nothing it names.
    @Test
    func anExplicitAllowlistWithoutTheIndexToolsIsNamed() throws {
        let tree = try Tree()
        defer { tree.cleanup() }
        try tree.repositoryAgent("catalogue-reviewer", frontmatter: ["name: catalogue-reviewer", "tools: Read, Grep, Glob, Bash"])

        let definition = try #require(AgentAllowlist.definition(named: "catalogue-reviewer", root: tree.root.path, home: tree.home))

        #expect(definition.tools == ["Read", "Grep", "Glob", "Bash"])
        #expect(definition.shutsTheIndexOut)
        #expect(definition.missing == IndexToolName.qualified)
    }

    /// And an allowlist that does name them is left alone, however it spells them.
    @Test
    func anAllowlistNamingTheIndexToolsIsNotADefect() throws {
        let tree = try Tree()
        defer { tree.cleanup() }
        let named = IndexToolName.qualified.joined(separator: ", ")
        try tree.userAgent("wired", frontmatter: ["name: wired", "tools: Read, Grep, \(named)"])
        try tree.userAgent("wildcarded", frontmatter: ["name: wildcarded", "tools: Read, mcp__sift__*"])

        for name in ["wired", "wildcarded"] {
            let definition = try #require(AgentAllowlist.definition(named: name, root: tree.root.path, home: tree.home))

            #expect(definition.missing.isEmpty, "\(name)")
        }

        #expect(AgentAllowlistReport.text(root: tree.root.path, home: tree.home) == nil)
    }

    /// A list written as an indented block sequence is the same list, and reading only the inline spelling would let the defect through in the shape that hides it.
    @Test
    func aBlockSequenceIsReadAsTheListItIs() throws {
        let tree = try Tree()
        defer { tree.cleanup() }
        try tree.userAgent("sequenced", frontmatter: ["name: sequenced", "tools:", "  - Read", "  - Grep", "model: haiku"])

        let definition = try #require(AgentAllowlist.definition(named: "sequenced", root: tree.root.path, home: tree.home))

        #expect(definition.tools == ["Read", "Grep"])
        #expect(definition.shutsTheIndexOut)
    }

    /// The report names every offender, the tools to add, and what it read — the last because "none found" and "nowhere looked" are otherwise the same sentence.
    @Test
    func theReportNamesTheOffendersTheRemedyAndWhatItRead() throws {
        let tree = try Tree()
        defer { tree.cleanup() }
        try tree.repositoryAgent("catalogue-reviewer", frontmatter: ["name: catalogue-reviewer", "tools: Read, Grep, Glob, Bash"])
        try tree.userAgent("fine", frontmatter: ["name: fine", "model: opus"])

        let text = try #require(AgentAllowlistReport.text(root: tree.root.path, home: tree.home))

        // The figure carries its arithmetic: one of the two definitions read.
        #expect(text.hasPrefix("agents: 1 of 2 definitions has a tools: allowlist without sift in it"))
        #expect(text.contains("catalogue-reviewer  .claude/agents/catalogue-reviewer.md"))
        #expect(text.contains("tools: Read, Grep, Glob, Bash"))
        #expect(text.contains(IndexToolName.qualified.joined(separator: ", ")))
        #expect(text.contains("searched .claude/agents and"))
        // Relative inside the repository, never absolute — the answer contract's unit of location.
        #expect(!text.contains(tree.root.path))
    }
}

private extension AgentAllowlistTests {
    /// A throwaway repository and home, so a test never reads whatever agent definitions this machine happens to hold.
    struct Tree {
        let root: URL
        let home: URL
        let cleanup: () -> Void

        init() throws {
            let base = try TemporaryDirectory.make("agents")
                .appendingPathComponent("agents", isDirectory: true)
            root = base.appendingPathComponent("repo", isDirectory: true)
            home = base.appendingPathComponent("home", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            cleanup = { try? FileManager.default.removeItem(at: base) }
        }

        func repositoryAgent(_ name: String, frontmatter: [String]) throws {
            try write(name, frontmatter: frontmatter, under: root)
        }

        func userAgent(_ name: String, frontmatter: [String]) throws {
            try write(name, frontmatter: frontmatter, under: home)
        }

        private func write(_ name: String, frontmatter: [String], under directory: URL) throws {
            let agents = directory.appendingPathComponent(".claude/agents", isDirectory: true)
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            let body = (["---"] + frontmatter + ["---", "", "You do the thing."]).joined(separator: "\n")
            try Data(body.utf8).write(to: agents.appendingPathComponent("\(name).md"))
        }
    }
}
