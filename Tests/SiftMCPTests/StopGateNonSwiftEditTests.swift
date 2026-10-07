//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A green run vouches for the Swift sources it saw, so a stop after only a note or a changelog moved, or after the same sources were committed, is not sent back to build.
@Suite(.temporaryDirectories)
struct StopGateNonSwiftEditTests {
    /// The transcript of a context that wrote `swift` and then ran tests in a shape the transcript cannot vouch for, so the ledger alone answers.
    private func transcript(_ fixture: StopGateFixture, swift: String) throws -> String {
        try fixture.transcript([
            StopGateFixture.edit("t1", path: swift, tool: "Write"),
            StopGateFixture.result("t1"),
            StopGateFixture.bash("t2", command: "sift run -- swift test --filter Depot > out.txt 2>&1; echo done", cwd: fixture.repo.path),
            StopGateFixture.result("t2"),
        ])
    }

    @Test
    func aChangelogEditedAndCommittedAfterTheGreenRunLeavesItStanding() async throws {
        let fixture = try StopGateFixture()
        let swift = try fixture.file("Tests/AppTests/GizmoTests.swift")
        let green = try #require(TreeKey.of(repositoryRoot: fixture.repo))
        fixture.ledger.record(StopGateFixture.record(tree: green.value, command: "swift test --filter Depot"))
        try "# Changes\n- a note\n".write(to: fixture.repo.appendingPathComponent("CHANGELOG.md"), atomically: true, encoding: .utf8)
        try MCPTestRepo.run(git: ["add", "CHANGELOG.md", "Tests/AppTests/GizmoTests.swift"], in: fixture.repo)
        try MCPTestRepo.run(git: ["commit", "-m", "Changelog"], in: fixture.repo)

        #expect(try await fixture.hook(["transcript_path": transcript(fixture, swift: swift)]).isEmpty)
    }

    @Test
    func aNoteEditedAndNeverCommittedLeavesItStanding() async throws {
        let fixture = try StopGateFixture()
        let swift = try fixture.file("Tests/AppTests/GizmoTests.swift")
        let green = try #require(TreeKey.of(repositoryRoot: fixture.repo))
        fixture.ledger.record(StopGateFixture.record(tree: green.value, command: "swift test --filter Depot"))
        try "scratch\n".write(to: fixture.repo.appendingPathComponent("Notes.md"), atomically: true, encoding: .utf8)

        #expect(try await fixture.hook(["transcript_path": transcript(fixture, swift: swift)]).isEmpty)
    }

    @Test
    func aSwiftEditAfterTheGreenRunStillBlocksBesideAChangelogEdit() async throws {
        let fixture = try StopGateFixture()
        let swift = try fixture.file("Tests/AppTests/GizmoTests.swift")
        let green = try #require(TreeKey.of(repositoryRoot: fixture.repo))
        fixture.ledger.record(StopGateFixture.record(tree: green.value, command: "swift test --filter Depot"))
        try "# Changes\n".write(to: fixture.repo.appendingPathComponent("CHANGELOG.md"), atomically: true, encoding: .utf8)
        try "struct Probe { var edited = 1 }\n".write(to: URL(fileURLWithPath: swift), atomically: true, encoding: .utf8)

        let reason = try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript(fixture, swift: swift)]))

        #expect(reason?.contains("1 Swift file (GizmoTests.swift)") == true)
    }

    @Test
    func aPackageManifestEditedAfterTheGreenRunStillBlocks() async throws {
        let fixture = try StopGateFixture()
        let swift = try fixture.file("Tests/AppTests/GizmoTests.swift")
        let green = try #require(TreeKey.of(repositoryRoot: fixture.repo))
        fixture.ledger.record(StopGateFixture.record(tree: green.value, command: "swift test --filter Depot"))
        let manifest = fixture.repo.appendingPathComponent("Package.swift")
        try (String(contentsOf: manifest, encoding: .utf8) + "// a dependency\n").write(to: manifest, atomically: true, encoding: .utf8)

        #expect(try await !fixture.hook(["transcript_path": transcript(fixture, swift: swift)]).isEmpty)
    }
}
