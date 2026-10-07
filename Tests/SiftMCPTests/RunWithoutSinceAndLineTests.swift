//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// Covers `--since`, which sets aside the change a commit made, and `--without-line`, which comments out one guarding line.
@Suite(.temporaryDirectories)
struct RunWithoutSinceAndLineTests {
    typealias Fixture = RunWithoutCommandTests.Fixture

    /// A committed fix is proven by setting it aside to the commit before it: the test fails without it, passes with it, and the tree comes back exactly as it was.
    @Test
    func aCommittedChangeIsSetAsideToTheRevisionBeforeItAndProvesTheTest() throws {
        let fixture = try Fixture()
        try fixture.commit(["Sources/feature.txt": "fixed\n"])
        let before = try fixture.snapshot()

        let result = try fixture.sift(Self.sinceProof)

        #expect(result.status == 0, "\(result.stdout)\(result.stderr)")
        #expect(result.stdout.hasPrefix("✔ 1 of 1 fails without Sources/feature.txt and passes with it\n"), "\(result.stdout)")
        #expect(result.stdout.contains("  ✔ shoutingWorks() — fails without Sources/feature.txt, passes with it"))
        #expect(try fixture.snapshot() == before)
        #expect(!fixture.recordExists)
    }

    /// A working tree with anything uncommitted under the pathspec refuses: the two sources are never set aside together, and the refusal names the path rather than falling back to it.
    @Test
    func aSinceRunRefusesATreeThatIsNotCleanUnderThePathspec() throws {
        let fixture = try Fixture()
        try fixture.commit(["Sources/feature.txt": "fixed\n"])
        try fixture.write("fixed, and edited again\n", to: "Sources/feature.txt")
        let before = try fixture.snapshot()

        let result = try fixture.sift(Self.sinceProof)

        #expect(result.status == 2)
        #expect(result.stderr.contains("Sources/feature.txt has uncommitted changes — Sources/feature.txt"), "\(result.stderr)")
        #expect(try fixture.snapshot() == before)
        #expect(!FileManager.default.fileExists(atPath: SetAsideStore(repositoryRoot: fixture.root).directory.path))
    }

    /// A revision git cannot resolve is refused before anything is recorded and before the lock is taken.
    @Test
    func aRevisionGitCannotResolveIsRefusedBeforeAnythingIsRecorded() throws {
        let fixture = try Fixture()
        let before = try fixture.snapshot()

        let result = try fixture.sift(["run", "--without", "Sources/", "--since", "no-such-revision", "--", "swift", "test", "--filter", "WidgetTests"])

        #expect(result.status == 64)
        #expect(result.stderr.contains("git cannot resolve `no-such-revision` to a commit"), "\(result.stderr)")
        #expect(try fixture.snapshot() == before)
        #expect(!FileManager.default.fileExists(atPath: SetAsideStore(repositoryRoot: fixture.root).directory.path))
    }

    /// A revision HEAD does not descend from is refused before anything is recorded: `git diff <rev> HEAD` is a two-point diff, so naming one would set aside the reverse of somebody else's work rather than "what the commits since it changed".
    @Test
    func aRevisionThatIsNotAnAncestorIsRefusedBeforeAnythingIsRecorded() throws {
        let fixture = try Fixture(otherBranch: true)
        let before = try fixture.snapshot()

        let result = try fixture.sift(["run", "--without", "Sources/", "--since", "other", "--", "swift", "test", "--filter", "WidgetTests"])

        #expect(result.status == 64)
        #expect(result.stderr.contains("`other` is not an ancestor of HEAD"), "\(result.stderr)")
        #expect(try fixture.snapshot() == before)
        #expect(!FileManager.default.fileExists(atPath: SetAsideStore(repositoryRoot: fixture.root).directory.path))
    }

    /// `--since` with no pathspec to read it against says which flag it needs, and runs nothing.
    @Test
    func aRevisionWithNoPathspecSaysWhichFlagItNeeds() throws {
        let fixture = try Fixture()

        let result = try fixture.sift(["run", "--since", "HEAD~1", "--", "swift", "test", "--filter", "WidgetTests"])

        #expect(result.status == 64)
        #expect(result.stderr.contains("--without <pathspec>"), "\(result.stderr)")
        #expect(!FileManager.default.fileExists(atPath: fixture.runLog.path), "nothing ran")
    }

    /// A `--since` run interrupted mid-flight puts the committed change back, exactly as one set aside from the working tree is put back.
    @Test
    func aSinceRunInterruptedMidFlightPutsTheCommittedChangeBack() throws {
        let fixture = try Fixture()
        try fixture.commit(["Sources/feature.txt": "fixed\n"])
        let before = try fixture.snapshot()
        let running = try fixture.launch(Self.sinceProof, marker: fixture.beside("hold-since"))

        let testsSaw = try running.waitUntilTheTestsAreRunning()
        #expect(testsSaw == "broken\n", "the tests ran against the tree with the committed change set aside")
        kill(running.process.processIdentifier, SIGINT)
        let result = try running.finish()

        #expect(result.status == 128 + SIGINT)
        #expect(result.stderr.contains("interrupted by signal \(SIGINT)"), "\(result.stderr)")
        #expect(try fixture.snapshot() == before)
        #expect(!fixture.recordExists)
    }

