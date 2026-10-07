//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A green `sift run` answers only for the repository it built, and only where the call's result vouches for it.
@Suite(.temporaryDirectories)
struct StopGateRunScopeTests {
    /// The issue's case: an edit in `pkg`, then `cd xc && sift run -- swift build`, green, and a stop — `pkg` was never built.
    @Test(arguments: [true, false])
    func aGreenRunInAnotherRepositoryLeavesTheEditStanding(relative: Bool) async throws {
        let fixture = try StopGateFixture()
        let parent = try TemporaryDirectory.make("stop-repos").resolvingSymlinksInPath()
        let other = try MCPTestRepo.make(at: parent.appendingPathComponent("xc"), declaring: "Gauge")
        let transcript = try fixture.transcript([
            StopGateFixture.edit("t1", path: fixture.depot),
            StopGateFixture.result("t1"),
            StopGateFixture.bash("t2", command: "cd \(relative ? "xc" : other.path) && sift run -- swift build", cwd: parent.path),
            StopGateFixture.result("t2"),
        ])

        let reason = try #require(try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript])))

        #expect(reason.contains("1 Swift file (Depot.swift)"))
    }

    /// A green run in one repository clears its own edits and leaves every other repository's standing.
    @Test
    func aGreenRunClearsOnlyTheEditsInItsOwnRepository() async throws {
        let fixture = try StopGateFixture()
        let other = try MCPTestRepo.make(declaring: "Gauge")
        let gauge = other.appendingPathComponent("Sources/App/Gauge.swift").path
        let transcript = try fixture.transcript([
            StopGateFixture.edit("t1", path: fixture.depot),
            StopGateFixture.result("t1"),
            StopGateFixture.edit("t2", path: gauge),
            StopGateFixture.result("t2"),
            StopGateFixture.bash("t3", command: "sift run -- swift build", cwd: other.path),
            StopGateFixture.result("t3"),
        ])

        let reason = try #require(try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript])))

        #expect(reason.contains("1 Swift file (Depot.swift)"))
    }

    /// The same run in the edited repository still lets the context stop, from its root or from a directory inside it.
    @Test(arguments: [("sift run -- swift build", ""), ("cd Sources/App && sift run -- swift test --filter Depot", ""), ("sift run -- swift build", "/Sources")])
    func aGreenRunInTheEditedRepositoryClearsIt(command: String, below: String) async throws {
        let fixture = try StopGateFixture()
        let transcript = try fixture.transcript([
            StopGateFixture.edit("t1", path: fixture.depot),
            StopGateFixture.result("t1"),
            StopGateFixture.bash("t2", command: command, cwd: fixture.repo.path + below),
            StopGateFixture.result("t2"),
        ])

        #expect(await fixture.hook(["transcript_path": transcript]).isEmpty)
    }

    /// A linked worktree is a checkout of its own: a build there never answers for an edit in the primary one.
    @Test
    func aGreenRunInAnotherWorktreeLeavesTheEditStanding() async throws {
        let fixture = try StopGateFixture()
        let worktree = try MCPTestRepo.worktree(of: fixture.repo, named: "side")
        let transcript = try fixture.transcript([
            StopGateFixture.edit("t1", path: fixture.depot),
            StopGateFixture.result("t1"),
            StopGateFixture.bash("t2", command: "sift run -- swift build", cwd: worktree.path),
            StopGateFixture.result("t2"),
        ])

        #expect(try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript])) != nil)
    }

    /// A piped run's call succeeds with the last stage, whatever the build did, so its success proves nothing.
    @Test
    func aPipedRunLeavesTheEditStanding() async throws {
        let fixture = try StopGateFixture()
        let transcript = try fixture.transcript([
            StopGateFixture.edit("t1", path: fixture.depot),
            StopGateFixture.result("t1"),
            StopGateFixture.bash("t2", command: "sift run -- swift build 2>&1 | tail -5", cwd: fixture.repo.path),
            StopGateFixture.result("t2"),
        ])

        #expect(try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript])) != nil)
    }

