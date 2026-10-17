//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// The Stop block runs the agent's own build in the directory it ran in, reads a line that is one subshell or brace group as its inside, and names the build bare where the context already stands there.
@Suite(.temporaryDirectories)
struct StopGateSubshellTests {
    /// The reason a block gives after a failed Bash `command` run from the repository and an edit of `app/A.swift` made standing in `standing`.
    private func reason(
        afterRunning command: String,
        in fixture: StopGateFixture,
        standing: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> String {
        let edited = try fixture.file("app/A.swift")
        let transcript = try fixture.transcript([
            StopGateFixture.bash("t1", command: command, cwd: fixture.repo.path),
            StopGateFixture.result("t1", failed: true),
            StopGateFixture.edit("t2", path: edited, cwd: standing),
            StopGateFixture.result("t2"),
        ])
        let printed = await fixture.hook(["transcript_path": transcript])
        return try #require(try StopGateFixture.blockReason(of: printed, sourceLocation: sourceLocation), sourceLocation: sourceLocation)
    }

    @Test
    func aRunWhoseRootIsAnotherCheckoutIsRunWhereItRan() async throws {
        let fixture = try StopGateFixture(package: false, neutralPath: true)
        let worktree = try MCPTestRepo.make(at: fixture.repo.appendingPathComponent(".claude/worktrees/w"), declaring: "Gizmo")
        let edited = worktree.appendingPathComponent("Sources/App/Gizmo.swift").path
        let transcript = try fixture.transcript([
            StopGateFixture.bash("t1", command: "sift run --root .claude/worktrees/w -- xcodebuild -scheme Gizmo build", cwd: fixture.repo.path),
            StopGateFixture.result("t1", failed: true),
            StopGateFixture.edit("t2", path: edited, cwd: worktree.path),
            StopGateFixture.result("t2"),
        ])

        let reason = try #require(try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript])))

        #expect(reason.contains("Run `(cd \(CanonicalPath.of(fixture.repo.path)) && sift run --root .claude/worktrees/w -- xcodebuild -scheme Gizmo build)` and"))
    }

    @Test
    func aContinuedLineKeepsItsDirectoryAndIsNamedJoined() async throws {
        let fixture = try StopGateFixture(package: false, neutralPath: true)
        let command = "cd app && sift run -- xcodebuild -scheme Gizmo \\\n-destination 'generic/platform=iOS Simulator' build"

        let reason = try await reason(afterRunning: command, in: fixture)

        let expected = "(cd \(CanonicalPath.of(fixture.repo.path))/app && sift run -- xcodebuild -scheme Gizmo -destination 'generic/platform=iOS Simulator' build)"

        #expect(reason.contains("Run `\(expected)` and"))
    }

    @Test(arguments: [
        "(cd app && sift run -- xcodebuild -scheme Gizmo build)",
        "{ cd app && sift run -- xcodebuild -scheme Gizmo build; }",
    ])
    func aLineThatIsOneGroupIsReadAsItsInside(command: String) async throws {
        let fixture = try StopGateFixture(package: false, neutralPath: true)

        let reason = try await reason(afterRunning: command, in: fixture)

        #expect(reason.contains("Run `(cd \(CanonicalPath.of(fixture.repo.path))/app && sift run -- xcodebuild -scheme Gizmo build)` and"))
    }

    @Test(arguments: [
        "(cd app && sift run -- xcodebuild -scheme Gizmo build) 2>&1 | tail -5",
        "(cd app && sift run -- xcodebuild -scheme Gizmo build) && echo ok",
        "(cd app && sift run -- xcodebuild -scheme Gizmo build); echo done",
        "(cd app && sift run -- xcodebuild -scheme Gizmo build) || echo failed",
        "(cd app && sift run -- xcodebuild -scheme Gizmo build) &",
        "{ cd app && sift run -- xcodebuild -scheme Gizmo build; } 2>&1 | tail",
        "true && (cd app && sift run -- xcodebuild -scheme Gizmo build)",
        "( cd app && ( sift run -- xcodebuild -scheme Gizmo build ) )",
    ])
    func aGroupWithMoreOnTheLineNamesNoBuild(command: String) async throws {
        let fixture = try StopGateFixture(package: false, neutralPath: true)
        let edited = try fixture.file("app/A.swift")
        let transcript = try fixture.transcript([
            StopGateFixture.bash("t1", command: command, cwd: fixture.repo.path),
            StopGateFixture.result("t1", failed: true),
            StopGateFixture.edit("t2", path: edited),
            StopGateFixture.result("t2"),
        ])

        let printed = await fixture.hook(["transcript_path": transcript])

        #expect(try StopGateFixture.blockReason(of: printed) == nil)
    }

    @Test(arguments: [
        ("(cd /w/x && sift run -- swift build)", ["/w/x"]),
        ("(cd /w/x && sift run -- swift build) && echo ok", []),
        ("(sift run -- swift build) | tail", []),
        ("{ cd /w/x && sift run -- swift build; }", ["/w/x"]),
    ])
    func aGroupValidatesOnlyWhereItIsTheWholeLine(command: String, directories: [String]) {
        #expect(BuildInputEditsSinceGreenRun.validatedDirectories(of: command, cwd: "/w/repo") == directories)
    }

    @Test
    func aContextStandingAtThePackageRootIsToldTheBareBuild() async throws {
        let fixture = try StopGateFixture()
        let transcript = try fixture.transcript([
            StopGateFixture.edit("t1", path: fixture.depot, cwd: fixture.repo.path),
            StopGateFixture.result("t1"),
        ])

        let reason = try #require(try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript])))

        #expect(reason.contains("Run `sift run -- swift build` and"))
    }

    @Test
    func aContextStandingWhereItsXcodebuildRanIsToldTheBareSegment() async throws {
        let fixture = try StopGateFixture(package: false, neutralPath: true)

        let reason = try await reason(
            afterRunning: "cd app && sift run -- xcodebuild -scheme Gizmo build",
            in: fixture,
            standing: fixture.repo.appendingPathComponent("app").path
        )

        #expect(reason.contains("Run `sift run -- xcodebuild -scheme Gizmo build` and"))
    }

    @Test
    func aContextStandingElsewhereIsToldTheSubshell() async throws {
        let fixture = try StopGateFixture()
        let transcript = try fixture.transcript([
            StopGateFixture.edit("t1", path: fixture.depot, cwd: fixture.transcripts.path),
            StopGateFixture.result("t1"),
        ])

        let reason = try #require(try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript])))

        #expect(reason.contains("Run `(cd \(CanonicalPath.of(fixture.repo.path)) && sift run -- swift build)` and"))
    }
}
