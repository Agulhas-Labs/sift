//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The reader of a repository's live runs, and the `tree` key a run's file carries for it.
@Suite(.temporaryDirectories)
struct RunProgressLiveRunsTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot(phase: RunProgressSnapshot.Phase, heard: TimeInterval, tree: String? = "abc") -> RunProgressSnapshot {
        var snapshot = RunProgressSnapshot(runId: "r", pid: 1, repoRoot: "/tmp/repo", startedAt: Self.now - 100, command: "swift test", tree: tree)
        snapshot.phase = phase
        snapshot.updatedAt = Self.now - heard
        return snapshot
    }

    /// The band's rule: a phase that has not ended, and a heartbeat no older than `staleAfter`, the limit itself included.
    @Test(arguments: [
        (RunProgressSnapshot.Phase.idle, 0.0, true),
        (.building, 2.0, true),
        (.testing, RunProgressWriter.staleAfter, true),
        (.testing, RunProgressWriter.staleAfter + 0.001, false),
        (.done, 0.0, false),
        (.failed, 0.0, false),
    ])
    func aRunIsLiveWhileItsPhaseIsOpenAndItsHeartbeatFresh(phase: RunProgressSnapshot.Phase, heard: TimeInterval, live: Bool) {
        #expect(snapshot(phase: phase, heard: heard).isLive(at: Self.now) == live)
    }

    @Test
    func theLiveRunsAreTheRunFilesStillLiveInTheRepositorysOwnDirectory() throws {
        let root = try TemporaryDirectory.make("live-runs")
        let directory = RunProgressPaths.directory(in: root, writesUnder: nil)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (id, shot) in [("live", snapshot(phase: .building, heard: 1)), ("stale", snapshot(phase: .building, heard: 60)), ("over", snapshot(phase: .done, heard: 0))] {
            try shot.encoded().write(to: RunProgressPaths.file(runId: id, in: directory))
        }
        try Data("not json".utf8).write(to: RunProgressPaths.file(runId: "garbled", in: directory))
        try snapshot(phase: .building, heard: 0).encoded().write(to: directory.appendingPathComponent("notes-live.json"))

        let live = RunProgressPaths.liveRuns(inRepositoryAt: root, at: Self.now)

        #expect(live.count == 1)
        #expect(RunProgressPaths.liveRuns(inRepositoryAt: root.appendingPathComponent("nowhere"), at: Self.now).isEmpty)
    }

    /// A file an older sift wrote has no `tree`, and still decodes: reading it as unreadable would have the prune delete a live run's file.
    @Test
    func aFileWithoutATreeDecodesWithNone() throws {
        var object = try #require(JSONSerialization.jsonObject(with: snapshot(phase: .building, heard: 0).encoded()) as? [String: Any])
        #expect(object["tree"] as? String == "abc")
        object["tree"] = nil

        let decoded = try RunProgressSnapshot.decoded(from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.tree == nil)
    }

    /// The tree a run is given is in its file from the first snapshot to the last, and no update can change it.
    @Test
    func theTreeIsInTheFileFromTheStartAndStaysThere() throws {
        let root = try TemporaryDirectory.make("live-tree")
        let directory = RunProgressPaths.directory(in: root, writesUnder: nil)
        let progress = try #require(RunProgress.forRun(in: root, writesUnder: nil, environment: [:], tree: "feedface"))
        progress.begin(["swift", "build"], kind: .swiftBuild, logPath: nil)
        defer { progress.writer.reset() }
        func onDisk(sourceLocation: SourceLocation = #_sourceLocation) throws -> RunProgressSnapshot {
            let name = try #require(FileManager.default.contentsOfDirectory(atPath: directory.path).first(where: RunProgressPaths.isRunFile), sourceLocation: sourceLocation)
            return try RunProgressSnapshot.decoded(from: Data(contentsOf: directory.appendingPathComponent(name)))
        }

        #expect(try onDisk().tree == "feedface")

        progress.writer.update { $0.tree = "changed" }
        progress.finish(exitCode: 0, logPath: nil)

        #expect(try onDisk().tree == "feedface")
    }
}
