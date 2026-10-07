//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// Covers `sift run --without` from outside the process, which is the only place its promise can be checked: whatever ends the run — the tests finishing, a signal, the process killed outright — the working tree comes back exactly as it was.
///
/// Every test drives the built binary against a throwaway repository, with a stand-in `swift` first on `PATH` that reads the tree the way a real test would, so what is proved is what the command does rather than what a type does in isolation. `SIFT_RUN_LOG` points the per-user run log at a temporary file, so none of this is ever filed as a run of anybody's code.
@Suite(.temporaryDirectories)
struct RunWithoutCommandTests {
    /// A proof run answers test by test, exits with the second run's code, files only that second run, and leaves the index, the files and the untracked files exactly as it found them.
    @Test
    func aProofRunAnswersTestByTestAndLeavesTheTreeExactlyAsItWas() throws {
        let fixture = try Fixture()
        let before = try fixture.snapshot()

        let result = try fixture.sift(["run", "--without", "Sources/", "--", "swift", "test", "--filter", "WidgetTests"])

        #expect(result.status == 0)
        #expect(result.stdout.hasPrefix("✔ 1 of 1 fails without Sources/ and passes with it\n"), "\(result.stdout)")
        #expect(result.stdout.contains("  ✔ shoutingWorks() — fails without Sources/, passes with it"))
        #expect(result.stdout.contains("(1 with staged changes, 1 with unstaged changes, 1 untracked), checked by content hash"))
        #expect(try fixture.snapshot() == before)
        #expect(!fixture.recordExists)
        let filed = try String(contentsOf: fixture.runLog, encoding: .utf8).split(separator: "\n")
        #expect(filed.count == 1, "only the run with the change is filed")
    }

    /// Each signal that ends a run puts the tree back before the process goes, and the process leaves as a signalled one would.
    @Test(arguments: [SIGINT, SIGTERM, SIGHUP])
    func aSignalMidRunPutsTheTreeBackBeforeExiting(_ number: Int32) throws {
        let fixture = try Fixture()
        let before = try fixture.snapshot()
        let running = try fixture.launch(holdingAt: "without")

        let testsSaw = try running.waitUntilTheTestsAreRunning()
        #expect(testsSaw == "broken\n", "the tests ran against the tree with the change set aside")
        kill(running.process.processIdentifier, number)
        let result = try running.finish()

        #expect(result.status == 128 + number)
        #expect(result.stderr.contains("interrupted by signal \(number)"), "\(result.stderr)")
        #expect(try fixture.snapshot() == before)
        #expect(!fixture.recordExists)
    }

    /// Killed outright — the one ending no handler inside the process can see, and what a crash looks like from outside it — the watcher puts the tree back.
    @Test
    func beingKilledOutrightLeavesTheWatcherToPutTheTreeBack() throws {
        let fixture = try Fixture()
        let before = try fixture.snapshot()
        let running = try fixture.launch(holdingAt: "without")

        _ = try running.waitUntilTheTestsAreRunning()
        kill(running.process.processIdentifier, SIGKILL)
        _ = try running.finish()
        running.stopTheStandIn()

        let deadline = Date().addingTimeInterval(30)
        while fixture.recordExists, Date() < deadline {
            usleep(50000)
        }

        #expect(!fixture.recordExists, "the watcher never restored the tree after its owner was killed")
        #expect(try fixture.snapshot() == before)
    }

    /// While a set-aside is out of the tree, every run refuses and names the restore — and the restore puts every byte back.
    @Test
    func everyRunRefusesWhileARecordStandsAndTheRestorePutsItBack() throws {
        let fixture = try Fixture()
        let before = try fixture.snapshot()
        // What a run leaves when it and its watcher were both killed: a record, the tree set aside, no lock.
        let store = SetAsideStore(repositoryRoot: fixture.root)
        let record = try SetAside.capture(pathspecs: ["Sources/"], from: fixture.root, into: store)
        guard case .setAside = try SetAside(store: store).setAside(record) else {
            Issue.record("the set-aside stopped part-way")
            return
        }

        let refused = try fixture.sift(["run", "--", "swift", "test", "--filter", "WidgetTests"])

        #expect(refused.status == 1)
        #expect(refused.stderr.contains("refusing to start"), "\(refused.stderr)")
        #expect(refused.stderr.contains("sift run --restore"))
        #expect(fixture.recordExists)

        let restored = try fixture.sift(["run", "--restore"])

        #expect(restored.status == 0)
        #expect(restored.stdout.contains("put back 3 paths under Sources/"), "\(restored.stdout)")
        #expect(try fixture.snapshot() == before)
        #expect(!fixture.recordExists)
    }

    /// Killed while a slow smudge filter is still producing HEAD's version of a file: the watcher ends everything the run started before it restores, so nothing is left to write into the tree afterwards.
    @Test
    func beingKilledDuringASlowSetAsideLeavesNothingWritingAfterTheRestore() throws {
        let fixture = try Fixture(slowSmudge: true)
        let before = try fixture.snapshot()
        let running = try fixture.launch(Fixture.proof)

        try fixture.wait("the smudge filter starting") { FileManager.default.fileExists(atPath: fixture.smudging.path) }
        kill(running.process.processIdentifier, SIGKILL)
        _ = try running.finish()
        try fixture.wait("the watcher putting the tree back") { !fixture.recordExists }
        // Past the moment the smudge filter would have finished, and anything waiting on it written.
        sleep(4)

        #expect(try fixture.snapshot() == before)
    }

