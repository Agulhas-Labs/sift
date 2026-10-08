//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// Covers `sift run --without` removing the build it made without the change once the changes are back, leaving it while they are not, and keeping it only when `--keep-without-build` asks.
@Suite(.temporaryDirectories)
struct RunWithoutBuildCleanupTests {
    typealias Fixture = RunWithoutCommandTests.Fixture

    /// The build directory the run without the change used, relative to the fixture's root.
    private static var own: String {
        ".sift/without-build/swiftpm"
    }

    /// What every run here is given: a stand-in that builds into its scratch path, and a Claude configuration directory with nothing in it.
    private static func environment(_ extra: [String: String] = [:]) throws -> [String: String] {
        let configuration = try TemporaryDirectory.make("claude-config")
        return ["SIFT_TEST_BUILDS": "1", "CLAUDE_CONFIG_DIR": configuration.path].merging(extra) { _, new in new }
    }

    /// A proof, a test that passes either way, and a run that names no test each end with the build gone, its mark with it, and the receipt saying so.
    @Test(arguments: [
        ("a proof", [:], Int32(0)),
        ("a test that passes either way", ["SIFT_TEST_ALWAYS_PASSES": "1"], Int32(1)),
        ("a run that reports no test", ["SIFT_TEST_SILENT": "1"], Int32(1)),
    ])
    func everyAnsweredRunRemovesTheBuild(_ name: String, _ extra: [String: String], _ status: Int32) throws {
        let fixture = try Fixture()

        let result = try fixture.sift(Fixture.proof, environment: Self.environment(extra))

        #expect(result.status == status, "\(name): \(result.stdout)\(result.stderr)")
        #expect(fixture.contents(of: ".build/built") == "with\n", "\(name): the run with the change ran")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(Self.own).path), "\(name): the build was left")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("\(Self.own).finished").path), "\(name): its mark was left")
        #expect(result.stdout.contains("; built without the change in a scratch build ("), "\(name): \(result.stdout)")
        #expect(result.stdout.contains("removed)"), "\(name): \(result.stdout)")
        #expect(!result.stdout.contains("rm -rf"), "\(name): \(result.stdout)")
    }

    /// A run whose build without the change failed removes what that build wrote too.
    @Test
    func aBuildThatFailedWithoutTheChangeIsRemoved() throws {
        let fixture = try Fixture()
        let failing = """
        #!/bin/sh
        scratch=.build; named=
        for argument in "$@"; do
            if [ -n "$named" ]; then scratch=$argument; named=; fi
            case "$argument" in --scratch-path) named=1 ;; esac
        done
        mkdir -p "$scratch" && echo built >> "$scratch/built"
        if grep -q fixed Sources/feature.txt; then
            printf 'Test shoutingWorks() passed after 0.001 seconds.\\n'
            printf 'Test run with 1 test in 1 suite passed after 0.001 seconds.\\n'
            exit 0
        fi
        printf '%s/Sources/Widget.swift:3:5: error: cannot find value in scope\\n' "$PWD"
        exit 1

        """
        try failing.write(to: fixture.bin.appendingPathComponent("swift"), atomically: true, encoding: .utf8)

        let result = try fixture.sift(Fixture.proof, environment: Self.environment())

        #expect(result.status == 1, "\(result.stdout)\(result.stderr)")
        #expect(fixture.contents(of: ".build/built") == "built\n", "the run with the change ran")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(Self.own).path), "\(result.stdout)")
    }

    /// A run that exits with the changes not back — another git holding the index — removes nothing: the build is left, said to be, and cleared by the next run rather than built on.
    @Test
    func aRunThatLeavesTheChangesOutLeavesTheBuild() throws {
        let fixture = try Fixture()
        let before = try fixture.snapshot()

        let result = try fixture.sift(Fixture.proof, environment: Self.environment(["SIFT_TEST_HOOK": "touch .git/index.lock"]))

        #expect(result.status == 3, "\(result.stderr)")
        #expect(fixture.contents(of: "\(Self.own)/built") == "without\n", "removed while the changes were out of the tree")
        #expect(result.stderr.contains("the build without the change was left at \(Self.own)"), "\(result.stderr)")
        try fixture.wait("the watcher letting go", upTo: 60) {
            if case .unrestored? = SetAsideSession.refusal(for: fixture.root) {
                return true
            }
            return false
        }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(".git/index.lock"))
        #expect(try fixture.sift(["run", "--restore"]).status == 0)
        #expect(try fixture.snapshot() == before)
        let keeping = ["run", "--without", "Sources/", "--keep-without-build", "--", "swift", "test", "--filter", "WidgetTests"]