    @Test(arguments: [
        ("sift run -- swift build", ["/w/repo"]),
        ("sift run -- swift build 2>&1", ["/w/repo"]),
        ("cd /w/xc && sift run -- swift build", ["/w/xc"]),
        ("cd xc && sift run -- swift test --filter X", ["/w/repo/xc"]),
        ("cd .. && cd pkg && sift run -- swift build && echo done", ["/w/pkg"]),
        ("cd /w/a && sift run -- swift build && cd /w/b && sift run -- swift test", ["/w/a", "/w/b"]),
        ("sift run -- swift build;", ["/w/repo"]),
        ("sift run -- swift build --package-path ../pkg", ["/w/pkg"]),
        ("sift run -- xcodebuild -project App/App.xcodeproj -scheme App build", ["/w/repo/App"]),
        ("sift run -- xcodebuild test -scheme Depot", ["/w/repo"]),
        ("sift run -- swift test --skip-build", []),
        ("sift run -- xcodebuild test-without-building -scheme Depot", []),
        ("sift run -- swift build | tail -5", []),
        ("sift run -- swift build |& tail -5", []),
        ("sift run -- swift build; echo done", []),
        ("sift run -- swift build || true", []),
        ("make || sift run -- swift build", []),
        ("sift run -- swift build &", []),
        ("cd /w/xc; sift run -- swift build", []),
        ("false || cd /w/xc && sift run -- swift build", []),
        ("(cd /w/xc && sift run -- swift build)", []),
        ("pushd /w/xc && sift run -- swift build", []),
        ("cd $HOME/xc && sift run -- swift build", []),
        ("sift run -- swift build --package-path $PKG", []),
        ("sift run -- swiftlint lint --strict", []),
        ("swift build", []),
        ("sift digest Depot", []),
        ("echo 'sift run -- swift build'", []),
    ])
    func theDirectoriesAGreenCallVouchesFor(command: String, directories: [String]) {
        #expect(SwiftEditsSinceGreenRun.validatedDirectories(of: command, cwd: "/w/repo") == directories)
    }

    /// With no directory for the call, only an absolute `cd` places the run.
    @Test
    func aCallWithNoDirectoryPlacesOnlyAnAbsoluteRun() {
        #expect(SwiftEditsSinceGreenRun.validatedDirectories(of: "sift run -- swift build", cwd: nil).isEmpty)
        #expect(SwiftEditsSinceGreenRun.validatedDirectories(of: "cd xc && sift run -- swift build", cwd: nil).isEmpty)
        #expect(SwiftEditsSinceGreenRun.validatedDirectories(of: "cd /w/xc && sift run -- swift build", cwd: nil) == ["/w/xc"])
    }

    /// The forms most real runs take — piped into `tail`, or logged with `; echo exit=$?` after — prove nothing through the call's result, but the run recorded the tree it saw itself, and that record clears the edit.
    @Test(arguments: ["sift run -- swift build 2>&1 | tail -5", "sift run -- swift build > .build/b.log 2>&1; echo exit=$?"])
    func aGreenRunOnRecordClearsTheEditHoweverTheShellWrappedIt(command: String) async throws {
        let fixture = try StopGateFixture()
        try "struct Depot { let edited = true }\n".write(toFile: fixture.depot, atomically: true, encoding: .utf8)
        try StopGateFixture.recordGreenBuild(in: fixture.repo)
        let transcript = try fixture.transcript([
            StopGateFixture.edit("t1", path: fixture.depot),
            StopGateFixture.result("t1"),
            StopGateFixture.bash("t2", command: command, cwd: fixture.repo.path),
            StopGateFixture.result("t2"),
        ])

        #expect(await fixture.hook(["transcript_path": transcript]).isEmpty)
    }

    /// A green run on record in another repository, or in a linked worktree of this one holding the very same tree, never answers for an edit here.
    @Test(arguments: [true, false])
    func aGreenRunOnRecordElsewhereLeavesTheEditStanding(worktree: Bool) async throws {
        let fixture = try StopGateFixture()
        let elsewhere = try worktree ? MCPTestRepo.worktree(of: fixture.repo, named: "side") : MCPTestRepo.make(declaring: "Gauge")
        if worktree {
            // The fixture's manifest is untracked, so the worktree needs its own copy to hold the same tree.
            try FileManager.default.copyItem(at: fixture.repo.appendingPathComponent("Package.swift"), to: elsewhere.appendingPathComponent("Package.swift"))
            #expect(TreeKey.of(repositoryRoot: elsewhere) == TreeKey.of(repositoryRoot: fixture.repo))
        }
        try StopGateFixture.recordGreenBuild(in: elsewhere)
        let transcript = try fixture.transcript([
            StopGateFixture.edit("t1", path: fixture.depot),
            StopGateFixture.result("t1"),
            StopGateFixture.bash("t2", command: "sift run -- swift build 2>&1 | tail -5", cwd: elsewhere.path),
            StopGateFixture.result("t2"),
        ])

        #expect(try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript])) != nil)
    }

    /// An edit landing after the recorded run changes the tree, and the record no longer stands for it.
    @Test
    func anEditAfterTheRecordedRunLeavesItStanding() async throws {
        let fixture = try StopGateFixture()
        try StopGateFixture.recordGreenBuild(in: fixture.repo)
        try "struct Depot { let edited = true }\n".write(toFile: fixture.depot, atomically: true, encoding: .utf8)
        let transcript = try fixture.transcript([
            StopGateFixture.bash("t1", command: "sift run -- swift build 2>&1 | tail -5", cwd: fixture.repo.path),
            StopGateFixture.result("t1"),
            StopGateFixture.edit("t2", path: fixture.depot),
            StopGateFixture.result("t2"),
        ])

        #expect(try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript])) != nil)
    }
}
