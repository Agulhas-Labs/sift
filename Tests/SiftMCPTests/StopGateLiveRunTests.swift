//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A context that stops while a `sift run` of its tree is still going is not sent to build it again, and one that stops beside a run of an earlier tree is told to wait for it.
@Suite(.temporaryDirectories)
struct StopGateLiveRunTests {
    private static let otherTree = String(repeating: "a", count: 40)
    /// The one instant each test writes its heartbeats at and judges them against, a minute back, so a loaded machine cannot age a live run past the rule between the two and a gate that read the wall clock instead would find every run stale.
    private let instant = Date().addingTimeInterval(-60)

    /// Writes the progress file a run of `tree` would keep in the fixture's repository, last heard from `age` seconds ago.
    private func run(
        in fixture: StopGateFixture,
        tree: String?,
        phase: RunProgressSnapshot.Phase = .testing,
        age: TimeInterval = 0,
        id: String = "20261005T100000000Z-0a1b2c3d",
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let directory = RunProgressPaths.directory(in: fixture.repo, writesUnder: nil)
        #expect(directory.path.hasPrefix(fixture.repo.path), sourceLocation: sourceLocation)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var snapshot = RunProgressSnapshot(
            runId: id,
            pid: getpid(),
            repoRoot: fixture.repo.path,
            startedAt: instant.addingTimeInterval(-90),
            command: "swift test",
            tree: tree
        )
        snapshot.phase = phase
        snapshot.updatedAt = instant.addingTimeInterval(-age)
        try snapshot.encoded().write(to: RunProgressPaths.file(runId: id, in: directory))
    }

    private func editedTranscript(_ fixture: StopGateFixture) throws -> String {
        try fixture.transcript([StopGateFixture.edit("t1", path: fixture.depot), StopGateFixture.result("t1")])
    }

    private func treeKey(_ fixture: StopGateFixture, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        try #require(TreeKey.of(repositoryRoot: fixture.repo), sourceLocation: sourceLocation).value
    }

    /// The case: a suite started in the background on this tree, the turn ending to wait for it.
    ///
    /// Nothing is said, and nothing is claimed, so the verdict is still judged by the next stop.
    @Test
    func aLiveRunOfTheTreeLetsTheStopThroughAndClaimsNothing() async throws {
        let fixture = try StopGateFixture()
        let transcript = try editedTranscript(fixture)
        try run(in: fixture, tree: treeKey(fixture))

        #expect(await fixture.hook(["transcript_path": transcript], now: instant).isEmpty)

        try run(in: fixture, tree: treeKey(fixture), phase: .failed)
        let reason = try #require(try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript], now: instant)))
        #expect(reason.contains("Run `sift run -- swift build` from"))
    }

    /// A heartbeat older than the band's own rule is a run that died: the gate blocks as it always has.
    @Test
    func aRunWhoseHeartbeatWentStaleDoesNotCount() async throws {
        let fixture = try StopGateFixture()
        let transcript = try editedTranscript(fixture)
        try run(in: fixture, tree: treeKey(fixture), age: RunProgressWriter.staleAfter + 55)

        let reason = try #require(try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript], now: instant)))

        #expect(reason.contains("Run `sift run -- swift build` from"))
        #expect(!reason.contains("in progress"))
    }

    /// Edits made after the run started: the run says nothing about this tree, so the stop is blocked, but the advice is to wait for that run and not to start a build beside it.
    @Test
    func aLiveRunOfAnEarlierTreeBlocksWithoutAdvisingABuildNow() async throws {
        let fixture = try StopGateFixture()
        let transcript = try editedTranscript(fixture)
        try run(in: fixture, tree: Self.otherTree)

        let reason = try #require(try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript], now: instant)))

        #expect(reason.contains("A `sift run` of an earlier tree is in progress"))
        #expect(reason.contains("Once it ends, run `sift run -- swift build`"))
        #expect(reason.contains("1 Swift file (Depot.swift)"))
        #expect(!reason.contains("Run `sift run"))

        #expect(await fixture.hook(["transcript_path": transcript], now: instant).isEmpty, "asked once for the tree while that run lasts")
    }

    /// The wait advice does not use up the ordinary one: once the earlier run has ended, the build is still asked for.
    @Test
    func theOrdinaryAdviceStillFiresOnceTheEarlierRunEnds() async throws {
        let fixture = try StopGateFixture()
        let transcript = try editedTranscript(fixture)
        try run(in: fixture, tree: Self.otherTree)
        _ = try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript], now: instant))

        try run(in: fixture, tree: Self.otherTree, phase: .done)
        let reason = try #require(try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript], now: instant)))

        #expect(reason.contains("Run `sift run -- swift build` from"))
    }

    /// A run of no known tree (a linter, a run that builds elsewhere, a file an older sift wrote) is neither a pass nor a reason to say wait.
    @Test
    func aLiveRunOfNoKnownTreeChangesNothing() async throws {
        let fixture = try StopGateFixture()
        let transcript = try editedTranscript(fixture)
        try run(in: fixture, tree: nil)

        let reason = try #require(try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript], now: instant)))

        #expect(reason.contains("Run `sift run -- swift build` from"))
    }

    /// A green record for the tree still answers first: a live run of an earlier tree beside it says nothing.
    @Test
    func aGreenRecordStillLetsTheStopThroughBesideALiveRunOfAnEarlierTree() async throws {
        let fixture = try StopGateFixture()
        let transcript = try editedTranscript(fixture)
        try StopGateFixture.recordGreenBuild(in: fixture.repo)
        try run(in: fixture, tree: Self.otherTree)

        #expect(await fixture.hook(["transcript_path": transcript], now: instant).isEmpty)
    }
}
