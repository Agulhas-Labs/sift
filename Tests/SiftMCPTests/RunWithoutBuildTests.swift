//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// Covers `sift run --without` around the store and the build it makes: nothing deletes the store while a run holds the tree, and the run without the change builds in its own directory.
@Suite(.temporaryDirectories)
struct RunWithoutBuildTests {
    typealias Fixture = RunWithoutCommandTests.Fixture
    typealias SwiftPMFixture = RunWithoutCommandTests.SwiftPMFixture
    typealias Racer = RunWithoutCommandTests.Racer

    // MARK: - Nothing deletes the store while a run holds the tree, and nothing is left in it

    /// `sift reset` refuses while a run holds the tree — in its second pass too, when no record stands — in the words a busy run is refused in, and deletes nothing.
    @Test
    func resetRefusesWhileARunHoldsTheTreeInItsSecondPass() throws {
        let fixture = try Fixture()
        let before = try fixture.snapshot()
        let proceed = fixture.beside("go-with")
        let marker = fixture.beside("hold-with")
        let first = try fixture.launch(Fixture.proof, marker: marker, environment: ["SIFT_HOLD_PASS": "with", "SIFT_HOLD_UNTIL": proceed.path])
        try fixture.wait("the first run's second pass") { FileManager.default.fileExists(atPath: marker.path) }

        let reset = try fixture.sift(["reset"])
        let lockStood = FileManager.default.fileExists(atPath: SetAsideStore(repositoryRoot: fixture.root).lockURL.path)
        FileManager.default.createFile(atPath: proceed.path, contents: Data())
        let finished = try first.finish()

        #expect(reset.status != 0, "\(reset.stdout)")
        #expect(reset.stderr.contains("is running its tests again with the changes back in place"), "\(reset.stderr)")
        #expect(lockStood, "reset deleted the lock the run holds")
        #expect(finished.status == 0, "\(finished.stdout)\(finished.stderr)")
        #expect(try fixture.snapshot() == before)
    }

    /// An interruption while a large set of changes is still being recorded ends the run as a signalled process would, with nothing set aside and no copy of anything left in the store.
    @Test
    func anInterruptionWhileTheChangesAreRecordedLeavesNoCopies() throws {
        let fixture = try Fixture()
        for number in 0 ..< 3000 {
            try fixture.write("\(number)\n", to: "Sources/untracked/\(number).txt")
        }
        let before = try fixture.snapshot()
        let store = SetAsideStore(repositoryRoot: fixture.root)
        let copies = store.directory.appendingPathComponent("copies").path
        let running = try fixture.launch(Fixture.proof)
        try fixture.wait("the copies starting", upTo: 60) { !Racer.names(in: copies).isEmpty }

        kill(running.process.processIdentifier, SIGINT)
        let result = try running.finish()

        #expect(result.status == 128 + SIGINT, "\(result.stderr)")
        #expect(!FileManager.default.fileExists(atPath: store.directory.path), "copies were left in the store")
        #expect(try fixture.snapshot() == before)
    }

    /// A plain run asks git for the repository's root once, however many parts of it need the root.
    @Test
    func aPlainRunAsksGitForTheRootOnce() throws {
        let fixture = try Fixture()
        let home = fixture.beside("home")
        let trace = fixture.beside("trace")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // git's configuration keys are read without regard to case.
        try "[trace2]\n\tnormaltarget = \(trace.path)\n".write(to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)

        let result = try fixture.sift(["run", "--", "true"], environment: ["HOME": home.path])

        #expect(result.status == 0, "\(result.stderr)")
        let lines = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n")
        let asked = lines.filter { $0.contains(" start ") && $0.contains("rev-parse --show-toplevel") }
        #expect(asked.count == 1, "\(asked)")
    }

    // MARK: - Where the run without the change builds

    /// The run without the change builds in a directory of its own, never where the caller's builds do, and — kept with `--keep-without-build` — builds on it again only after a build that reached its tests.
    @Test
    func theRunWithoutTheChangeBuildsApartAndOnlyOnABuildThatFinished() throws {
        let fixture = try Fixture()
        let builds = ["SIFT_TEST_BUILDS": "1"]
        let own = ".sift/without-build/swiftpm/built"
        let keeping = ["run", "--without", "Sources/", "--keep-without-build", "--", "swift", "test", "--filter", "WidgetTests"]

        let first = try fixture.sift(keeping, environment: builds)
        #expect(first.status == 0, "\(first.stdout)\(first.stderr)")
        #expect(fixture.contents(of: ".build/built") == "with\n", "only the run with the change builds where the caller's builds do")
        #expect(fixture.contents(of: own) == "without\n")

        #expect(try fixture.sift(keeping, environment: builds).status == 0)
        #expect(fixture.contents(of: own) == "without\nwithout\n", "a build that reached its tests is built on")

        let silent = try fixture.sift(keeping, environment: builds.merging(["SIFT_TEST_SILENT": "1"]) { _, new in new })
        #expect(silent.status == 1, "\(silent.stdout)")
        #expect(try fixture.sift(keeping, environment: builds).status == 0)
        #expect(fixture.contents(of: own) == "without\n", "a build that never reached its tests is started afresh")
    }

