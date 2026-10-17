//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// Covers `flakes` without `--root`: inside a git work tree it answers for that repository, and `--root /` is the way back to every repository.
@Suite(.temporaryDirectories)
struct FlakesDefaultRootTests {
    private static let key = TreeContentHash.RunKey(tree: "aaaa", invocation: "all")

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

    /// A log holding one failing and one passing run in each of two directories.
    private static func twoRootLog() throws -> (file: URL, roots: [URL]) {
        let file = try TemporaryDirectory.make("flakes-default").appendingPathComponent("run.jsonl")
        let here = try MCPTestRepo.make()
        let elsewhere = try MCPTestRepo.make()
        for root in [here, elsewhere] {
            record(["theWellIsATarget()"], in: root, to: file)
            record([], in: root, to: file)
        }
        return (file, [here, elsewhere])
    }

    @Test
    func aDirectoryInsideARepositoryResolvesToItsTopLevel() throws {
        let repo = try MCPTestRepo.make()
        let nested = repo.appendingPathComponent("Sources/App")

        let resolved = RunFailureHistoryReport.defaultRoot(workingDirectory: nested)

        #expect(resolved.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == repo.path)
    }

    @Test
    func aDirectoryOutsideAnyRepositoryResolvesToNothing() throws {
        let directory = try TemporaryDirectory.make("flakes-no-repo")

        #expect(RunFailureHistoryReport.defaultRoot(workingDirectory: directory) == nil)
    }

    @Test
    func theDefaultedRootCountsOnlyItsRunsAndSaysHowToWiden() throws {
        let (file, roots) = try Self.twoRootLog()
        let here = roots[0]

        let rendered = RunFailureHistoryReport.render(fileURL: file, root: here.path, rootIsDefault: true, redactor: nil)

        let first = try #require(rendered.split(separator: "\n").first)

        #expect(first.contains("over 2 runs"), "\(rendered)")
        #expect(first.contains("the repository this was run in; --root / for every repository"), "\(rendered)")
        #expect(first.contains(here.path), "\(rendered)")
    }

    @Test
    func rootSlashIsNoScopeSoARunThatRecordedNoRootIsCounted() throws {
        let (file, _) = try Self.twoRootLog()
        let rootless: [String: Any] = [
            "kind": "swift test", "exit": 1, "ms": 100, "ts": "2026-08-20T10:00:00Z",
            "failed": ["theWellIsATarget()"], "failed_total": 1, "tree": Self.key.tree, "invocation": Self.key.invocation,
        ]
        let line = try String(data: JSONSerialization.data(withJSONObject: rootless, options: [.sortedKeys]), encoding: .utf8) ?? ""
        let existing = try String(contentsOf: file, encoding: .utf8)
        try (existing + line + "\n").write(to: file, atomically: true, encoding: .utf8)

        let everything = RunFailureHistoryReport.render(fileURL: file, root: "/", redactor: nil)
        let unscoped = RunFailureHistoryReport.render(fileURL: file, redactor: nil)

        let first = try #require(everything.split(separator: "\n").first)

        #expect(first.contains("over 5 runs"), "\(everything)")
        #expect(!first.contains(" in "), "\(everything)")
        #expect(everything == unscoped)
    }

    @Test
    func aDefaultedRootOverAnEmptyLogAnswersAsTheUnscopedReportDoes() throws {
        let file = try TemporaryDirectory.make("flakes-empty").appendingPathComponent("run.jsonl")
        let repo = try MCPTestRepo.make()

        let rendered = RunFailureHistoryReport.render(fileURL: file, root: repo.path, rootIsDefault: true, redactor: nil)

        #expect(rendered == RunFailureHistoryReport.render(fileURL: file, redactor: nil), "\(rendered)")
    }

    @Test
    func aDefaultedRootWithNoRunsIsAnEmptyStateNotARefusal() throws {
        let (file, _) = try Self.twoRootLog()
        let unwrapped = try MCPTestRepo.make()

        let rendered = RunFailureHistoryReport.render(fileURL: file, root: unwrapped.path, rootIsDefault: true, redactor: nil)

        #expect(rendered.hasPrefix("no runs recorded in \(unwrapped.path) — the repository this was run in; --root / for every repository — 4 runs in the log overall\nlog: "), "\(rendered)")
    }
}
