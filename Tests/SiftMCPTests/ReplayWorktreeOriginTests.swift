//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// The replay judges a call run in a linked worktree gone from disk against the repository it was cut from, where evidence names one, and withholds it as unreplayable where none does.
@Suite(.temporaryDirectories) struct ReplayWorktreeOriginTests {
    /// A call run in a gone linked worktree under the repository's own ignored tree (`<repo>/.build/<name>`) is judged against the repository it lay in, as one under `.claude/worktrees` is, and so is a command that opens by moving into it — neither is withheld as unreplayable.
    @Test func aCallInAGoneWorktreeUnderTheRepositorysIgnoredTreeIsJudgedAgainstTheRepository() async throws {
        let root = try await WorthAnsweringFixture.repository()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".build"), withIntermediateDirectories: true)
        try ".build/\n".write(to: root.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
        let members = (1 ... 40).map { "    func part\($0)() -> Int {\n        let count = \($0)\(WorthAnsweringFixture.comment)\n        let doubled = count * 2\n        return doubled + count\n    }" }
        try ("/// A yard.\nstruct Yard {\n" + members.joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent("Sources/App/Yard.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        let gone = root.appendingPathComponent(".build/wtX").path

        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let lines = try [
            TranscriptAuditReplayTests.call("cat Sources/App/Depot.swift", id: "c1", cwd: gone, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Depot"),
            TranscriptAuditReplayTests.call("cd .build/wtX && cat Sources/App/Yard.swift", id: "c2", cwd: root.path, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "c2", isError: false, text: "struct Yard"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)

        let section = try await TranscriptAuditReplayTests.replaySection(of: transcript)

        #expect(section.contains("  unreplayable    0  the directory they run in is not on disk now — neither recovered nor judged"), "\(section)")
        #expect(section.contains { $0.hasPrefix("  recovered       2  ") }, "\(section)")
    }

    /// A gone worktree outside any repository's tree is judged against the repository the session's own `git worktree add` ran in, since that command names where it was cut from.
    @Test func aGoneWorktreeTheTranscriptAddedIsJudgedAgainstTheRepositoryItRanIn() async throws {
        let root = try await WorthAnsweringFixture.repository()
        let name = "\(root.lastPathComponent)-wt"
        let gone = root.deletingLastPathComponent().appendingPathComponent(name).path

        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let lines = try [
            TranscriptAuditReplayTests.call("git worktree add -q ../\(name) HEAD", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: ""),
            TranscriptAuditReplayTests.call("cat Sources/App/Depot.swift", id: "c2", cwd: gone, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "c2", isError: false, text: "struct Depot"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)

        let section = try await TranscriptAuditReplayTests.replaySection(of: transcript)

        #expect(section.contains("  unreplayable    0  the directory they run in is not on disk now — neither recovered nor judged"), "\(section)")
        #expect(section.contains { $0.hasPrefix("  recovered       1  ") }, "\(section)")
    }

    /// A `git worktree add` whose command word is spelled through quotes names where the worktree was cut from as the plain spelling does, since the shell runs the same command for both.
    @Test(arguments: [#"g"it""#, "g'i't"])
    func aWorktreeAddSpelledThroughQuotesIsReadAsTheSame(git: String) async throws {
        let root = try await WorthAnsweringFixture.repository()
        let name = "\(root.lastPathComponent)-wt"
        let gone = root.deletingLastPathComponent().appendingPathComponent(name).path

        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let lines = try [
            TranscriptAuditReplayTests.call("\(git) worktree add -q ../\(name) HEAD", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: ""),
            TranscriptAuditReplayTests.call("cat Sources/App/Depot.swift", id: "c2", cwd: gone, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "c2", isError: false, text: "struct Depot"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)

        let section = try await TranscriptAuditReplayTests.replaySection(of: transcript)

        #expect(section.contains("  unreplayable    0  the directory they run in is not on disk now — neither recovered nor judged"), "\(section)")
        #expect(section.contains { $0.hasPrefix("  recovered       1  ") }, "\(section)")
    }

    /// A gone directory under the repository's ignored tree that the session made itself with `mkdir` is a scratch directory, never a checkout of the repository, so a call run in it stays unreplayable.
    @Test func aGoneDirectoryTheTranscriptMadeWithMkdirStaysUnreplayable() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".build"), withIntermediateDirectories: true)
        try ".build/\n".write(to: root.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
        let gone = root.appendingPathComponent(".build/probe").path

        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let lines = try [
            TranscriptAuditReplayTests.call("mkdir -p .build/probe/Sources/App", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: ""),
            TranscriptAuditReplayTests.call("cat Sources/App/Depot.swift", id: "c2", cwd: gone, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "c2", isError: false, text: "struct Depot"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)

        let section = try await TranscriptAuditReplayTests.replaySection(of: transcript)

        #expect(section.contains("  unreplayable    1  the directory they run in is not on disk now — neither recovered nor judged"), "\(section)")
    }
}
