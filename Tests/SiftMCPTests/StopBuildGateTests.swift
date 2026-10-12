//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// The `Stop` and `SubagentStop` hook sends a context that edited Swift back to build it, once per tree, and stays silent everywhere else.
@Suite(.temporaryDirectories)
struct StopBuildGateTests {
    @Test
    func anEditOnATreeNothingValidatedBlocksOnceNamingTheSwiftPMBuild() async throws {
        let fixture = try StopGateFixture()
        let transcript = try fixture.transcript([
            StopGateFixture.edit("t1", path: fixture.depot),
            StopGateFixture.result("t1"),
        ])

        let first = await fixture.hook(["transcript_path": transcript])
        let reason = try #require(try StopGateFixture.blockReason(of: first))

        #expect(reason.contains("`sift run -- swift build` from \(CanonicalPath.of(fixture.repo.path)) and"))
        #expect(reason.contains("1 Swift file (Depot.swift)"))

        #expect(await fixture.hook(["transcript_path": transcript]).isEmpty)
    }

    @Test
    func aStopAlreadyContinuedByAHookNeverBlocks() async throws {
        let fixture = try StopGateFixture()
        let transcript = try fixture.transcript([StopGateFixture.edit("t1", path: fixture.depot), StopGateFixture.result("t1")])

        #expect(await fixture.hook(["transcript_path": transcript, "stop_hook_active": true]).isEmpty)
    }

    @Test
    func aContextThatEditedNoSwiftNeverBlocks() async throws {
        let fixture = try StopGateFixture()
        let notes = fixture.repo.appendingPathComponent("Notes.md").path
        let transcript = try fixture.transcript([StopGateFixture.edit("t1", path: notes), StopGateFixture.result("t1")])

        #expect(await fixture.hook(["transcript_path": transcript]).isEmpty)
    }

    @Test
    func aBuildSettingEditedInARepositoryWhoseCurrentPathNamesNothingOfTheToolIsStillCounted() async throws {
        let fixture = try StopGateFixture(neutralPath: true)
        #expect(!fixture.repo.path.contains("sift"))
        let config = try fixture.file("Config/Base.xcconfig")
        let transcript = try fixture.transcript([StopGateFixture.edit("t1", path: config), StopGateFixture.result("t1")])

        let reason = try #require(await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript])))

        #expect(reason.contains("you edited 1 build input (Base.xcconfig)"))
    }

    @Test
    func aContextThatEditedOnlyABuildSettingIsAskedToBuildNamingItAsABuildInput() async throws {
        let fixture = try StopGateFixture()
        let config = try fixture.file("Config/Base.xcconfig")
        let transcript = try fixture.transcript([StopGateFixture.edit("t1", path: config), StopGateFixture.result("t1")])

        let reason = try #require(await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript])))

        #expect(reason.contains("you edited 1 build input (Base.xcconfig) and no green `sift run` build or test is on record"))
        #expect(!reason.contains("Swift file"))
    }

    @Test
    func aSwiftEditBesideAnotherInputCountsEveryFileAsABuildInput() async throws {
        let fixture = try StopGateFixture()
        let plist = try fixture.file("App/Info.plist")
        let transcript = try fixture.transcript([
            StopGateFixture.edit("t1", path: plist),
            StopGateFixture.result("t1"),
            StopGateFixture.edit("t2", path: fixture.depot),
            StopGateFixture.result("t2"),
        ])

        let reason = try #require(await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript])))

        #expect(reason.contains("you edited 2 build inputs (Info.plist, Depot.swift)"))
    }

    @Test
    func aSwiftOnlyEditKeepsTheSwiftFileWording() async throws {
        let fixture = try StopGateFixture()
        let transcript = try fixture.transcript([StopGateFixture.edit("t1", path: fixture.depot), StopGateFixture.result("t1")])

        let reason = try #require(await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript])))

        #expect(reason.contains("you edited 1 Swift file (Depot.swift) and no green"))
        #expect(!reason.contains("build input"))
    }

