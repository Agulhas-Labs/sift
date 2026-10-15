//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A `sift run` answer's `raw:` line names the tree and commit the run happened in, in the words of the `tree:` header.
///
/// Without it a suite run in the wrong checkout reads, line for line, as the run that was meant.
@Suite(.temporaryDirectories)
struct RunRawLineNamesTreeTests {
    @Test
    func theStampIsTheHeadersOwnWordsForTheTreeAndItsCommit() {
        let tree = WorkingTree(repository: "Widget", worktree: "agent-1")

        #expect(Freshness.stamp(of: tree, headShort: "cc94af6", dirtyCount: 0) == "Widget (worktree agent-1) @ cc94af6 (Swift clean)")
        #expect(Freshness.stamp(of: tree, headShort: "cc94af6", dirtyCount: 3) == "Widget (worktree agent-1) @ cc94af6 (Swift dirty: 3)")
        #expect(Freshness.stamp(of: tree, headShort: Freshness.unbornHead, dirtyCount: 0) == "Widget (worktree agent-1) @ unborn (Swift dirty: 0)")
        #expect(Freshness.stamp(of: tree, headShort: nil, dirtyCount: nil) == "Widget (worktree agent-1)")
        #expect(Freshness.stamp(of: tree, headShort: "cc94af6", dirtyCount: nil) == "Widget (worktree agent-1) @ cc94af6")

        let header = Freshness(tree: tree, headShort: "cc94af6", dirtyCount: 0, parseErrorFiles: 0).syntacticHeaderLine
        #expect(header == "tree: Widget (worktree agent-1)  head: cc94af6  clean")
    }

    @Test
    func theRawLineOpensWithTheStampBeforeTheLogPath() {
        let renderer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"), treeStamp: "Widget @ abc1234 (Swift clean)")
        let line = Self.rawLine(of: renderer)

        #expect(line == "raw: Widget @ abc1234 (Swift clean) · .sift/runs/run-a.log (1 lines in, 3 out), kept for the next 4 runs")
    }

    @Test
    func aRendererGivenNoStampKeepsTheBareLine() {
        let renderer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"))

        #expect(Self.rawLine(of: renderer) == "raw: .sift/runs/run-a.log (1 lines in, 3 out), kept for the next 4 runs")
    }

    @Test
    func aRunInARepositoryNamesItsTreeAndCommitAndSaysWhenTheTreeHasMoved() throws {
        let root = try TestSources.makeTempRepo()
        let swift = try Self.fakeSwift(in: root)
        try "struct Widget {}\n".write(to: root.appendingPathComponent("Widget.swift"), atomically: true, encoding: .utf8)
        let head = try String(TestSources.runGit(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines).prefix(7))
        let outcome = try RunLauncher(workingDirectory: root, repositoryRoot: root).run([swift.path, "test"])
        let stamp = "\(WorkingTree.describing(root).rendered) @ \(head)"

        let moved = try #require(outcome.filteredAnswer(workingDirectory: root, stamped: true)?.text)
        #expect(Self.rawLine(in: moved).hasPrefix("raw: \(stamp) (Swift dirty: 1) · "))

        try TestSources.commitAll(in: root, message: "settle")
        let settled = try TestSources.runGit(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = try #require(outcome.filteredAnswer(workingDirectory: root, stamped: true)?.text)
        #expect(Self.rawLine(in: clean).hasPrefix("raw: \(WorkingTree.describing(root).rendered) @ \(settled.prefix(7)) (Swift clean) · "))
    }

    @Test
    func theStampCallsATreeCleanWhenTheHeaderDoes() throws {
        let root = try TestSources.makeTempRepo()
        let swift = try Self.fakeSwift(in: root)
        try TestSources.commitAll(in: root, message: "settle")
        try "build/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "notes\n".write(to: root.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        let outcome = try RunLauncher(workingDirectory: root, repositoryRoot: root).run([swift.path, "test"])

        let answer = try #require(outcome.filteredAnswer(workingDirectory: root, stamped: true)?.text)

        #expect(Self.rawLine(in: answer).contains(" (Swift clean) · "))
    }

    @Test
    func aTreeWhoseDirtyStateCannotBeReadIsNotCalledClean() throws {
        let root = try TestSources.makeTempRepo()
        let swift = try Self.fakeSwift(in: root)
        let outcome = try RunLauncher(workingDirectory: root, repositoryRoot: root).run([swift.path, "test"])
        try "not an index".write(to: root.appendingPathComponent(".git/index"), atomically: true, encoding: .utf8)

        let answer = try #require(outcome.filteredAnswer(workingDirectory: root, stamped: true)?.text)
        let line = Self.rawLine(in: answer)

        #expect(line.hasPrefix("raw: \(WorkingTree.describing(root).rendered) @ "))
        #expect(line.contains(" · .sift/runs/"))
        #expect(!line.contains("(Swift clean)"))
        #expect(!line.contains("(Swift dirty"))
    }

    @Test
    func aRunOutsideARepositoryNamesTheTreeAlone() throws {
        let root = try TestSources.makeTempDirectory()
        let swift = try Self.fakeSwift(in: root)
        let outcome = try RunLauncher(workingDirectory: root).run([swift.path, "test"])

        let answer = outcome.filteredAnswer(workingDirectory: root, stamped: true)?.text

        #expect(Self.rawLine(in: answer ?? "").hasPrefix("raw: \(WorkingTree.describing(root).rendered) · "))
    }

    @Test
    func theInternalCallersThatReadTheAnswerBackAreNotStamped() throws {
        let root = try TestSources.makeTempRepo()
        let swift = try Self.fakeSwift(in: root)
        let outcome = try RunLauncher(workingDirectory: root, repositoryRoot: root).run([swift.path, "test"])

        let answer = outcome.filteredAnswer(workingDirectory: root)?.text

        #expect(Self.rawLine(in: answer ?? "").hasPrefix("raw: .sift/runs/"))
    }

    private static func rawLine(of renderer: RunReportRenderer) -> String {
        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        filter.consume(line: "✔ Test run with 1 test in 1 suite passed after 0.047 seconds.")
        let report = filter.finish(exitCode: 0)
        let answer = renderer.render(report, exitCode: 0, logURL: URL(fileURLWithPath: "/Users/dev/Widget/.sift/runs/run-a.log"))
        return rawLine(in: answer)
    }

    private static func rawLine(in answer: String) -> String {
        answer.split(separator: "\n").last { $0.hasPrefix("raw: ") }.map(String.init) ?? ""
    }

    /// A stand-in `swift` that prints one passing Swift Testing line and exits 0, with an untracked file beside it so a repository it stands in is dirty.
    private static func fakeSwift(in directory: URL) throws -> URL {
        let script = directory.appendingPathComponent("swift")
        try "#!/bin/sh\necho '✔ Test run with 1 test in 1 suite passed after 0.047 seconds.'\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}