        let next = try fixture.sift(keeping, environment: Self.environment())

        #expect(next.status == 0, "\(next.stdout)\(next.stderr)")
        #expect(fixture.contents(of: "\(Self.own)/built") == "without\n", "the next run built on what was left rather than clearing it")
    }

    /// With `--keep-without-build` the build stays, marked to be built on, and the receipt names it and how to remove it.
    @Test
    func keepingTheBuildLeavesItAndSaysHowToRemoveIt() throws {
        let fixture = try Fixture()
        let keeping = ["run", "--without", "Sources/", "--keep-without-build", "--", "swift", "test", "--filter", "WidgetTests"]

        let result = try fixture.sift(keeping, environment: Self.environment())

        #expect(result.status == 0, "\(result.stdout)\(result.stderr)")
        #expect(fixture.contents(of: "\(Self.own)/built") == "without\n")
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("\(Self.own).finished").path))
        #expect(result.stdout.contains("; the run without the change built in \(Self.own) ("), "\(result.stdout)")
        #expect(result.stdout.contains("remove it any time with `rm -rf \(Self.own)`"), "\(result.stdout)")
    }

    /// `--keep-without-build` with no set-aside to keep a build for is refused as a usage error.
    @Test
    func keepingTheBuildWithoutASetAsideIsRefused() throws {
        let fixture = try Fixture()

        let result = try fixture.sift(["run", "--keep-without-build", "--", "true"], environment: Self.environment())

        #expect(result.status == 64, "\(result.stdout)\(result.stderr)")
        #expect(result.stderr.contains("sift run --keep-without-build goes with --without or --without-line"), "\(result.stderr)")
    }

    /// `--keep-without-build` beside a set-aside is still refused with `--restore` or `--proved`, which build nothing to keep.
    @Test(arguments: ["--restore", "--proved"])
    func keepingTheBuildWithRestoreOrProvedIsRefused(_ flag: String) throws {
        let fixture = try Fixture()

        let result = try fixture.sift(["run", "--without", "Sources/", "--keep-without-build", flag, "--", "swift", "test"], environment: Self.environment())

        #expect(result.status == 64, "\(flag): \(result.stdout)\(result.stderr)")
        #expect(result.stderr.contains("sift run --keep-without-build goes with --without or --without-line, and with no --restore or --proved"), "\(flag): \(result.stderr)")
    }

    /// A run whose command built nothing without the change says nothing about a scratch build: there was none to remove.
    @Test
    func aRunThatBuiltNothingSaysNothingAboutABuild() throws {
        let fixture = try Fixture()

        let result = try fixture.sift(Fixture.proof, environment: ["CLAUDE_CONFIG_DIR": TemporaryDirectory.make("claude-config").path])

        #expect(result.status == 0, "\(result.stdout)\(result.stderr)")
        #expect(!result.stdout.contains("scratch build"), "\(result.stdout)")
        #expect(!result.stdout.contains("without-build"), "\(result.stdout)")
    }

    /// `.sift/without-build` linked elsewhere is refused before anything is set aside, naming the link, and nothing is removed or built there.
    @Test
    func aLinkedBuildPlaceIsRefusedBeforeTheSetAside() throws {
        let fixture = try Fixture()
        let elsewhere = try TemporaryDirectory.make("link-target")
        try Data("precious".utf8).write(to: elsewhere.appendingPathComponent("sentinel"))
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent(".sift"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent(".sift/without-build").path, withDestinationPath: elsewhere.path)
        // `.sift/` is the run's own, and the ignore file it writes there hides the link from git: the tree is the rest.
        let tree = { try fixture.snapshot().split(separator: "\n").filter { !$0.contains(SiftPaths.directoryName) } }
        let before = try tree()

        let result = try fixture.sift(Fixture.proof, environment: Self.environment())

        #expect(result.status == 2, "\(result.stdout)\(result.stderr)")
        #expect(result.stderr.contains(".sift/without-build is a symbolic link"), "\(result.stderr)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path) == ["sentinel"], "built or removed through the link")
        #expect(fixture.contents(of: ".build/built") == nil, "a command ran")
        #expect(try tree() == before)
    }
}