    /// Over a real SwiftPM package: nothing in the build directory the caller's builds use was written while the change was out of the tree, so the next build there has nothing compiled without the change to trust.
    ///
    /// The change is inside a function body, so the run with it recompiles only the file it is in. Built where the caller builds, the test target's objects from the run without it would still be there afterwards, dated before the restore — the kind of object a build that stopped part-way leaves unrecorded, and the next build links against the restored tree.
    @Test
    func nothingBuiltWithoutTheChangeIsLeftWhereTheNextBuildLooks() throws {
        let package = try SwiftPMFixture()
        let started = try package.stamp()

        let result = try package.sift(["run", "--without", "Sources", "--", "swift", "test", "--filter", "WidgetTests"])

        #expect(result.status == 0, "\(result.stdout)\(result.stderr)")
        let restored = try SwiftPMFixture.modified(package.root.appendingPathComponent("Sources/Widget/Widget.swift"))
        let builtWhileOut = try package.files(under: ".build").filter { started <= $0.modified && $0.modified < restored }.map(\.path)
        #expect(builtWhileOut.isEmpty, "written into .build while the change was set aside: \(builtWhileOut.prefix(5))")
    }

    /// Both runs are handed the repository's URL rewrites alike, so the change is the only thing that differs between them: a test running git against a rewritten URL cannot fail without the change for want of a rewrite alone.
    @Test
    func bothRunsAreGivenTheSameGitConfiguration() throws {
        let fixture = try Fixture()
        try fixture.git(["config", "--local", "url.git@example.com:acme/.insteadof", "https://example.com/acme/"])
        let seen = fixture.beside("git-config")

        let result = try fixture.sift(Fixture.proof, environment: ["SIFT_TEST_GIT_CONFIG": seen.path])

        #expect(result.status == 0, "\(result.stdout)\(result.stderr)")
        let passes = try String(contentsOf: seen, encoding: .utf8).split(separator: "\n").map { $0.split(separator: " ", maxSplits: 1).map(String.init) }
        try #require(passes.count == 2, "\(passes)")
        #expect(passes.map(\.first) == ["without", "with"])
        #expect(passes[0].last?.contains("GIT_CONFIG_KEY_0=url.git@example.com:acme/.insteadof") == true, "\(passes[0])")
        #expect(passes[0].last == passes[1].last, "the run with the change was given other git configuration than the run without it")
    }

    /// A run without the change that could not fetch a dependency is answered in one line and ends there: nothing was proven, so the run with the change is not made, and the partial fetch left in the build directory is removed.
    ///
    /// The answer still carries the set-aside receipt and where the one run's raw log is — the same lines the ordinary answer would give, not dropped for having stopped early.
    @Test
    func aRunThatCouldNotFetchItsDependenciesEndsInOneLineWithItsBuildRemoved() throws {
        let fixture = try Fixture()
        let before = try fixture.snapshot()
        let seen = fixture.beside("git-config")

        let result = try fixture.sift(Fixture.proof, environment: ["SIFT_TEST_BUILDS": "1", "SIFT_TEST_UNRESOLVED": "1", "SIFT_TEST_GIT_CONFIG": seen.path])

        #expect(result.status == 1, "\(result.stdout)\(result.stderr)")
        #expect(result.stdout.hasPrefix("✘ could not build without Sources/: dependency resolution failed — nothing was proven (Failed to clone repository https://example.com/acme/Widget.git:)\n"), "\(result.stdout)")
        #expect(result.stdout.contains("  set aside and put back: 3 paths under Sources/ (1 with staged changes, 1 with unstaged changes, 1 untracked), checked by content hash"), "\(result.stdout)")
        #expect(result.stdout.contains("  raw output at "), "\(result.stdout)")
        #expect(result.stdout.contains(" (without Sources/)"), "\(result.stdout)")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".sift/without-build/swiftpm").path), "the build directory the fetch failed in is removed")
        #expect(fixture.contents(of: ".build/built") == nil, "no run with the change was made")
        #expect(try String(contentsOf: seen, encoding: .utf8) == "without\n", "no run with the change was made")
        #expect(try fixture.snapshot() == before)
        #expect(!fixture.recordExists)
    }
}
