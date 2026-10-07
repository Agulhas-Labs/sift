//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// Covers `flakes --root` over the worktrees of one repository: a failure recorded in a linked worktree and a pass in the checkout are one test's history.
///
/// Every worktree here is cut outside the checkout (`MCPTestRepo.worktree` places it in a temporary directory of its own), because one beneath the checkout is already in scope by path and would pass without the repository key.
@Suite(.temporaryDirectories)
struct RunFailureWorktreeScopeTests {
    private static let key = TreeContentHash.RunKey(tree: "aaaa", invocation: "all")

    private static func logFile() throws -> URL {
        try TemporaryDirectory.make("flakes-worktrees").appendingPathComponent("run.jsonl")
    }

    private static func record(_ failed: [String], in root: URL, to file: URL) {
        RunUsageLog(fileURL: file).record(
            logKey: "swift test",
            exitCode: failed.isEmpty ? 0 : 1,
            answer: RunUsageLog.Answer(failedTests: failed),
            repositoryRoot: root,
            milliseconds: 100,
            startedOn: key
        )
    }

    /// A line as one written before the log kept a repository key: a root and nothing to widen by.
    private static func olderLine(_ failed: [String], in root: URL) -> String {
        let object: [String: Any] = [
            "kind": "swift test", "exit": failed.isEmpty ? 0 : 1, "ms": 100, "ts": "2026-08-20T10:00:00Z",
            "root": root.path, "failed": failed, "failed_total": failed.count, "tree": key.tree, "invocation": key.invocation,
        ]
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data ?? Data(), encoding: .utf8) ?? ""
    }

    private static func append(_ line: String, to file: URL) throws {
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try (existing + line + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    @Test
    func aFailureInAWorktreeIsInItsCheckoutsHistory() throws {
        let checkout = try MCPTestRepo.make()
        let worktree = try MCPTestRepo.worktree(of: checkout, named: "agent")
        let file = try Self.logFile()
        Self.record(["theWellIsATarget()"], in: worktree, to: file)
        Self.record([], in: checkout, to: file)

        let rendered = RunFailureHistoryReport.render(fileURL: file, root: checkout.path, redactor: nil)

        #expect(rendered.contains("1 of 2 on one tree"), "\(rendered)")
        #expect(rendered.contains("theWellIsATarget()"))
    }

    /// A checkout whose own lines all predate the key still reaches its worktrees' newer ones, through the key of its own directory.
    @Test
    func aCheckoutWhoseLinesPredateTheKeyStillReachesItsWorktrees() throws {
        let checkout = try MCPTestRepo.make()
        let worktree = try MCPTestRepo.worktree(of: checkout, named: "agent")
        let file = try Self.logFile()
        try Self.append(Self.olderLine([], in: checkout), to: file)
        Self.record(["theWellIsATarget()"], in: worktree, to: file)

        let rendered = RunFailureHistoryReport.render(fileURL: file, root: checkout.path, redactor: nil)

        #expect(rendered.contains("1 of 2 on one tree"), "\(rendered)")
    }

    /// A worktree's line that carries no key is scoped by its directory alone, as every line was before the key existed.
    @Test
    func aLineWithoutTheKeyIsScopedByItsDirectoryAlone() throws {
        let checkout = try MCPTestRepo.make()
        let worktree = try MCPTestRepo.worktree(of: checkout, named: "agent")
        let file = try Self.logFile()
        try Self.append(Self.olderLine(["theWellIsATarget()"], in: worktree), to: file)
        try Self.append(Self.olderLine([], in: checkout), to: file)

        let rendered = RunFailureHistoryReport.render(fileURL: file, root: checkout.path, redactor: nil)

        #expect(!rendered.contains("theWellIsATarget()"), "\(rendered)")
    }

    /// A recorded root that has lost its `.git` but sits inside another checkout does not borrow that checkout's key, so the other repository's runs stay out of its history.
    @Test
    func aRootThatLostItsRepositoryDoesNotWidenToTheEnclosingOne() throws {
        let outer = try MCPTestRepo.make()
        let outerWorktree = try MCPTestRepo.worktree(of: outer, named: "agent")
        let inner = try MCPTestRepo.make(at: outer.appendingPathComponent("Nested"))
        let file = try Self.logFile()
        try Self.append(Self.olderLine([], in: inner), to: file)
        Self.record(["theWellIsATarget()"], in: outerWorktree, to: file)
        try FileManager.default.moveItem(
            at: inner.appendingPathComponent(".git"),
            to: outer.appendingPathComponent("Nested.git-aside")
        )

        let rendered = RunFailureHistoryReport.render(fileURL: file, root: inner.path, redactor: nil)

        #expect(!rendered.contains("theWellIsATarget()"), "\(rendered)")
    }

    /// The key is the repository's, not the checkout's: both halves of one repository file the same one, another repository files another, and the line carries no path beyond its root.
    @Test
    func everyWorktreeOfOneRepositoryFilesOneKey() throws {
        let checkout = try MCPTestRepo.make()
        let worktree = try MCPTestRepo.worktree(of: checkout, named: "agent")
        let other = try MCPTestRepo.make()
        let file = try Self.logFile()
        for root in [checkout, worktree, other] {
            Self.record([], in: root, to: file)
        }

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { line in
            try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        let keys = lines.map { $0["repo"] as? String }

        #expect(keys.count == 3)
        let key = try #require(keys[0])
        #expect(key.count == 16)
        #expect(keys[1] == key)
        #expect(keys[2] != nil && keys[2] != key)
        #expect(lines.allSatisfy { !$0.values.contains { ($0 as? String)?.contains(".git") == true } })
    }
}
