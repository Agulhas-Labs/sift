//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// The time budget the audit command's own replay answers under, apart from the replay suite, whose tests each name a budget of their own.
@Suite(.temporaryDirectories) struct AuditReplayTimeBudgetTests {
    /// The replay the audit command runs, left to its own time budget, waits out an answer slower than the live hook's: its count is what the hook would answer for the call's shape, never how busy the machine was while it counted.
    @Test func theAuditsOwnReplayWaitsOutAnAnswerSlowerThanTheLiveBudget() async throws {
        let root = try await WorthAnsweringFixture.repository()
        let canonical = CanonicalPath.of(root.path)
        try #require(canonical != root.path, "the answer's engine must ask for a root the classification has not already asked for")
        let slow = RootDiscovery { directory in
            if directory.path == canonical {
                Thread.sleep(forTimeInterval: InPlaceAnswer.timeBudget + 1)
            }
            return GitContext.spawnedRoot(from: directory)
        }
        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        try Data([
            TranscriptAuditReplayTests.call("cat Sources/App/Depot.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Depot"),
        ].joined(separator: [0x0A])).write(to: transcript)
        let scratch = try TemporaryDirectory.make("replay")

        let section = try await InPlaceAnswerTests.onItsOwnThread {
            Result {
                try AuditCommand.replaySection(
                    projectsDirectory: transcript.deletingLastPathComponent(),
                    since: nil,
                    transcript: transcript.path,
                    scratch: scratch,
                    roots: slow
                )
            }
        }.get()

        #expect(section.contains("  recovered       1  the hook would now answer these in place"), "\(section)")
        #expect(!section.contains { $0.contains("overTime") }, "\(section)")
    }
}