    @Test
    func aMarkdownOnlyEditNeverAsksForABuild() async throws {
        let fixture = try StopGateFixture()
        let notes = try fixture.file("Docs/Notes.md")
        let transcript = try fixture.transcript([StopGateFixture.edit("t1", path: notes), StopGateFixture.result("t1")])

        #expect(await fixture.hook(["transcript_path": transcript]).isEmpty)
    }

    @Test
    func aBuildSettingUnderAHiddenDirectoryIsNoEdit() async throws {
        let fixture = try StopGateFixture()
        let config = try fixture.file(".scratch/Base.xcconfig")
        let transcript = try fixture.transcript([StopGateFixture.edit("t1", path: config), StopGateFixture.result("t1")])

        #expect(await fixture.hook(["transcript_path": transcript]).isEmpty)
    }

    @Test
    func anEditWhoseResultWasAnErrorCountsForNothing() async throws {
        let fixture = try StopGateFixture()
        let transcript = try fixture.transcript([StopGateFixture.edit("t1", path: fixture.depot), StopGateFixture.result("t1", failed: true)])

        #expect(await fixture.hook(["transcript_path": transcript]).isEmpty)
    }

    /// A green `sift run` after the last edit validated it; a red one did not, and neither does one before the edit.
    @Test(arguments: [(false, false), (true, true)])
    func aSiftRunAfterTheEditAnswersItOnlyWhenGreen(failed: Bool, blocks: Bool) async throws {
        let fixture = try StopGateFixture()
        let transcript = try fixture.transcript([
            StopGateFixture.edit("t1", path: fixture.depot),
            StopGateFixture.result("t1"),
            StopGateFixture.bash("t2", command: "cd \(fixture.repo.path) && sift run -- swift build 2>&1"),
            StopGateFixture.result("t2", failed: failed),
        ])

        #expect(await !fixture.hook(["transcript_path": transcript]).isEmpty == blocks)
    }

    @Test
    func anEditAfterTheGreenRunStillBlocks() async throws {
        let fixture = try StopGateFixture()
        let transcript = try fixture.transcript([
            StopGateFixture.bash("t1", command: "sift run -- swift test --filter Depot", cwd: fixture.repo.path),
            StopGateFixture.result("t1"),
            StopGateFixture.edit("t2", path: fixture.depot),
            StopGateFixture.result("t2"),
        ])

        #expect(try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript])) != nil)
    }

    @Test
    func aGreenRecordForTheTreeAsItStandsAnswersIt() async throws {
        let fixture = try StopGateFixture()
        let tree = try #require(TreeKey.of(repositoryRoot: fixture.repo))
        fixture.ledger.record(StopGateFixture.record(tree: tree.value, command: "swift test --filter Gizmo"))
        let transcript = try fixture.transcript([StopGateFixture.edit("t1", path: fixture.depot), StopGateFixture.result("t1")])

        #expect(await fixture.hook(["transcript_path": transcript]).isEmpty)
    }

    @Test
    func aBuildSettingChangedSinceTheGreenRunStillBlocks() async throws {
        let fixture = try StopGateFixture()
        try StopGateFixture.recordGreenBuild(in: fixture.repo)
        let transcript = try fixture.transcript([StopGateFixture.edit("t1", path: fixture.depot), StopGateFixture.result("t1")])
        #expect(await fixture.hook(["transcript_path": transcript]).isEmpty)

        let settings = fixture.repo.appendingPathComponent("Base.xcconfig")
        try "SWIFT_STRICT_CONCURRENCY = complete\n".write(to: settings, atomically: true, encoding: .utf8)

        let printed = await fixture.hook(["transcript_path": transcript])
        let reason = try #require(try StopGateFixture.blockReason(of: printed))
        #expect(reason.contains("1 Swift file (Depot.swift)"))
    }

    @Test
    func aRecordedTestRunIsNeverTheCommandNamed() async throws {
        let fixture = try StopGateFixture()
        fixture.ledger.record(StopGateFixture.record(tree: "0123456789abcdef", command: "swift test --filter Gizmo", workingDirectory: "Packages/Depot"))
        let transcript = try fixture.transcript([StopGateFixture.edit("t1", path: fixture.depot), StopGateFixture.result("t1")])

        let reason = try #require(try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript])))

        #expect(reason.contains("`sift run -- swift build` from \(CanonicalPath.of(fixture.repo.path)) and"))
        #expect(!reason.contains("Gizmo"))
    }