    /// Killed while the tests run, with a writer they left in the background: the watcher ends it before restoring, so it never writes into the tree it put back.
    @Test
    func beingKilledWhileATestLeftAWriterRunningEndsTheWriterBeforeTheRestore() throws {
        let fixture = try Fixture()
        let before = try fixture.snapshot()
        let running = try fixture.launch(holdingAt: "orphan", environment: fixture.leavingAWriter)

        _ = try running.waitUntilTheTestsAreRunning()
        kill(running.process.processIdentifier, SIGKILL)
        _ = try running.finish()
        try fixture.wait("the watcher putting the tree back") { !fixture.recordExists }
        try fixture.waitForTheWriterToEnd()

        #expect(try fixture.snapshot() == before)
    }

    /// A writer the run without the change left running is ended before the changes go back, and the answer says so.
    @Test
    func aWriterTheFirstRunLeftBehindIsEndedBeforeTheChangesGoBack() throws {
        let fixture = try Fixture()
        let before = try fixture.snapshot()

        let result = try fixture.sift(Fixture.proof, environment: fixture.leavingAWriter)
        try fixture.waitForTheWriterToEnd()

        #expect(result.status == 0, "\(result.stdout)\(result.stderr)")
        #expect(result.stdout.contains("the run without Sources/ left running, before putting the changes back"), "\(result.stdout)")
        #expect(try fixture.snapshot() == before)
    }

