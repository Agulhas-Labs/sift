//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// The stop gate asks about the edited files that are on disk, never about an edit the working tree no longer holds.
@Suite(.temporaryDirectories)
struct StopGateAbsentEditsTests {
    /// The fixture, its repository checked to sit in the temporary directory before any git writes to it.
    private func fixture(sourceLocation: SourceLocation = #_sourceLocation) throws -> StopGateFixture {
        let fixture = try StopGateFixture()
        let temporary = CanonicalPath.of(FileManager.default.temporaryDirectory.path) + "/"
        try #require(CanonicalPath.of(fixture.repo.path).hasPrefix(temporary), sourceLocation: sourceLocation)
        return fixture
    }

    /// Records the tree the fixture holds now as a green test run in the repository's ledger.
    private func recordGreen(_ fixture: StopGateFixture, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let tree = try #require(TreeKey.of(repositoryRoot: fixture.repo), sourceLocation: sourceLocation)
        fixture.ledger.record(StopGateFixture.record(tree: tree.value, command: "swift test --filter Depot"))
    }

    /// A transcript that wrote each of `paths` and ran nothing the transcript can vouch for, so the ledger alone answers.
    private func transcript(_ fixture: StopGateFixture, editing paths: [String]) throws -> String {
        try fixture.transcript(paths.enumerated().flatMap { index, path in
            [StopGateFixture.edit("t\(index)", path: path, tool: "Write"), StopGateFixture.result("t\(index)")]
        })
    }

    /// `path`, a file in the fixture, spelled as the filesystem resolves the repository, as an editor in a real checkout writes it: once the file is gone its spelling can no longer be resolved, and one under an unresolved `$TMPDIR` would fall outside the repository's root by spelling alone, hiding whether the gate drops it for being gone.
    private func canonical(_ path: String, in fixture: StopGateFixture) -> String {
        let relative = String(path.dropFirst(fixture.repo.path.count))
        return CanonicalPath.of(fixture.repo.path) + relative
    }

    private func git(_ arguments: [String], in fixture: StopGateFixture) throws {
        try MCPTestRepo.run(git: arguments, in: fixture.repo)
    }

    /// `Gizmo.swift` written and validated on a branch `feature`, then committed on `main` too, with the same content, beside a change to `Depot.swift` — so no green run is on record for the tree as it stands, though the file is as the run saw it.
    private func gizmoValidatedOnAnotherCommit() throws -> (fixture: StopGateFixture, gizmo: String) {
        let fixture = try fixture()
        try git(["checkout", "-b", "feature"], in: fixture)
        let gizmo = try fixture.file("Sources/App/Gizmo.swift")
        try recordGreen(fixture)
        try git(["add", "Sources/App/Gizmo.swift"], in: fixture)
        try git(["commit", "-m", "Gizmo"], in: fixture)
        try git(["checkout", "main"], in: fixture)
        try "struct Depot { let moved = true }\n".write(toFile: fixture.depot, atomically: true, encoding: .utf8)
        try git(["checkout", "feature", "--", "Sources/App/Gizmo.swift"], in: fixture)
        try git(["commit", "-a", "-m", "Gizmo on main, Depot moved"], in: fixture)
        return (fixture, gizmo)
    }

    /// Written on a branch, validated and committed there, then the branch checked out away from.
    @Test
    func anEditCommittedOnABranchAndCheckedOutAwayFromAsksNothing() async throws {
        let fixture = try fixture()
        try git(["checkout", "-b", "feature"], in: fixture)
        let written = try canonical(fixture.file("Sources/App/Catalogue.swift"), in: fixture)
        try recordGreen(fixture)
        try git(["add", "Sources/App/Catalogue.swift"], in: fixture)
        try git(["commit", "-m", "Catalogue"], in: fixture)
        try git(["checkout", "main"], in: fixture)
        try #require(!FileManager.default.fileExists(atPath: written))

        #expect(try await fixture.hook(["transcript_path": transcript(fixture, editing: [written])]).isEmpty)
    }

    /// Deleted after it was written, with no green run anywhere: there is nothing left to build.
    @Test
    func anEditedFileSinceDeletedAsksNothing() async throws {
        let fixture = try fixture()
        let written = try canonical(fixture.file("Sources/App/Gizmo.swift"), in: fixture)
        try FileManager.default.removeItem(atPath: written)

        #expect(try await fixture.hook(["transcript_path": transcript(fixture, editing: [written])]).isEmpty)
    }

    /// The edited file is as a green run saw it, but a file it builds with moved since: the run does not stand for the build.
    @Test
    func anEditedFileUnchangedSinceAGreenRunAsksWhenADependencyMoved() async throws {
        let (fixture, gizmo) = try gizmoValidatedOnAnotherCommit()

        let reason = try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript(fixture, editing: [gizmo])]))

        #expect(reason?.contains("1 Swift file (Gizmo.swift)") == true)
    }

    @Test
    func aFileChangedSinceTheGreenRunStillAsks() async throws {
        let (fixture, gizmo) = try gizmoValidatedOnAnotherCommit()
        try "struct Probe { var edited = 1 }\n".write(toFile: gizmo, atomically: true, encoding: .utf8)

        let reason = try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript(fixture, editing: [gizmo])]))

        #expect(reason?.contains("1 Swift file (Gizmo.swift)") == true)
    }
}