    /// Without a package at the root the command is the context's own `xcodebuild` build, even one that failed, written as it was.
    @Test
    func anXcodebuildBuildTheContextRanIsTheOneNamed() async throws {
        let fixture = try StopGateFixture(package: false)
        let build = "sift run -- xcodebuild -scheme 'Depot App' build"
        let transcript = try fixture.transcript([
            StopGateFixture.bash("t1", command: "cd \(fixture.repo.path) && \(build) 2>&1 | tail -5"),
            StopGateFixture.result("t1", failed: true),
            StopGateFixture.edit("t2", path: fixture.depot),
            StopGateFixture.result("t2"),
        ])

        let reason = try #require(try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript])))

        #expect(reason.contains("Run `\(build)` from"))
    }

    @Test
    func anXcodebuildTestIsNotABuildToName() async throws {
        let fixture = try StopGateFixture(package: false)
        let transcript = try fixture.transcript([
            StopGateFixture.bash("t1", command: "sift run -- xcodebuild -scheme App test"),
            StopGateFixture.result("t1", failed: true),
            StopGateFixture.edit("t2", path: fixture.depot),
            StopGateFixture.result("t2"),
        ])

        #expect(await fixture.hook(["transcript_path": transcript]).isEmpty)
    }

    @Test
    func aSwiftFileTheIndexLeavesOutIsNoEdit() async throws {
        let fixture = try StopGateFixture()
        let probe = try fixture.file("pkg/.build/probe/Z.swift")
        let transcript = try fixture.transcript([StopGateFixture.edit("t1", path: probe), StopGateFixture.result("t1")])

        #expect(await fixture.hook(["transcript_path": transcript]).isEmpty)
    }

    @Test
    func aSwiftFileGitIgnoresIsNoEdit() async throws {
        let fixture = try StopGateFixture()
        try "Scratch/\n".write(to: fixture.repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let scratch = try fixture.file("Scratch/Z.swift")
        let transcript = try fixture.transcript([StopGateFixture.edit("t1", path: scratch), StopGateFixture.result("t1")])

        #expect(await fixture.hook(["transcript_path": transcript]).isEmpty)
    }

    /// The repository of the last edit is not the only one asked: an edit outside any repository after it hides nothing.
    @Test
    func anEditOutsideEveryRepositoryDoesNotHideAnEarlierOneInside() async throws {
        let fixture = try StopGateFixture()
        let outside = try TemporaryDirectory.make("stop-outside").appendingPathComponent("Loose.swift").path
        let transcript = try fixture.transcript([
            StopGateFixture.edit("t1", path: fixture.depot),
            StopGateFixture.result("t1"),
            StopGateFixture.edit("t2", path: outside),
            StopGateFixture.result("t2"),
        ])

        let reason = try #require(try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript])))

        #expect(reason.contains("1 Swift file (Depot.swift)"))
    }

    @Test(arguments: ["Write", "MultiEdit", "Edit"])
    func eachEditingToolCountsAsAnEdit(tool: String) async throws {
        let fixture = try StopGateFixture()
        let transcript = try fixture.transcript([StopGateFixture.edit("t1", path: fixture.depot, tool: tool), StopGateFixture.result("t1")])

        #expect(try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript])) != nil)
    }

    @Test
    func aRelativePathIsReadFromTheCallsDirectory() async throws {
        let fixture = try StopGateFixture()
        let transcript = try fixture.transcript([
            StopGateFixture.edit("t1", path: "Sources/App/Depot.swift", cwd: fixture.repo.path),
            StopGateFixture.result("t1"),
        ])

        let reason = try #require(try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript])))

        #expect(reason.contains("1 Swift file (Depot.swift)"))
    }

    @Test
    func noRecordAndNoPackageAtTheRootMeansNoBlock() async throws {
        let fixture = try StopGateFixture(package: false)
        let transcript = try fixture.transcript([StopGateFixture.edit("t1", path: fixture.depot), StopGateFixture.result("t1")])

        #expect(await fixture.hook(["transcript_path": transcript]).isEmpty)
    }

    /// The session answers for its own lines only, and a subagent for its own transcript, never its parent's.
    @Test
    func eachContextAnswersForItsOwnEdits() async throws {
        let fixture = try StopGateFixture()
        let session = try fixture.transcript([
            StopGateFixture.edit("t1", path: fixture.depot, sidechain: true),
            StopGateFixture.result("t1", sidechain: true),
        ])
        #expect(await fixture.hook(["transcript_path": session]).isEmpty)

        let parent = try fixture.transcript([StopGateFixture.edit("t1", path: fixture.depot), StopGateFixture.result("t1")], named: "parent")
        let quiet = try fixture.transcript([], named: "agent-quiet")
        let subagentStop: [String: Any] = ["hook_event_name": "SubagentStop", "transcript_path": parent, "agent_id": "quiet"]
        #expect(await fixture.hook(subagentStop.merging(["agent_transcript_path": quiet]) { $1 }).isEmpty)
        #expect(await fixture.hook(subagentStop).isEmpty)

        let busy = try fixture.transcript([StopGateFixture.edit("t9", path: fixture.depot), StopGateFixture.result("t9")], named: "agent-busy")
        let blocked = await fixture.hook(["hook_event_name": "SubagentStop", "transcript_path": parent, "agent_id": "busy", "agent_transcript_path": busy])
        #expect(try StopGateFixture.blockReason(of: blocked) != nil)
    }

    /// Writes the progress file a run of `tree` with process `pid` would keep in the fixture's repository, its heartbeat long stale.
    private func run(in fixture: StopGateFixture, tree: String, pid: Int32, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let directory = RunProgressPaths.directory(in: fixture.repo, writesUnder: nil)
        #expect(directory.path.hasPrefix(fixture.repo.path), sourceLocation: sourceLocation)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var snapshot = RunProgressSnapshot(
            runId: "20261010T100000000Z-0a1b2c3d",
            pid: pid,
            repoRoot: fixture.repo.path,
            startedAt: Date().addingTimeInterval(-600),
            command: "swift test",
            tree: tree
        )
        snapshot.phase = .testing
        snapshot.updatedAt = Date().addingTimeInterval(-300)
        try snapshot.encoded().write(to: RunProgressPaths.file(runId: snapshot.runId, in: directory))
    }