    /// A file written between being recorded and being set aside stops the run before any test: the write stays as its writer left it, and everything else is exactly as it was.
    @Test
    func aFileWrittenWhileTheTreeIsBeingSetAsideStopsTheRunAndKeepsTheWrite() throws {
        let fixture = try Fixture(slowSmudge: true)
        let running = try fixture.launch(Fixture.proof)
        try fixture.wait("the smudge filter starting") { FileManager.default.fileExists(atPath: fixture.smudging.path) }
        try "written while the tree was being set aside\n".write(
            to: fixture.root.appendingPathComponent("Sources/new/untracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        let withTheWrite = try fixture.snapshot()

        let result = try running.finish()

        #expect(result.status == 2, "\(result.stderr)")
        #expect(result.stderr.contains("the working tree changed while it was being set aside"), "\(result.stderr)")
        #expect(result.stderr.contains("Sources/new/untracked.txt was written after it was recorded"))
        #expect(try fixture.snapshot() == withTheWrite)
        #expect(!fixture.recordExists)
    }

    /// A second `run --without` started while the first runs its tests with the changes back is refused, and the first run's answer is its own.
    @Test
    func aSecondRunIsRefusedWhileTheFirstRunsItsSecondPass() throws {
        let fixture = try Fixture()
        let before = try fixture.snapshot()
        let marker = fixture.root.deletingLastPathComponent().appendingPathComponent("hold-with")
        let first = try fixture.launch(Fixture.proof, marker: marker, environment: ["SIFT_HOLD_PASS": "with", "SIFT_HOLD_SECONDS": "3"])
        try fixture.wait("the first run's second pass") { FileManager.default.fileExists(atPath: marker.path) }

        let second = try fixture.sift(Fixture.proof)
        let finished = try first.finish()

        #expect(second.status == 2, "\(second.stdout)\(second.stderr)")
        #expect(second.stderr.contains("is running its tests again with the changes back in place"), "\(second.stderr)")
        #expect(finished.status == 0, "\(finished.stdout)")
        #expect(finished.stdout.hasPrefix("✔ 1 of 1 fails without Sources/ and passes with it"), "\(finished.stdout)")
        #expect(try fixture.snapshot() == before)
    }

    /// A restore stopped by another git's index lock says the work is not back, how to get it back, and exits with the code of its own; once the lock is gone, `--restore` puts every byte back.
    @Test
    func aRestoreStoppedByTheIndexLockSaysSoAndExitsWithItsOwnCode() throws {
        let fixture = try Fixture()
        let before = try fixture.snapshot()

        let result = try fixture.sift(Fixture.proof, environment: ["SIFT_TEST_HOOK": "touch .git/index.lock"])

        #expect(result.status == 3, "\(result.stderr)")
        #expect(result.stderr.contains("are NOT back in the working tree"), "\(result.stderr)")
        #expect(result.stderr.contains("Nothing has been deleted"))
        #expect(result.stderr.contains("`sift run --restore`"))
        #expect(!result.stderr.contains(fixture.root.path), "an absolute path in the answer: \(result.stderr)")
        // The watcher tries again once the run is gone, and gives up while the lock is still there.
        try fixture.wait("the watcher letting go", upTo: 60) {
            if case .unrestored? = SetAsideSession.refusal(for: fixture.root) {
                return true
            }
            return false
        }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(".git/index.lock"))

        let restored = try fixture.sift(["run", "--restore"])

        #expect(restored.status == 0, "\(restored.stderr)")
        #expect(try fixture.snapshot() == before)
    }

    /// HEAD moving while the changes are out puts the bytes and index entries back, keeps what the switch wrote, says HEAD moved and exits as not proven — and leaves no record to wedge the next run.
    @Test
    func aHeadThatMovedDuringTheRunIsReportedAndNothingIsWedged() throws {
        let fixture = try Fixture(otherBranch: true)
        let index = try fixture.index()

        let result = try fixture.sift(Fixture.proof, environment: ["SIFT_TEST_HOOK": "git checkout -q other"])

        #expect(result.status == 1, "\(result.stdout)\(result.stderr)")
        #expect(result.stdout.hasPrefix("⚠ HEAD moved from "), "\(result.stdout)")
        #expect(result.stdout.contains("kept rather than overwritten: Sources/feature.txt.sift-kept-"))
        #expect(try fixture.index() == index)
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("Sources/feature.txt"), encoding: .utf8) == "fixed\n")
        #expect(!fixture.recordExists)
        #expect(try fixture.sift(["run", "--", "swift", "test", "--filter", "WidgetTests"]).status == 0)
    }

    /// The exit code is the answer's: `0` only for a proof, `1` for runs that proved nothing, `2` for a refusal with nothing out of the tree, and `3` whenever somebody's work is not back.
    @Test
    func theExitCodeSaysWhetherItWasProvenAndWhetherTheWorkIsBack() throws {
        let fixture = try Fixture()

        #expect(try fixture.sift(Fixture.proof).status == 0)
        let pinsNothing = try fixture.sift(Fixture.proof, environment: ["SIFT_TEST_ALWAYS_PASSES": "1"])
        #expect(pinsNothing.status == 1, "\(pinsNothing.stdout)")
        // The fixture's change is under `Sources/` and never touches its test, so that test passing either way is
        // the expected case: counted into one line rather than named as pinning nothing.
        #expect(pinsNothing.stdout.contains("1 test the change does not touch passes without Sources/ too — expected, so it is not listed"), "\(pinsNothing.stdout)")
        let nothingRan = try fixture.sift(Fixture.proof, environment: ["SIFT_TEST_SILENT": "1"])
        #expect(nothingRan.status == 1, "\(nothingRan.stdout)")
        #expect(nothingRan.stdout.hasPrefix("⚠ neither run reported a test"))
        #expect(try fixture.sift(["run", "--without", "Nowhere/", "--", "swift", "test", "--filter", "WidgetTests"]).status == 2)

        let store = SetAsideStore(repositoryRoot: fixture.root)
        let record = try SetAside.capture(pathspecs: ["Sources/"], from: fixture.root, into: store)
        guard case .setAside = try SetAside(store: store).setAside(record) else {
            Issue.record("the set-aside stopped part-way")
            return
        }
        let overUnrestored = try fixture.sift(Fixture.proof)
        #expect(overUnrestored.status == 3, "\(overUnrestored.stderr)")
        #expect(try fixture.sift(["run", "--restore"]).status == 0)
    }

    /// A command that cannot prove anything is refused before a single file moves.
    @Test
    func anUnnamedTestRunIsRefusedBeforeAnythingMoves() throws {
        let fixture = try Fixture()
        let before = try fixture.snapshot()

        let result = try fixture.sift(["run", "--without", "Sources/", "--", "swift", "test"])

        #expect(result.status == 64)
        #expect(result.stderr.contains("--filter"), "\(result.stderr)")
        #expect(try fixture.snapshot() == before)
        #expect(!FileManager.default.fileExists(atPath: SetAsideStore(repositoryRoot: fixture.root).directory.path))
    }

    /// A build directory that cannot be cleared for the run without the change refuses before a single file moves: nothing is set aside, the guardian is released, and the exit code is a refusal's.
    @Test
    func aBuildDirectoryThatCannotBeClearedRefusesBeforeAnythingIsSetAside() throws {
        let fixture = try Fixture()
        let before = try fixture.snapshot()
        let withoutBuild = fixture.root.appendingPathComponent(".sift/without-build")
        try FileManager.default.createDirectory(at: withoutBuild.appendingPathComponent("swiftpm"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: withoutBuild.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: withoutBuild.path) }

        let result = try fixture.sift(Fixture.proof)

        #expect(result.status == 2, "\(result.stderr)")
        #expect(result.stderr.contains(".sift/without-build/swiftpm"), "\(result.stderr)")
        #expect(result.stderr.contains("could not be cleared for the run without the change, so nothing was set aside and nothing was run"), "\(result.stderr)")
        #expect(try fixture.snapshot() == before)
        #expect(!fixture.recordExists)
        #expect(try fixture.watcher() == nil, "nothing was set aside, so no watcher was armed to guard it")
    }

    /// The refusal names the build directory it could not clear from wherever the run started, as the receipt does: relative at the repository root, and by its whole path from a subdirectory, where the relative spelling would name a directory that does not exist.
    @Test
    func aBuildDirectoryThatCannotBeClearedIsNamedFromWhereTheRunStarted() throws {
        let fixture = try Fixture()
        let withoutBuild = fixture.root.appendingPathComponent(".sift/without-build")
        try FileManager.default.createDirectory(at: withoutBuild.appendingPathComponent("swiftpm"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: withoutBuild.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: withoutBuild.path) }

        let fromTheRoot = try fixture.sift(Fixture.proof)
        let fromASubdirectory = try fixture.sift(["run", "--without", ".", "--", "swift", "test", "--filter", "WidgetTests"], in: "Sources")

        #expect(fromTheRoot.status == 2, "\(fromTheRoot.stderr)")
        #expect(fromTheRoot.stderr.contains("sift run --without: .sift/without-build/swiftpm could not be cleared"), "\(fromTheRoot.stderr)")
        #expect(fromASubdirectory.status == 2, "\(fromASubdirectory.stderr)")
        // Compared once both are resolved: the fixture's root has had its `/private` resolved away, and the
        // repository root the command finds has not.
        let named = fromASubdirectory.stderr.firstMatch(of: #/sift run --without: (/.+?) could not be cleared/#).map { String($0.1) }
        #expect(
            named.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == withoutBuild.appendingPathComponent("swiftpm").resolvingSymlinksInPath().path,
            "\(fromASubdirectory.stderr)"
        )
    }

    /// A build directory the run left a writer running in is not marked as holding a build that reached its tests, so the next run starts it afresh rather than trusting what a still-writing build left there.
    @Test
    func aBuildTheRunLeftAWriterRunningInIsNotBuiltOnAgain() throws {
        let fixture = try Fixture()
        let builds = ["SIFT_TEST_BUILDS": "1"]
        let own = ".sift/without-build/swiftpm/built"

        let withAStraggler = try fixture.sift(Fixture.proof, environment: builds.merging(fixture.leavingAWriter) { _, new in new })
        try fixture.waitForTheWriterToEnd()

        #expect(withAStraggler.status == 0, "\(withAStraggler.stdout)\(withAStraggler.stderr)")
        #expect(withAStraggler.stdout.contains("the run without Sources/ left running, before putting the changes back"), "\(withAStraggler.stdout)")
        #expect(fixture.contents(of: own) == "without\n")

        #expect(try fixture.sift(Fixture.proof, environment: builds).status == 0)
        #expect(fixture.contents(of: own) == "without\n", "a build the run left a writer running in is never trusted, so the next one starts afresh")
    }
}

