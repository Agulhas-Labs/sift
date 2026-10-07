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

    @Test
    func theBlockIsTheTopLevelDecisionEnvelope() throws {
        let printed = try #require(HookOutput.stopBlock(reason: "build it"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any])

        #expect(object["decision"] as? String == "block")
        #expect(object["reason"] as? String == "build it")
        #expect(object.count == 2)
    }
}