    @Test
    func aRunOfTheTreeWhoseProcessIsAliveLetsTheStopThroughHoweverOldItsHeartbeat() async throws {
        let fixture = try StopGateFixture()
        let transcript = try fixture.transcript([StopGateFixture.edit("t1", path: fixture.depot), StopGateFixture.result("t1")])
        try run(in: fixture, tree: #require(TreeKey.of(repositoryRoot: fixture.repo)).value, pid: getpid())

        #expect(await fixture.hook(["transcript_path": transcript]).isEmpty)
    }

    @Test
    func aRunOfTheTreeWhoseProcessIsGoneIsIgnoredAndTheBuildIsAsked() async throws {
        let fixture = try StopGateFixture()
        let transcript = try fixture.transcript([StopGateFixture.edit("t1", path: fixture.depot), StopGateFixture.result("t1")])
        try run(in: fixture, tree: #require(TreeKey.of(repositoryRoot: fixture.repo)).value, pid: ServerRootByParentTests.exitedPid())

        let reason = try #require(try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript])))

        #expect(reason.contains("Run `sift run -- swift build` from"))
    }

    @Test
    func aLiveRunOfAnotherTreeStillGetsTheBuildAskedAfterIt() async throws {
        let fixture = try StopGateFixture()
        let transcript = try fixture.transcript([StopGateFixture.edit("t1", path: fixture.depot), StopGateFixture.result("t1")])
        try run(in: fixture, tree: String(repeating: "b", count: 40), pid: getpid())

        let reason = try #require(try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript], now: Date().addingTimeInterval(-299))))

        #expect(reason.contains("Once it ends, run `sift run -- swift build`"))
    }

    @Test
    func theBlockIsTheTopLevelDecisionEnvelope() throws {
        let printed = try #require(HookOutput.stopBlock(reason: "build it"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any])

        #expect(object["decision"] as? String == "block")
        #expect(object["reason"] as? String == "build it")
        #expect(object.count == 2)
    }
}