    /// The proof run every test here makes against a change that is already committed.
    static let sinceProof = ["run", "--without", "Sources/feature.txt", "--since", "HEAD~1", "--", "swift", "test", "--filter", "WidgetTests"]

    /// One line commented out proves the test that needs it — failing without it, passing with it back — and the file comes back byte for byte, with nothing else in the tree touched.
    @Test
    func aLineCommentedOutProvesTheTestAndTheFileComesBackByteForByte() throws {
        let fixture = try Fixture()
        try fixture.commit([Self.guarded: Self.guardedSource])
        let before = try fixture.snapshot()

        let result = try fixture.sift(Self.lineProof, environment: ["SIFT_TEST_PROBE": Self.guarded])

        #expect(result.status == 0, "\(result.stdout)\(result.stderr)")
        #expect(result.stdout.hasPrefix("✔ 1 of 1 fails without Sources/Widget.swift:3 and passes with it\n"), "\(result.stdout)")
        #expect(result.stdout.contains("  set aside: Sources/Widget.swift:3 — \"\"fixed\"\" (commented out for the run without the change)"), "\(result.stdout)")
        #expect(result.stdout.contains("with Sources/Widget.swift:3 back — "), "\(result.stdout)")
        #expect(try fixture.snapshot() == before)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent(Self.guarded)) == Data(Self.guardedSource.utf8))
        #expect(!fixture.recordExists)
    }

    /// A run killed while its tests see the line commented out puts the line back before the process goes.
    @Test
    func aLineRunInterruptedMidFlightPutsTheLineBack() throws {
        let fixture = try Fixture()
        try fixture.commit([Self.guarded: Self.guardedSource])
        let before = try fixture.snapshot()
        let running = try fixture.launch(Self.lineProof, marker: fixture.beside("hold-line"), environment: ["SIFT_TEST_PROBE": Self.guarded])

        let testsSaw = try running.waitUntilTheTestsAreRunning()
        #expect(testsSaw.contains("        // \"fixed\"\n"), "the tests ran against the file with its line commented out: \(testsSaw)")
        kill(running.process.processIdentifier, SIGTERM)
        let result = try running.finish()

        #expect(result.status == 128 + SIGTERM)
        #expect(result.stderr.contains("interrupted by signal \(SIGTERM)"), "\(result.stderr)")
        #expect(try fixture.snapshot() == before)
        #expect(!fixture.recordExists)
    }

    /// A line named without its number, or beside a flag it cannot share a run with, is refused as a usage error, and a file that is not Swift is refused as a set-aside — each before anything is recorded or run.
    @Test
    func aLineThatCannotBeSetAsideIsRefusedBeforeAnythingMoves() throws {
        let fixture = try Fixture()
        try fixture.commit([Self.guarded: Self.guardedSource])
        let before = try fixture.snapshot()
        let tests = ["--", "swift", "test", "--filter", "WidgetTests"]
        let usage: [([String], String)] = [
            (["--without-line", Self.guarded], "takes <file>:<line>"),
            (["--without-line", "\(Self.guarded):three"], "takes <file>:<line>"),
            (["--without-line", ":3"], "takes <file>:<line>"),
            (["--without-line", "\(Self.guarded):3", "--without", "Sources/"], "takes no --without"),
            (["--without-line", "\(Self.guarded):3", "--since", "HEAD"], "takes no --without"),
            (["--without-line", "\(Self.guarded):3", "--proved"], "takes no --without"),
        ]

        for (flags, says) in usage {
            let result = try fixture.sift(["run"] + flags + tests)
            #expect(result.status == 64, "\(flags): \(result.stderr)")
            #expect(result.stderr.contains(says), "\(flags): \(result.stderr)")
        }
        let restore = try fixture.sift(["run", "--without-line", "\(Self.guarded):3", "--restore"])
        let notSwift = try fixture.sift(["run", "--without-line", "Sources/feature.txt:1"] + tests)

        #expect(restore.status == 64, "\(restore.stderr)")
        #expect(notSwift.status == 2, "\(notSwift.stderr)")
        #expect(notSwift.stderr.contains("Sources/feature.txt"), "\(notSwift.stderr)")
        #expect(notSwift.stderr.contains("sift run --without-line: refusing to set aside"), "\(notSwift.stderr)")
        #expect(!notSwift.stderr.contains("sift run --without:"), "\(notSwift.stderr)")
        #expect(try fixture.snapshot() == before)
        #expect(!fixture.recordExists)
        #expect(!FileManager.default.fileExists(atPath: fixture.runLog.path), "nothing ran")
    }

    /// The Swift file the line tests set a line of aside.
    static var guarded: String {
        "Sources/Widget.swift"
    }

    /// What that file holds: its third line is the `"fixed"` the stand-in's test needs.
    static var guardedSource: String {
        "struct Widget {\n    var state: String {\n        \"fixed\"\n    }\n}\n"
    }

    /// The proof run the line tests make, commenting out the guarding line.
    static let lineProof = ["run", "--without-line", "Sources/Widget.swift:3", "--", "swift", "test", "--filter", "WidgetTests"]
}