extension RunWithoutCommandTests {
    /// A throwaway repository with one of each kind of uncommitted change under `Sources/`, a stand-in `swift`, and a temporary run log.
    ///
    /// Asked for a slow smudge, it gives `Sources/feature.txt` a smudge filter that touches a marker and sleeps, so a set-aside preparing HEAD's version of it is held open long enough to be killed or written under; asked for another branch, it adds one whose one commit changes that file.
    struct Fixture {
        let root: URL
        let bin: URL
        let runLog: URL
        /// Touched by the smudge filter as it starts.
        let smudging: URL

        init(slowSmudge: Bool = false, otherBranch: Bool = false, under parent: URL? = nil) throws {
            let base = try parent.map { $0.appendingPathComponent("sift-without-\(UUID().uuidString)") } ?? TemporaryDirectory.make("without")
            root = base.appendingPathComponent("repo").resolvingSymlinksInPath()
            bin = base.appendingPathComponent("bin")
            runLog = base.appendingPathComponent("run.jsonl")
            smudging = base.appendingPathComponent("smudging")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try Self.standIn.write(to: bin.appendingPathComponent("swift"), atomically: true, encoding: .utf8)
            chmod(bin.appendingPathComponent("swift").path, 0o755)

            for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "test@example.com"], ["config", "user.name", "Tester"]] {
                try git(arguments)
            }
            if slowSmudge {
                try git(["config", "filter.slow.smudge", "touch '\(smudging.path)'; sleep 3; cat"])
                try git(["config", "filter.slow.clean", "cat"])
                try write("Sources/feature.txt filter=slow\n", to: ".gitattributes")
            }
            try write("broken\n", to: "Sources/feature.txt")
            try write("base\n", to: "Sources/staged.txt")
            try git(["add", "-A"])
            try git(["commit", "-q", "-m", "seed"])
            if otherBranch {
                try git(["checkout", "-q", "-b", "other"])
                try write("on the other branch\n", to: "Sources/feature.txt")
                try git(["commit", "-q", "-am", "other"])
                try git(["checkout", "-q", "main"])
            }
            try write("fixed\n", to: "Sources/feature.txt")
            try write("staged\n", to: "Sources/staged.txt")
            try git(["add", "Sources/staged.txt"])
            try write("untracked\n", to: "Sources/new/untracked.txt")
        }

        /// A stand-in `swift test`: one test, which passes only when the tree holds the fix.
        ///
        /// Told where, it reports that the tests are running and then holds — for good, for `SIFT_HOLD_SECONDS`, or until the file `SIFT_HOLD_UNTIL` names exists — in the pass `SIFT_HOLD_PASS` names, so a test can end or overlap the run mid-flight. `SIFT_TEST_HOOK` runs a command at the start of the pass without the fix; `SIFT_TEST_ORPHAN` leaves a writer behind in that pass, which records its pid in the file `SIFT_TEST_ORPHAN` names and writes into the tree once the file `SIFT_TEST_ORPHAN_AFTER` names is gone, and `SIFT_TEST_STUBBORN` one that ignores `SIGTERM` while it waits; `SIFT_PASS_DONE` is touched as the pass without the fix ends; `SIFT_TEST_ALWAYS_PASSES` and `SIFT_TEST_SILENT` stand in for a test that pins nothing and a filter that names none; `SIFT_TEST_BUILDS` has it build as SwiftPM does, where `--scratch-path` says or in `.build`, appending the pass to `built` there; `SIFT_TEST_GIT_CONFIG` names a file each pass appends its name and its `GIT_CONFIG_*` variables to, one line a pass; `SIFT_TEST_UNRESOLVED` has the pass without the fix fail as SwiftPM does when it cannot clone a dependency; `SIFT_TEST_PROBE` names the file the fix is looked for in, instead of `Sources/feature.txt`, and a line commented out with `//` never holds it.
        private static var standIn: String {
            """
            #!/bin/sh
            if grep -v '^[[:space:]]*//' "${SIFT_TEST_PROBE:-Sources/feature.txt}" | grep -q fixed; then pass=with; else pass=without; fi
            if [ -n "$SIFT_TEST_BUILDS" ]; then
                scratch=.build; named=
                for argument in "$@"; do
                    if [ -n "$named" ]; then scratch=$argument; named=; fi
                    case "$argument" in --scratch-path) named=1 ;; --scratch-path=*) scratch=${argument#--scratch-path=} ;; esac
                done
                mkdir -p "$scratch" && echo "$pass" >> "$scratch/built"
            fi
            if [ -n "$SIFT_TEST_GIT_CONFIG" ]; then echo "$pass" $(env | grep '^GIT_CONFIG' | sort) >> "$SIFT_TEST_GIT_CONFIG"; fi
            if [ "$pass" = without ] && [ -n "$SIFT_TEST_UNRESOLVED" ]; then
                printf 'Fetching https://example.com/acme/Widget.git\\n'
                printf 'error: Failed to clone repository https://example.com/acme/Widget.git:\\n'
                exit 1
            fi
            if [ "$pass" = without ] && [ -n "$SIFT_TEST_HOOK" ]; then sh -c "$SIFT_TEST_HOOK"; fi
            if [ "$pass" = without ] && [ -n "$SIFT_TEST_ORPHAN" ]; then
                ( while [ -e "$SIFT_TEST_ORPHAN_AFTER" ]; do sleep 0.05; done; echo "written by a process the run left behind" > Sources/feature.txt ) > /dev/null 2>&1 &
                echo $! > "$SIFT_TEST_ORPHAN"
            fi
            if [ "$pass" = without ] && [ -n "$SIFT_TEST_STUBBORN" ]; then
                ( trap '' TERM; sleep "$SIFT_TEST_STUBBORN"; echo "written by a process that ignored SIGTERM" > Sources/feature.txt ) > /dev/null 2>&1 &
            fi
            if [ -n "$SIFT_HOLD_MARKER" ] && [ "$pass" = "${SIFT_HOLD_PASS:-without}" ]; then
                cat "${SIFT_TEST_PROBE:-Sources/feature.txt}" > "$SIFT_HOLD_MARKER.tree"
                echo $$ > "$SIFT_HOLD_MARKER.tmp" && mv "$SIFT_HOLD_MARKER.tmp" "$SIFT_HOLD_MARKER"
                if [ -n "$SIFT_HOLD_UNTIL" ]; then
                    while [ ! -e "$SIFT_HOLD_UNTIL" ]; do sleep 0.05; done
                elif [ -z "$SIFT_HOLD_SECONDS" ]; then
                    exec sleep 60
                else
                    sleep "$SIFT_HOLD_SECONDS"
                fi
            fi
            if [ "$pass" = without ] && [ -n "$SIFT_PASS_DONE" ]; then : > "$SIFT_PASS_DONE"; fi
            if [ -n "$SIFT_TEST_SILENT" ]; then exit 0; fi
            if [ -n "$SIFT_TEST_ALWAYS_PASSES" ] || grep -v '^[[:space:]]*//' "${SIFT_TEST_PROBE:-Sources/feature.txt}" | grep -q fixed; then
                printf 'Test shoutingWorks() passed after 0.001 seconds.\\n'
                printf 'Test run with 1 test in 1 suite passed after 0.001 seconds.\\n'
                exit 0
            fi
            printf 'Test shoutingWorks() recorded an issue at WidgetTests.swift:7:9: Expectation failed: broken\\n'
            printf 'Test shoutingWorks() failed after 0.001 seconds with 1 issue.\\n'
            printf 'Test run with 1 test in 1 suite failed after 0.001 seconds with 1 issue.\\n'
            exit 1

            """
        }

        var recordExists: Bool {
            FileManager.default.fileExists(atPath: SetAsideStore(repositoryRoot: root).recordURL.path)
        }

        /// git's reading of the tree, and every file's bits and bytes, outside git's and this tool's own directories.
        func snapshot() throws -> String {
            var lines = try [git(["status", "--porcelain=v2", "--untracked-files=all"])]
            let paths = try FileManager.default.subpathsOfDirectory(atPath: root.path)
                .filter { !$0.hasPrefix(".git") && !$0.hasPrefix(SiftPaths.directoryName) }
                .sorted()
            for path in paths {
                let url = root.appendingPathComponent(path)
                var info = stat()
                guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                    lines.append(path)
                    continue
                }
                try lines.append("\(path) \(String(info.st_mode & 0o7777, radix: 8)) \(String(contentsOf: url, encoding: .utf8))")
            }
            return lines.joined(separator: "\n")
        }

        /// The one proof run every test here makes.
        static let proof = ["run", "--without", "Sources/", "--", "swift", "test", "--filter", "WidgetTests"]

        /// Runs `sift` to completion in the repository — at its root, or in the subdirectory `directory` names.
        func sift(
            _ arguments: [String],
            environment: [String: String] = [:],
            in directory: String? = nil,
            sourceLocation: SourceLocation = #_sourceLocation
        ) throws -> Finished {
            try launch(arguments, environment: environment, in: directory, sourceLocation: sourceLocation).finish(sourceLocation: sourceLocation)
        }

        /// Starts `run --without` with the stand-in holding once the tests start.
        func launch(holdingAt name: String, environment: [String: String] = [:], sourceLocation: SourceLocation = #_sourceLocation) throws -> Running {
            let marker = root.deletingLastPathComponent().appendingPathComponent("hold-\(name)")
            return try launch(Self.proof, marker: marker, environment: environment, sourceLocation: sourceLocation)
        }

        /// Starts `sift` and returns without waiting for it.
        func launch(
            _ arguments: [String],
            marker: URL? = nil,
            environment extra: [String: String] = [:],
            in directory: String? = nil,
            sourceLocation: SourceLocation = #_sourceLocation
        ) throws -> Running {
            let binary = try #require(
                BuiltExecutable.sift,
                "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)",
                sourceLocation: sourceLocation
            )
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            process.currentDirectoryURL = directory.map { root.appendingPathComponent($0) } ?? root
            var environment = ProcessEnvironment.withoutGit()
            environment["PATH"] = "\(bin.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
            environment["SIFT_RUN_LOG"] = runLog.path
            environment["SIFT_HOLD_MARKER"] = marker?.path
            environment.merge(extra) { _, new in new }
            process.environment = environment
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            return Running(process: process, stdout: stdout, stderr: stderr, marker: marker)
        }

        func write(_ text: String, to path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        /// Commits `files` alone — whatever else is staged stays staged and uncommitted.
        func commit(_ files: [String: String]) throws {
            for (path, text) in files {
                try write(text, to: path)
            }
            let paths = files.keys.sorted()
            try git(["add", "--"] + paths)
            try git(["commit", "-q", "-m", "more", "--"] + paths)
        }

        /// What a file under the root holds, or `nil` when there is none.
        func contents(of path: String) -> String? {
            try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }

        /// Every name in `directory` — repository-relative — that holds a kept file.
        func kept(in directory: String) -> [String] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(directory).path)) ?? []
            return names.filter { $0.contains(".sift-kept-") }.sorted().map { "\(directory)/\($0)" }
        }

        /// The watcher guarding the record that stands now, found by the record id it was started with.
        func watcher() throws -> Int32? {
            guard let record = try SetAsideStore(repositoryRoot: root).record() else {
                return nil
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-f", "guard-set-aside \(record.id)"]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try process.run()
            let output = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            return (String(data: output, encoding: .utf8) ?? "").split(separator: "\n").compactMap { Int32($0) }.first
        }

        /// Where a marker file for this fixture goes — beside the repository, never in it.
        func beside(_ name: String) -> URL {
            root.deletingLastPathComponent().appendingPathComponent(name)
        }

        /// The environment that has the pass without the fix leave a writer behind, which writes into the tree as soon as the changes are back unless it was ended first.
        ///
        /// Timed by the set-aside record rather than by a delay: a writer that slept a fixed span raced the run itself, so a machine slow enough to take that long to reach the end of the pass saw the write land while the tree was still set aside, and failed for its load rather than for anything the run did.
        var leavingAWriter: [String: String] {
            ["SIFT_TEST_ORPHAN": beside("writer.pid").path, "SIFT_TEST_ORPHAN_AFTER": SetAsideStore(repositoryRoot: root).recordURL.path]
        }

        /// Waits for the writer ``leavingAWriter`` left behind to be gone, ended or done writing, so the tree read next is the one it leaves.
        func waitForTheWriterToEnd(sourceLocation: SourceLocation = #_sourceLocation) throws {
            let recorded = try String(contentsOf: beside("writer.pid"), encoding: .utf8)
            let pid = try #require(Int32(recorded.trimmingCharacters(in: .whitespacesAndNewlines)), "no writer was left behind", sourceLocation: sourceLocation)
            try wait("the writer the run left behind ending", until: { kill(pid, 0) != 0 }, sourceLocation: sourceLocation)
        }

        /// Makes the uncommitted version of `path` a file of `bytes` bytes — sparse, so it costs no disk — starting with `text`: large enough that hashing it gives a racer time to act.
        func makeLarge(_ path: String, bytes: Int, startingWith text: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
            try write(text, to: path)
            let descriptor = open(root.appendingPathComponent(path).path, O_WRONLY)
            try #require(descriptor >= 0, sourceLocation: sourceLocation)
            defer { close(descriptor) }
            try #require(ftruncate(descriptor, off_t(bytes)) == 0, sourceLocation: sourceLocation)
        }

        /// The size of the file at `path`, when there is one.
        func size(of path: String) -> Int? {
            (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path))?[.size] as? Int
        }

        /// Waits for `condition`, failing rather than hanging the suite if it never holds.
        func wait(
            _ what: String,
            upTo seconds: TimeInterval = 30,
            until condition: () -> Bool,
            sourceLocation: SourceLocation = #_sourceLocation
        ) throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline {
                usleep(20000)
            }
            try #require(condition(), "\(what) never happened", sourceLocation: sourceLocation)
        }

        /// Every index entry, with its mode, object and stage.
        func index() throws -> String {
            try git(["ls-files", "-s"])
        }

        @discardableResult
        func git(_ arguments: [String]) throws -> String {
            try RunWithoutCommandTests.git(arguments, in: root)
        }
    }

    /// A thread that waits for `trigger` to hold and then acts once — how a test lands a write in the moment a run leaves a path open to one.
    final class Racer: @unchecked Sendable {
        private let gate = NSLock()
        private var stopped = false
        private var fired = false
        private let done = DispatchSemaphore(value: 0)

        init(until trigger: @escaping @Sendable () -> Bool, then act: @escaping @Sendable () -> Void) {
            let thread = Thread { [self] in
                while !gate.withLock({ stopped }) {
                    if trigger() {
                        act()
                        gate.withLock { fired = true }
                        break
                    }
                    usleep(100)
                }
                done.signal()
            }
            thread.start()
        }

        /// Stops it, and answers whether it acted.
        func stop() -> Bool {
            gate.withLock { stopped = true }
            done.wait()
            return gate.withLock { fired }
        }

        /// Whether anything stands at `path`, link or not.
        static func exists(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0
        }

        /// The names in `directory`, or none when it does not exist.
        static func names(in directory: String) -> [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        }

        /// Creates `path` holding `text`, failing rather than replacing anything there — how an editor's first save of a new file lands.
        static func create(_ path: String, holding text: String) {
            let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            guard descriptor >= 0 else {
                return
            }
            _ = Array(text.utf8).withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            close(descriptor)
        }

        /// Writes `text` over whatever is at `path`, in place, as `open(…, "w")` does — how an editor that saves in place lands.
        static func save(_ path: String, holding text: String) {
            let descriptor = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0o644)
            guard descriptor >= 0 else {
                return
            }
            _ = Array(text.utf8).withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            close(descriptor)
        }
    }

    /// An HFS+ disk image, attached for one test: a volume that cannot clone a file, so putting one back means copying it.
    struct ScratchVolume {
        let mountPoint: URL

        init() throws {
            let base = try TemporaryDirectory.make("volume").appendingPathComponent("volume")
            let image = base.appendingPathComponent("volume.dmg")
            mountPoint = base.appendingPathComponent("mount")
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            try Self.hdiutil(["create", "-quiet", "-size", "160m", "-fs", "HFS+", "-volname", "sift-without", "-type", "UDIF", image.path])
            try Self.hdiutil(["attach", "-quiet", "-nobrowse", "-noverify", "-mountpoint", mountPoint.path, image.path])
        }

        func detach() {
            try? Self.hdiutil(["detach", "-quiet", "-force", mountPoint.path])
        }

        private static func hdiutil(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw FixtureError(message: "hdiutil \(arguments.first ?? "") failed with exit \(process.terminationStatus)")
            }
        }
    }

    /// A throwaway SwiftPM package in a git repository — `Widget`, whose `shout()` an uncommitted change fixes, and a test that passes only with the fix — never built before the run, so every file in its `.build` is dated by the build that wrote it.
    struct SwiftPMFixture {
        let root: URL
        /// SwiftPM's `$TMPDIR`, inside the test's own scope: SwiftPM files locks there named for the package's path and never removes them.
        let temporary: URL
        let runLog: URL

        init() throws {
            let base = try TemporaryDirectory.make("without-swiftpm")
            root = base.appendingPathComponent("repo").resolvingSymlinksInPath()
            temporary = base.appendingPathComponent("tmp")
            runLog = base.appendingPathComponent("run.jsonl")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            try write(Self.manifest, to: "Package.swift")
            try write(".build/\n", to: ".gitignore")
            try write(Self.widget(shouting: "name"), to: "Sources/Widget/Widget.swift")
            try write(Self.test, to: "Tests/WidgetTests/WidgetTests.swift")
            for arguments in [
                ["init", "-q", "-b", "main"], ["config", "user.email", "test@example.com"], ["config", "user.name", "Tester"],
                ["add", "-A"], ["commit", "-q", "-m", "seed"],
            ] {
                try RunWithoutCommandTests.git(arguments, in: root)
            }
            try write(Self.widget(shouting: "name.uppercased()"), to: "Sources/Widget/Widget.swift")
        }

        static var manifest: String {
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Widget",
                platforms: [.macOS(.v13)],
                targets: [
                    .target(name: "Widget"),
                    .testTarget(name: "WidgetTests", dependencies: ["Widget"]),
                ]
            )
            """
        }

        static var test: String {
            """
            import Testing
            import Widget

            @Test func shoutingWorks() {
                #expect(Widget(name: "hi").shout() == "HI")
            }
            """
        }

        static func widget(shouting body: String) -> String {
            """
            public struct Widget {
                public var name: String

                public init(name: String) {
                    self.name = name
                }

                public func shout() -> String {
                    \(body)
                }
            }
            """
        }

        /// When `url` was last written, in nanoseconds on the file system's own clock.
        static func modified(_ url: URL) throws -> Int64 {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw FixtureError(message: "nothing at \(url.path)")
            }
            return Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        }

        /// Now, on the file system's clock: the time of a file written beside the repository.
        func stamp() throws -> Int64 {
            let url = root.deletingLastPathComponent().appendingPathComponent("stamp")
            try Data().write(to: url)
            return try Self.modified(url)
        }

        /// Every regular file under `directory`, repository-relative, with when it was last written.
        func files(under directory: String) throws -> [(path: String, modified: Int64)] {
            let base = root.appendingPathComponent(directory)
            return try FileManager.default.subpathsOfDirectory(atPath: base.path).compactMap { path in
                let url = base.appendingPathComponent(path)
                var info = stat()
                guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                    return nil
                }
                return try ("\(directory)/\(path)", Self.modified(url))
            }
        }

        /// Runs `sift` in the package to completion, with the real `swift` on `PATH` — two builds from nothing and two test runs, so it is given longer than a stand-in needs.
        func sift(_ arguments: [String], sourceLocation: SourceLocation = #_sourceLocation) throws -> Finished {
            let binary = try #require(
                BuiltExecutable.sift,
                "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)",
                sourceLocation: sourceLocation
            )
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            process.currentDirectoryURL = root
            var environment = ProcessEnvironment.withoutGit()
            environment["SIFT_RUN_LOG"] = runLog.path
            environment["TMPDIR"] = temporary.path + "/"
            process.environment = environment
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            // This runs a real SwiftPM package clean twice — with the change, then without it — so the deadline is
            // far past what any machine takes even where a neighbouring build shares the same load: a run of the
            // suite alone finishes in seconds, one beside another build once stretched past 600.
            return try Running(process: process, stdout: stdout, stderr: stderr, marker: nil).finish(upTo: 1800, sourceLocation: sourceLocation)
        }

        func write(_ text: String, to path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Runs git in `root` with none of the test process's own git environment, and answers what it printed.
    @discardableResult
    static func git(_ arguments: [String], in root: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = ProcessEnvironment.withoutGit()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let streams = ProcessStreams.drain(stdout: stdout, stderr: stderr)
        process.waitUntilExit()
        let output = String(data: streams.output, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let failure = String(data: streams.failure, encoding: .utf8) ?? ""
            throw FixtureError(message: "git \(arguments.joined(separator: " ")) failed: \(failure)")
        }
        return output
    }

    /// A `sift` process under test.
    struct Running {
        let process: Process
        let stdout: Pipe
        let stderr: Pipe
        let marker: URL?

        /// Waits for the stand-in to say the tests are running, and returns what the tree held for them.
        func waitUntilTheTestsAreRunning(sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
            let marker = try #require(marker, sourceLocation: sourceLocation)
            let deadline = Date().addingTimeInterval(60)
            while !FileManager.default.fileExists(atPath: marker.path), process.isRunning, Date() < deadline {
                usleep(20000)
            }
            try #require(FileManager.default.fileExists(atPath: marker.path), "the tests never started", sourceLocation: sourceLocation)
            return try String(contentsOf: URL(fileURLWithPath: marker.path + ".tree"), encoding: .utf8)
        }

        /// Ends the stand-in if it is still holding — a process killed outright passes no signal on.
        func stopTheStandIn() {
            guard let marker, let text = try? String(contentsOf: marker, encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                return
            }
            kill(pid, SIGKILL)
        }

        /// Waits for the process to end — failing rather than hanging the suite if it never does — and reads what it said.
        func finish(upTo seconds: TimeInterval = 60, sourceLocation: SourceLocation = #_sourceLocation) throws -> Finished {
            let deadline = Date().addingTimeInterval(seconds)
            while process.isRunning, Date() < deadline {
                usleep(20000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                stopTheStandIn()
                Issue.record("sift was still running \(Int(seconds)) seconds later", sourceLocation: sourceLocation)
            }
            let streams = ProcessStreams.drain(stdout: stdout, stderr: stderr)
            return Finished(
                status: process.terminationStatus,
                stdout: String(data: streams.output, encoding: .utf8) ?? "",
                stderr: String(data: streams.failure, encoding: .utf8) ?? ""
            )
        }
    }

    struct Finished {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    struct FixtureError: Error {
        let message: String
    }
}
