//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A `sift run --root` build vouches for the directory it names, and the Stop block names its build as a subshell.
@Suite(.temporaryDirectories)
struct StopGateRootRunTests {
    @Test(arguments: [
        ("sift run --root /w/other -- swift build", ["/w/other"]),
        ("sift run --root ../other -- swift test", ["/w/other"]),
        ("cd /w/x && sift run --root sub -- swift build", ["/w/x/sub"]),
        ("sift run --root=/w/other -- swift build", ["/w/other"]),
        ("sift run --root /w/other swift build", ["/w/other"]),
    ])
    func aRunsOwnRootPlacesIt(command: String, directories: [String]) {
        #expect(BuildInputEditsSinceGreenRun.validatedDirectories(of: command, cwd: "/w/repo") == directories)
    }

    @Test
    func anotherOptionLeavesTheRunWhereItWas() {
        #expect(BuildInputEditsSinceGreenRun.validatedDirectories(of: "sift run --without Sources -- swift test", cwd: "/w/repo") == ["/w/repo"])
    }

    @Test
    func aRelativeRootWithNoDirectoryPlacesNothing() {
        #expect(BuildInputEditsSinceGreenRun.validatedDirectories(of: "sift run --root rel -- swift build", cwd: nil).isEmpty)
    }

    @Test
    func aPackageRootIsNamedAsASubshell() throws {
        let root = try TemporaryDirectory.make("stop-root")
        try "// swift-tools-version: 6.0\n".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let command = StopBuildGate.command(root: root, xcodebuild: nil)

        #expect(command?.command == "(cd \(root.path) && sift run -- swift build)")
        #expect(command?.directory == root.path)
    }

    @Test
    func anXcodebuildIsWrappedVerbatimInItsDirectory() throws {
        let root = try TemporaryDirectory.make("stop-root")
        let inside = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let written = "sift run -- xcodebuild -scheme Gizmo -destination 'generic/platform=iOS Simulator' build"
        let command = StopBuildGate.command(root: root, xcodebuild: (written, inside.path))
        let canonical = CanonicalPath.of(inside.path)

        #expect(command?.command == "(cd \(canonical) && sift run -- xcodebuild -scheme Gizmo -destination 'generic/platform=iOS Simulator' build)")
    }

    @Test
    func anXcodebuildWithItsOwnRootIsWrappedVerbatim() throws {
        let root = try TemporaryDirectory.make("stop-root")
        let written = "sift run --root /x -- xcodebuild -scheme Gizmo build"
        let command = StopBuildGate.command(root: root, xcodebuild: (written, root.path))

        #expect(command?.command == "(cd \(CanonicalPath.of(root.path)) && sift run --root /x -- xcodebuild -scheme Gizmo build)")
    }

    @Test
    func anXcodebuildOfUnknownDirectoryNamesNoBuild() throws {
        let root = try TemporaryDirectory.make("stop-root")
        let written = "sift run -- xcodebuild -scheme Gizmo build"
        let command = StopBuildGate.command(root: root, xcodebuild: (written, nil))

        #expect(command == nil)
    }

    @Test
    func aCdOnTheLineIsTheDirectoryTheBuildIsNamedIn() async throws {
        let fixture = try StopGateFixture(package: false, neutralPath: true)
        let edited = try fixture.file("app/A.swift")
        let transcript = try fixture.transcript([
            StopGateFixture.bash("t1", command: "cd app && sift run -- xcodebuild -scheme Gizmo build", cwd: fixture.repo.path),
            StopGateFixture.result("t1", failed: true),
            StopGateFixture.edit("t2", path: edited),
            StopGateFixture.result("t2"),
        ])

        let reason = try #require(try await StopGateFixture.blockReason(of: fixture.hook(["transcript_path": transcript])))

        #expect(reason.contains("`(cd \(CanonicalPath.of(fixture.repo.path))/app && sift run -- xcodebuild -scheme Gizmo build)` and"))
    }

    @Test
    func aPushdLeavesNoBuildNamed() async throws {
        let fixture = try StopGateFixture(package: false, neutralPath: true)
        let edited = try fixture.file("app/A.swift")
        let transcript = try fixture.transcript([
            StopGateFixture.bash("t1", command: "pushd app && sift run -- xcodebuild -scheme Gizmo build", cwd: fixture.repo.path),
            StopGateFixture.result("t1", failed: true),
            StopGateFixture.edit("t2", path: edited),
            StopGateFixture.result("t2"),
        ])

        let printed = await fixture.hook(["transcript_path": transcript])

        #expect(try StopGateFixture.blockReason(of: printed) == nil)
    }
}
