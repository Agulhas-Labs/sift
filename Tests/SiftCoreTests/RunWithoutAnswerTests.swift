//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the answer `run --without` gives — one line per named test, the exceptions first — and the command it will agree to run twice.
@Suite(.temporaryDirectories)
struct RunWithoutAnswerTests {
    /// Every test failing without the change and passing with it is the one answer that earns the tick, and it says so in the words a caller greps for.
    @Test
    func aTickNeedsEveryTestToFailWithoutAndPassWith() {
        let answer = Self.answer(
            without: Self.run(["shoutingWorks()": false, "sizeIsCarried()": false]),
            with: Self.run(["shoutingWorks()": true, "sizeIsCarried()": true])
        )
        let lines = answer.text.split(separator: "\n").map(String.init)

        #expect(lines.first == "✔ 2 of 2 fail without Sources/ and pass with it")
        #expect(lines.contains("  ✔ shoutingWorks() — fails without Sources/, passes with it"))
        #expect(lines.contains("  ✔ sizeIsCarried() — fails without Sources/, passes with it"))
        #expect(answer.lines == answer.text.split(separator: "\n", omittingEmptySubsequences: false).count)
    }

    /// A test that passes without the change pins nothing, and one that fails both ways is not pinning it either: both are named, ahead of the tests that do pin it.
    @Test
    func theTestsThatBreakTheClaimAreNamedFirst() {
        let answer = Self.answer(
            without: Self.run(["shoutingWorks()": false, "sizeIsCarried()": true, "theGridReflows()": false]),
            with: Self.run(["shoutingWorks()": true, "sizeIsCarried()": true, "theGridReflows()": false])
        )
        let lines = answer.text.split(separator: "\n").map(String.init)

        #expect(lines.first == "✘ 1 of 3 fails without Sources/ and passes with it")
        let pinsNothing = lines.firstIndex(of: "  ✘ sizeIsCarried() — passes without Sources/ too, so it pins nothing")
        let failsBothWays = lines.firstIndex { $0.hasPrefix("  ✘ theGridReflows() — fails both ways — with it: WidgetTests.swift:7:9: Expectation failed") }
        let pins = lines.firstIndex(of: "  ✔ shoutingWorks() — fails without Sources/, passes with it")
        #expect(pinsNothing != nil && failsBothWays != nil && pins != nil)
        if let pinsNothing, let failsBothWays, let pins {
            #expect(pinsNothing < failsBothWays && failsBothWays < pins)
        }
    }

    /// Tests that did not compile without the change are evidence, not a failing assertion, and the headline says which it is — with the errors that show why.
    ///
    /// The claim rests on the error landing in a file that imports a test framework, and it is still not a proof.
    @Test
    func aSuiteThatDidNotCompileWithoutTheChangeIsSaidApartFromAFailure() throws {
        let directory = try Self.directory(holding: ["Tests/WidgetTests/WidgetTests.swift": "import Testing\n@testable import Widgets\n"])
        let without = Self.failedBeforeTests("Tests/WidgetTests/WidgetTests.swift:3:5: error: cannot find 'Gadget' in scope\n")

        let judged = Self.judged(without: without, with: Self.run(["shoutingWorks()": true]), workingDirectory: directory)
        let lines = judged.render().text.split(separator: "\n").map(String.init)

        #expect(lines.first == "◇ the tests did not compile without Sources/ — evidence they need it, not a failing assertion; 1 of 1 passes with it")
        #expect(lines.contains("    Tests/WidgetTests/WidgetTests.swift:3:5: error: cannot find 'Gadget' in scope"))
        #expect(lines.contains("  ◇ shoutingWorks() — passes with it; without Sources/ it did not compile — needed, not pinned"))
        #expect(!lines.contains { $0.hasPrefix("  ✔") }, "a tick is a test that failed an assertion without the change, and none did")
        #expect(!judged.proven, "tests that did not compile are evidence, not the proof")
    }

    /// A change that adds a file HEAD does not have is set aside by removing the file, so the answer says that is what happened, and that a test naming what it declared could only fail to build.
    ///
    /// The distinction is the whole value of the line: "the test could not build without the fix" does not say the test pins anything, and a reader who takes the one for the other has a proof that is not there.
    @Test
    func aFileHeadDoesNotHaveIsRemovedAndTheAnswerSaysWhatThatCanShow() throws {
        let directory = try Self.directory(holding: ["Tests/WidgetTests/WidgetTests.swift": "import Testing\n@testable import Widgets\n"])
        let without = Self.failedBeforeTests("Tests/WidgetTests/WidgetTests.swift:3:5: error: cannot find 'Gadget' in scope\n")

        let judged = Self.judged(
            without: without,
            with: Self.run(["shoutingWorks()": true]),
            workingDirectory: directory,
            newFiles: ["Sources/Widgets/Gadget.swift"]
        )
        let lines = judged.render().text.split(separator: "\n").map(String.init)

        #expect(lines.contains("  Sources/Widgets/Gadget.swift is not in HEAD, so setting it aside removed it: a test that names what it declared could not build, and none failed an assertion without Sources/. Whether a test pins what the file does, rather than merely naming it, is not shown — that needs the file committed and what it does changed."), "\(lines)")
        #expect(!judged.proven)
    }

    /// Two new files are named together, and a run whose tests did compile without the change says nothing about them: the removal only explains a build that broke.
    @Test
    func removedFilesAreNamedTogetherAndOnlyWhereTheyExplainTheBuild() throws {
        let directory = try Self.directory(holding: ["Tests/WidgetTests/WidgetTests.swift": "import Testing\n@testable import Widgets\n"])
        let both = Self.judged(
            without: Self.failedBeforeTests("Tests/WidgetTests/WidgetTests.swift:3:5: error: cannot find 'Gadget' in scope\n"),
            with: Self.run(["shoutingWorks()": true]),
            workingDirectory: directory,
            newFiles: ["Sources/Widgets/Gadget.swift", "Sources/Widgets/Bracket.swift"]
        )

        #expect(both.render().text.contains("  Sources/Widgets/Gadget.swift, Sources/Widgets/Bracket.swift are not in HEAD, so setting them aside removed them: a test"), "\(both.render().text)")

        let compiled = Self.judged(
            without: Self.run(["shoutingWorks()": false]),
            with: Self.run(["shoutingWorks()": true]),
            workingDirectory: directory,
            newFiles: ["Sources/Widgets/Gadget.swift"]
        )
        let text = compiled.render().text

        #expect(text.hasPrefix("✔ 1 of 1 fails without Sources/ and passes with it"), "\(text)")
        #expect(!text.contains("is not in HEAD"), "\(text)")
        #expect(compiled.proven)
    }

    /// Under `--since`, a file the range added is in HEAD — it is not in the revision the set-aside placed — so the answer must never say it is not in HEAD, which would be a falsehood on the feature's headline case: the file is committed, right there, when the reader reads the answer.
    @Test
    func aSinceRunNamesTheRevisionRatherThanHEADForAFileItAdded() throws {
        let directory = try Self.directory(holding: ["Tests/WidgetTests/WidgetTests.swift": "import Testing\n@testable import Widgets\n"])
        let without = Self.failedBeforeTests("Tests/WidgetTests/WidgetTests.swift:3:5: error: cannot find 'Gadget' in scope\n")
        let revision = String(repeating: "c", count: 40)

        let judged = Self.judged(
            without: without,
            with: Self.run(["shoutingWorks()": true]),
            workingDirectory: directory,
            newFiles: ["Sources/Widgets/Gadget.swift"],
            since: revision
        )
        let text = judged.render().text

        #expect(!text.contains("is not in HEAD"), "\(text)")
        #expect(text.contains("Sources/Widgets/Gadget.swift is not in \(String(revision.prefix(10))), so setting it aside removed it"), "\(text)")
    }

    /// An error before any test ran that is not a compiler error in a test file — a scheme that does not exist, a source file that did not build — is the command failing before its tests, quoted, and never "the tests do not compile".
    @Test
    func anErrorBeforeAnyTestRanIsNotCalledTheTestsNotCompiling() throws {
        let directory = try Self.directory(holding: ["Sources/Widgets/Widget.swift": "import Foundation\n"])
        for (log, what) in [
            ("xcodebuild: error: The project named \"App\" does not contain a scheme named \"Nope\".\n", "the command failed"),
            ("Sources/Widgets/Widget.swift:3:5: error: cannot find 'Gadget' in scope\n", "the build failed"),
            (Self.compilerCrash, "the build failed"),
        ] {
            let judged = Self.judged(without: Self.failedBeforeTests(log), with: Self.run(["shoutingWorks()": true]), workingDirectory: directory)
            let text = judged.render().text

            #expect(text.hasPrefix("✘ the command failed before running tests without Sources/ — nothing was proven\n"), "\(text)")
            #expect(text.contains("  without Sources/, \(what) before any test ran:"), "\(text)")
            #expect(!text.contains("did not compile"), "\(text)")
            #expect(!judged.proven)
        }
        let bothWays = Self.judged(
            without: Self.failedBeforeTests("xcodebuild: error: The project named \"App\" does not contain a scheme named \"Nope\".\n"),
            with: Self.failedBeforeTests("xcodebuild: error: The project named \"App\" does not contain a scheme named \"Nope\".\n"),
            workingDirectory: directory
        )

        #expect(bothWays.render().text.hasPrefix("✘ the command failed before running tests, both without Sources/ and with it — nothing was proven"))
    }

    /// A run without the change that did not build reads the same way a plain `sift run` would: `did not build — no test ran`, never as an ordinary `✘` beside the run with it, which reads as a negative gate that passed.
    @Test
    func aRunWithoutTheChangeThatDidNotBuildIsNeverReadAsAnOrdinaryFailure() throws {
        let directory = try Self.directory(holding: ["Sources/Widgets/Widget.swift": "import Foundation\n"])
        let selector = RunTestSelector.named(in: ["swift", "test", "--filter", "shoutingWorks"])
        let judged = Self.judged(
            without: Self.failedBeforeTests("Sources/Widgets/Widget.swift:3:5: error: cannot find 'Gadget' in scope\n"),
            with: Self.run(["shoutingWorks()": true]),
            workingDirectory: directory,
            selector: selector
        )
        let text = judged.render().text

        #expect(text.hasPrefix("✘ the command failed before running tests without Sources/ — nothing was proven\n"), "\(text)")
        #expect(text.contains("without Sources/ — ✘ swift test — did not build — no test ran (the command exited 1; sift run exits 5)"), "\(text)")
        #expect(!text.contains("without Sources/ — ✘ swift test — exit 1"), "the per-run line must not read as an ordinary failure beside the run with it, which is the false proof --without exists to rule out: \(text)")
        #expect(!judged.proven)
    }

    /// Two tests that print one name and disagree cannot be told apart from the log, and the answer says that instead of letting one stand for both.
    @Test
    func twoTestsSharingANameThatDisagreeAreSaidRatherThanFolded() {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(Data("""
        Test shoutingWorks() passed after 0.001 seconds.
        Test shoutingWorks() failed after 0.001 seconds with 1 issue.
        Test run with 2 tests in 2 suites failed after 0.001 seconds with 1 issue.

        """.utf8))
        let without = RunOutcome(kind: .swiftTest, logKey: "swift test", exitCode: 1, report: filter.finish(), log: nil, repositoryRoot: nil)

        let answer = Self.answer(without: without, with: Self.run(["shoutingWorks()": true]))

        #expect(answer.text.contains("✘ shoutingWorks() — 2 tests print this name, and without Sources/ 1 passed and 1 failed — the log cannot tell them apart"))
        #expect(answer.text.hasPrefix("✘ 0 of 1 fail without Sources/"))
    }

    /// The answer states what was set aside and that it was checked, and names both raw logs' absence rather than pretending they exist.
    @Test
    func theAnswerStatesTheSetAsideAndBothRuns() {
        let answer = Self.answer(
            without: Self.run(["shoutingWorks()": false]),
            with: Self.run(["shoutingWorks()": true])
        )

        #expect(answer.text.contains("  set aside and put back: 2 paths under Sources/ (1 with staged changes, 1 untracked), checked by content hash"))
        #expect(answer.text.contains("without Sources/ — ✘ swift test — exit 1"))
        #expect(answer.text.contains("with it — ✔ swift test"))
        #expect(answer.text.contains("no raw log could be written (without Sources/)"))
    }

    /// A `--since` run's entries are committed changes, whose `Entry.status` is empty — `split` counts nothing from it, so the parenthetical the uncommitted case fills with "staged"/"unstaged"/"untracked" must not render as an empty `()`.
    ///
    /// It says what was committed since instead.
    @Test
    func aSinceRunNamesWhatWasCommittedRatherThanAnEmptyParenthesis() {
        let revision = String(repeating: "d", count: 40)
        let record = SetAsideRecord(
            id: "0123456789",
            pathspecs: ["Sources/"],
            directory: "",
            head: String(repeating: "a", count: 40),
            since: revision,
            owner: 1,
            entries: [SetAsideRecord.Entry(path: "Sources/feature.txt", status: "", head: nil, index: .absent, worktree: .absent)]
        )
        let answer = RunWithoutAnswer(
            pathspecs: "Sources/",
            without: Self.run(["shoutingWorks()": false]),
            with: Self.run(["shoutingWorks()": true]),
            restored: SetAside.Restored(record: record, kept: [], headNow: nil),
            workingDirectory: URL(fileURLWithPath: "/nonexistent"),
            repositoryRoot: URL(fileURLWithPath: "/nonexistent")
        ).render()

        #expect(!answer.text.contains("Sources/ ()"), "\(answer.text)")
        #expect(answer.text.contains("  set aside and put back: 1 path under Sources/ (committed since \(String(revision.prefix(10)))), checked by content hash"), "\(answer.text)")
    }

    /// The build directory the run without the change built in is named in the receipt, with its size when one was measured, and how to remove it — the disk it costs is never invisible.
    @Test
    func theReceiptNamesTheBuildDirectoryAndHowToRemoveIt() {
        let named = Self.judged(
            without: Self.run(["shoutingWorks()": false]),
            with: Self.run(["shoutingWorks()": true]),
            buildDirectory: "/nonexistent/.sift/without-build/swiftpm",
            buildDirectorySize: 1_234_567
        )
        let unmeasured = Self.judged(
            without: Self.run(["shoutingWorks()": false]),
            with: Self.run(["shoutingWorks()": true]),
            buildDirectory: "/nonexistent/.sift/without-build/swiftpm"
        )
        let plain = Self.judged(without: Self.run(["shoutingWorks()": false]), with: Self.run(["shoutingWorks()": true]))

        #expect(named.render().text.contains("; the run without the change built in .sift/without-build/swiftpm (1.2 MB) — remove it any time with `rm -rf .sift/without-build/swiftpm`"), "\(named.render().text)")
        #expect(unmeasured.render().text.contains("; the run without the change built in .sift/without-build/swiftpm — remove it any time with `rm -rf .sift/without-build/swiftpm`"), "\(unmeasured.render().text)")
        #expect(!plain.render().text.contains("without-build"), "nothing to name when the caller passed no build directory")
    }

    /// The receipt's `rm -rf` removes the build directory from wherever the run started: a run in a subdirectory names it by its whole path, and a path a shell would split is quoted.
    @Test
    func theReceiptRemovesTheBuildDirectoryFromWhereverTheRunStarted() throws {
        let root = try TemporaryDirectory.make("answer").appendingPathComponent("My Repo")
        let build = root.appendingPathComponent(".sift/without-build/swiftpm").path
        let fromTheRoot = Self.judged(
            without: Self.run(["shoutingWorks()": false]),
            with: Self.run(["shoutingWorks()": true]),
            workingDirectory: root,
            buildDirectory: build
        )
        let fromASubdirectory = Self.judged(
            without: Self.run(["shoutingWorks()": false]),
            with: Self.run(["shoutingWorks()": true]),
            workingDirectory: root.appendingPathComponent("Packages/Kit"),
            buildDirectory: build
        )

        #expect(fromTheRoot.render().text.contains("; the run without the change built in .sift/without-build/swiftpm — remove it any time with `rm -rf .sift/without-build/swiftpm`"), "\(fromTheRoot.render().text)")
        #expect(fromASubdirectory.render().text.contains("; the run without the change built in \(build) — remove it any time with `rm -rf '\(build)'`"), "\(fromASubdirectory.render().text)")
    }

    /// Only a test run that builds first and names its tests can prove anything twice; everything else is refused before a single file moves.
    @Test
    func onlyANamedTestRunThatBuildsFirstIsAccepted() throws {
        try RunWithoutArguments.check(["swift", "test", "--filter", "WidgetTests"], pathspecs: [])
        try RunWithoutArguments.check(["swift", "test", "--filter=WidgetTests"], pathspecs: [])
        try RunWithoutArguments.check(["xcodebuild", "test", "-scheme", "App", "-only-testing:AppTests/WidgetTests"], pathspecs: [])
        try RunWithoutArguments.check(["xcodebuild", "test", "-only-testing:AppTests", "-retry-tests-on-failure", "-test-iterations", "3"], pathspecs: [])
        try RunWithoutArguments.check(["xcodebuild", "test", "-only-testing:AppTests", "-parallel-testing-enabled", "NO"], pathspecs: [])
        try RunWithoutArguments.check(["xcodebuild", "test", "-only-testing:AppTests", "ONLY_ACTIVE_ARCH=NO"], pathspecs: [])
        try RunWithoutArguments.check(["xcodebuild", "test", "-only-testing:AppTests", "SDKROOT=macosx"], pathspecs: [], environment: [:])

        for (arguments, expected) in [
            (["xcodebuild", "test", "-only-testing:AppTests", "-parallel-testing-enabled", "YES"], "parallel clones"),
            (["xcodebuild", "test", "-only-testing:AppTests", "-parallel-testing-enabled", "yes"], "parallel clones"),
            (["swift", "test"], "unnamed"),
            (["swift", "test", "--skip-build", "--filter", "WidgetTests"], "prebuilt"),
            (["swift", "build"], "not a test run"),
            (["xcodebuild", "test", "-scheme", "App"], "unnamed"),
            (["xcodebuild", "test-without-building", "-only-testing:AppTests"], "prebuilt"),
            (["swift", "test", "--parallel", "--filter", "WidgetTests"], "parallel"),
            (["swift", "test", "--num-workers=4", "--filter", "WidgetTests"], "parallel"),
            (["xcodebuild", "test", "-only-testing:AppTests", "-test-iterations", "3"], "repeated"),
            (["xcodebuild", "test", "-only-testing:AppTests", "-run-tests-until-failure"], "repeated"),
            (["xcodebuild", "test", "-only-testing:AppTests", "SYMROOT=build"], "build location"),
            (["xcodebuild", "test", "-only-testing:AppTests", "OBJROOT=build"], "build location"),
            (["xcodebuild", "test", "-only-testing:AppTests", "BUILD_DIR=build"], "build location"),
            (["xcodebuild", "test", "-only-testing:AppTests", "BUILD_ROOT=build"], "build location"),
            (["xcodebuild", "test", "-only-testing:AppTests", "CONFIGURATION_BUILD_DIR=build"], "build location"),
            (["xcodebuild", "test", "-only-testing:AppTests", "SHARED_PRECOMPS_DIR=build"], "build location"),
            (["xcodebuild", "test", "-only-testing:AppTests", "TEMP_ROOT=build"], "build location"),
            (["xcodebuild", "test", "-only-testing:AppTests", "PROJECT_TEMP_ROOT=build"], "build location"),
            (["xcodebuild", "test", "-only-testing:AppTests", "PROJECT_TEMP_DIR=build"], "build location"),
            (["xcodebuild", "test", "-only-testing:AppTests", "CONFIGURATION_TEMP_DIR=build"], "build location"),
            (["xcodebuild", "test", "-only-testing:AppTests", "TARGET_TEMP_DIR=build"], "build location"),
            (["xcodebuild", "test", "-only-testing:AppTests", "OBJECT_FILE_DIR=build"], "build location"),
            (["xcodebuild", "test", "-only-testing:AppTests", "BUILT_PRODUCTS_DIR=build"], "build location"),
            (["xcodebuild", "test", "-only-testing:AppTests", "TARGET_BUILD_DIR=build"], "build location"),
            (["xcodebuild", "test", "-only-testing:AppTests", "SYMROOT[sdk=macosx*]=build"], "build location"),
            (["xcodebuild", "test", "-only-testing:AppTests", "OBJECT_FILE_DIR_normal=build"], "build location"),
            (["xcodebuild", "test", "-only-testing:AppTests", "OBJECT_FILE_DIR_normal[arch=arm64]=build"], "build location"),
            (["xcodebuild", "test", "-only-testing:AppTests", "MODULE_CACHE_DIR=build"], "build location"),
            (["xcodebuild", "test", "-only-testing:AppTests", "DERIVED_FILE_DIR=build"], "build location"),
            (["xcodebuild", "test", "-only-testing:AppTests", "PROJECT_DERIVED_FILE_DIR=build"], "build location"),
            (["xcodebuild", "test", "-only-testing:AppTests", "-xcconfig", "Debug.xcconfig"], "build settings file"),
        ] {
            do {
                // No environment, so a variable the test runner happens to carry cannot decide a row.
                try RunWithoutArguments.check(arguments, pathspecs: [], environment: [:])
                Issue.record("\(arguments) was accepted")
            } catch let error as RunWithoutError {
                let kind = switch error {
                case .unnamed: "unnamed"
                case .prebuilt: "prebuilt"
                case .notATestRun: "not a test run"
                case .parallel: "parallel"
                case .parallelClones: "parallel clones"
                case .repeated: "repeated"
                case .buildLocation: "build location"
                case .buildSettingsFile: "build settings file"
                case .emptyBuildSettingsFile: "build settings file"
                case .pathspecsRunTogether: "pathspecs run together"
                case .sinceWithoutPathspec: "since without pathspec"
                case .unresolvedRevision: "unresolved revision"
                case .notAnAncestor: "not an ancestor"
                }
                #expect(kind == expected, "\(arguments)")
            }
        }

        #expect(RunWithoutArguments.retriesFailures(["xcodebuild", "test", "-only-testing:AppTests", "-retry-tests-on-failure"]))
        #expect(!RunWithoutArguments.retriesFailures(["swift", "test", "--filter", "WidgetTests"]))
    }

    /// A file of build settings can set where xcodebuild writes its products, so it is refused wherever it comes from — `-xcconfig`, or `XCODE_XCCONFIG_FILE` in the environment the command runs with — and said as what it can do rather than what it does.
    ///
    /// `swift test` ignores the variable (observed: a `SYMROOT` and an `OBJROOT` in the file it named left SwiftPM's products in its scratch path), so it is not refused there.
    @Test
    func aFileOfBuildSettingsIsRefusedWhereverItComesFrom() throws {
        let file = ["XCODE_XCCONFIG_FILE": "/tmp/Shared.xcconfig"]
        try RunWithoutArguments.check(["swift", "test", "--filter", "WidgetTests"], pathspecs: [], environment: file)
        try RunWithoutArguments.check(["xcodebuild", "test", "-only-testing:AppTests"], pathspecs: [], environment: [:])

        // Set empty, the variable is refused too, but names no file — so the remedy spells out the command that
        // unsets it rather than inviting `XCODE_XCCONFIG_FILE= sift …`.
        for (arguments, environment) in [
            (["xcodebuild", "test", "-only-testing:AppTests"], file),
            (["xcodebuild", "test", "-only-testing:AppTests", "-xcconfig", "Debug.xcconfig"], [:]),
        ] {
            let spelling = environment.isEmpty ? "`-xcconfig`" : "`XCODE_XCCONFIG_FILE` in the environment"
            let remedy = environment.isEmpty
                ? "Drop it"
                : "Unset it for this run with `env -u XCODE_XCCONFIG_FILE sift run --without …`, not by setting it empty, which is refused too"
            do {
                try RunWithoutArguments.check(arguments, pathspecs: [], environment: environment)
                Issue.record("\(arguments) was accepted with \(environment)")
            } catch let error as RunWithoutError {
                #expect(error.description.hasPrefix("sift run --without cannot use \(spelling): the file it names can set where xcodebuild writes its build products"), "\(error)")
                #expect(error.description.contains(". \(remedy) — "), "\(error)")
            }
        }

        // Empty rather than unset, the variable names no file at all, so the message says that instead of claiming
        // one — it is set but empty, which xcodebuild cannot open.
        do {
            try RunWithoutArguments.check(["xcodebuild", "test", "-only-testing:AppTests"], pathspecs: [], environment: ["XCODE_XCCONFIG_FILE": ""])
            Issue.record("empty XCODE_XCCONFIG_FILE was accepted")
        } catch let error as RunWithoutError {
            #expect(error.description == "sift run --without cannot use `XCODE_XCCONFIG_FILE` in the environment: it is set but empty, which xcodebuild cannot open; unset it with `env -u XCODE_XCCONFIG_FILE sift run --without …`.", "\(error)")
        }
    }

    /// A test a command retried is one test, judged by its last attempt — and the attempts that failed first are said, not dropped.
    @Test
    func aRetriedTestIsJudgedByItsLastAttempt() {
        let contract = RunVerdict.Contract.of(["xcodebuild", "test", "-only-testing:WidgetTests"]) ?? .unreadable
        var filter = RunOutputFilter(expecting: contract)
        filter.consume(Data("""
        Test Case '-[WidgetTests.LegacyWidgetTests testNaming]' started.
        Test Case '-[WidgetTests.LegacyWidgetTests testNaming]' failed (0.001 seconds).
        Test Case '-[WidgetTests.LegacyWidgetTests testNaming]' started.
        Test Case '-[WidgetTests.LegacyWidgetTests testNaming]' passed (0.001 seconds).
        ** TEST SUCCEEDED **

        """.utf8))
        let with = RunOutcome(kind: .xcodebuild, logKey: "xcodebuild test", exitCode: 0, report: filter.finish(), log: nil, repositoryRoot: nil)
        var failing = RunOutputFilter(expecting: contract)
        failing.consume(Data("""
        Test Case '-[WidgetTests.LegacyWidgetTests testNaming]' started.
        Test Case '-[WidgetTests.LegacyWidgetTests testNaming]' failed (0.001 seconds).
        ** TEST FAILED **

        """.utf8))
        let without = RunOutcome(kind: .xcodebuild, logKey: "xcodebuild test", exitCode: 65, report: failing.finish(), log: nil, repositoryRoot: nil)

        let retried = Self.judged(without: without, with: with, retries: true)
        let folded = Self.judged(without: without, with: with)

        #expect(retried.render().text.contains("  ✔ -[WidgetTests.LegacyWidgetTests testNaming] — fails without Sources/, passes with it (with it it passed only on a retry, after 1 failure)"), "\(retried.render().text)")
        #expect(retried.proven)
        #expect(folded.render().text.contains("2 tests print this name"), "without a retry flag, two finishes under one name are two tests")
        #expect(!folded.proven)
    }

    /// What was left in place, what was stopped, and a HEAD that moved are all said — and a HEAD that moved means nothing was proven.
    @Test
    func whatTheRunDidBesidesTheTestsIsSaid() {
        let without = Self.run(["shoutingWorks()": false])
        let with = Self.run(["shoutingWorks()": true])

        let plain = Self.judged(without: without, with: with)
        let busy = Self.judged(without: without, with: with, leftInPlace: [".sift/config.json"], stragglers: 2)
        let moved = Self.judged(without: without, with: with, headNow: String(repeating: "b", count: 40))

        #expect(plain.proven)
        #expect(busy.proven)
        #expect(busy.render().text.contains("  left in place: .sift/config.json — changed, but in this tool's own .sift/ directory, which a set-aside never moves"))
        #expect(busy.render().text.contains("  stopped 2 processes the run without Sources/ left running, before putting the changes back"))
        #expect(moved.render().text.hasPrefix("⚠ HEAD moved from aaaaaaaaaa to bbbbbbbbbb while the tests ran"))
        #expect(!moved.proven)
    }

    /// Tests xcodebuild ran in parallel clones — a scheme can turn that on with no flag on the command line — are said to have run that way, never blamed on the filter, and their assertion failures are never read as tests that did not compile.
    @Test
    func runsInParallelClonesAreSaidRatherThanBlamedOnTheFilter() throws {
        let directory = try Self.directory(holding: ["Tests/WidgetTests.swift": "import XCTest\n"])
        let contract = RunVerdict.Contract.of(["xcodebuild", "test", "-only-testing:WidgetTests"]) ?? .unreadable
        func parallel(_ ending: String, failure: String, verdict: String, exitCode: Int32) -> RunOutcome {
            var filter = RunOutputFilter(expecting: contract)
            filter.consume(Data("""
            Test suite 'WidgetTests' started on 'Clone 1 of Device - App (4242)'
            \(failure)Test case 'WidgetTests.testNaming()' \(ending) on 'Clone 1 of Device - App (4242)' (0.001 seconds)
            ** TEST \(verdict) **

            """.utf8))
            return RunOutcome(kind: .xcodebuild, logKey: "xcodebuild test", exitCode: exitCode, report: filter.finish(), log: nil, repositoryRoot: nil)
        }
        let without = parallel("failed", failure: "Tests/WidgetTests.swift:5: error: -[WidgetTests testNaming] : the widget was never named\n", verdict: "FAILED", exitCode: 65)
        let with = parallel("passed", failure: "", verdict: "SUCCEEDED", exitCode: 0)

        let judged = Self.judged(without: without, with: with, workingDirectory: directory)

        #expect(judged.render().text.hasPrefix("⚠ neither run reported a test in a form this reads — xcodebuild ran them in parallel"), "\(judged.render().text)")
        #expect(judged.render().text.contains("-parallel-testing-enabled NO"))
        #expect(!judged.proven)
    }

    /// A watcher that stopped while the changes were out is said in the answer: nothing was lost, but for part of the run a kill would have left them out of the tree.
    @Test
    func aWatcherThatStoppedIsSaid() {
        let without = Self.run(["shoutingWorks()": false])
        let with = Self.run(["shoutingWorks()": true])
        let record = SetAsideRecord(id: "0123456789", pathspecs: ["Sources/"], directory: "", head: String(repeating: "a", count: 40), owner: 1, entries: [])

        let answer = RunWithoutAnswer(
            pathspecs: "Sources/",
            without: without,
            with: with,
            restored: SetAside.Restored(record: record, kept: [], headNow: nil),
            workingDirectory: URL(fileURLWithPath: "/nonexistent"),
            repositoryRoot: URL(fileURLWithPath: "/nonexistent"),
            watcherLost: true
        )

        #expect(answer.render().text.contains(RunWithoutAnswer.watcherLostLine))
        #expect(!Self.answer(without: without, with: with).text.contains("the watcher"))
    }

    /// Only every test failing without and passing with is proven; a test that pins nothing, one that fails both ways, and a run that reported no test are not.
    @Test
    func onlyEveryTestPinningIsProven() {
        #expect(Self.judged(without: Self.run(["a()": false, "b()": false]), with: Self.run(["a()": true, "b()": true])).proven)
        #expect(!Self.judged(without: Self.run(["a()": false, "b()": true]), with: Self.run(["a()": true, "b()": true])).proven)
        #expect(!Self.judged(without: Self.run(["a()": false]), with: Self.run(["a()": false])).proven)
        #expect(!Self.judged(without: Self.run([:]), with: Self.run([:])).proven)
    }
}

// MARK: - A module the run could not find

extension RunWithoutAnswerTests {
    /// A module an `xcodebuild` run without the change cannot find is not evidence the tests need the change: that run builds in derived data of its own, where a module only ever built elsewhere — by another scheme, into the caller's DerivedData — is missing.
    ///
    /// With no path set aside that defines a build or is named for the module, the headline names the module, says what it checked and how it read it, and counts nothing as pinning.
    @Test
    func aModuleTheWithoutBuildCannotFindIsNotCountedAsPinning() throws {
        let directory = try Self.directory(holding: ["Tests/WidgetTests/WidgetTests.swift": "import Testing\nimport Sidecar\n"])
        let without = Self.failedBeforeTests("Tests/WidgetTests/WidgetTests.swift:2:8: error: no such module 'Sidecar'\n", xcodebuild: true)

        let judged = Self.judged(without: without, with: Self.run(["shoutingWorks()": true]), workingDirectory: directory)
        let lines = judged.render().text.split(separator: "\n").map(String.init)

        #expect(lines.first == "⚠ module 'Sidecar' could not be found without Sources/ — none of the paths set aside is a manifest, lockfile, project, settings or module-map file this recognises, or a folder or built-module file named for it, so it is read as missing from this run's own build directory, not as evidence; nothing was proven")
        #expect(lines.contains("  without Sources/, module 'Sidecar' could not be found:"), "\(lines)")
        #expect(lines.contains("    Tests/WidgetTests/WidgetTests.swift:2:8: error: no such module 'Sidecar'"))
        #expect(!lines.contains(where: { $0.contains("did not compile") }), "\(lines)")
        #expect(lines.contains("  ⚠ shoutingWorks() — did not run without Sources/; passed with it"), "\(lines)")
        #expect(!judged.proven, "a module the run could not find is never proof")
    }

    /// The dependency scanner's wording is a missing module too — what Xcode 27 prints, and the wording reported for Xcode 16 — so neither reads as the tests needing the change.
    ///
    /// The first is a capture from a scratch package whose test imported a module nothing built (see ``xcode27MissingModule(in:)``); the second is the Xcode 16 wording as reported, not captured here. What `swift test` prints for the same package is read as evidence instead: see ``aModuleSwiftTestCannotFindWithoutTheChangeIsEvidence(_:_:)``.
    @Test(arguments: ["xcode 27", "xcode 16"])
    func theDependencyScannersWordingIsAMissingModuleToo(_ toolchain: String) throws {
        let directory = try Self.directory(holding: ["Tests/WidgetTests/WidgetTests.swift": "import Testing\nimport Widget\nimport Sidecar\n"])
        let without = switch toolchain {
        case "xcode 27": Self.failedBeforeTests(Self.xcode27MissingModule(in: directory), xcodebuild: true)
        default: Self.failedBeforeTests(Self.xcode27MissingModule(in: directory).replacing("Unable to resolve module dependency", with: "Unable to find module dependency"), xcodebuild: true)
        }

        let judged = Self.judged(without: without, with: Self.run(["shoutingWorks()": true]), workingDirectory: directory)
        let lines = judged.render().text.split(separator: "\n").map(String.init)

        #expect(lines.first?.hasPrefix("⚠ module 'Sidecar' could not be found without Sources/ — ") == true, "\(lines)")
        #expect(lines.contains { $0.hasPrefix("    Tests/WidgetTests/WidgetTests.swift:3:8: error: ") && $0.contains("module dependency: 'Sidecar'") }, "\(lines)")
        #expect(!lines.contains { $0.contains("did not compile") || $0.contains("evidence they need it") }, "\(lines)")
        #expect(lines.contains("  ⚠ shoutingWorks() — did not run without Sources/; passed with it"), "\(lines)")
        #expect(!judged.proven)
    }

    /// A module the run with the change cannot find is the tests not compiling, as any other error in a test file is: that run builds where the caller's builds do, so the change — a module renamed in `Package.swift`, one test's import missed — is the first suspect, never a reason set apart from it.
    @Test(arguments: ["xcode 27", "no such module"])
    func aModuleTheWithBuildCannotFindIsTheTestsNotCompilingWithIt(_ wording: String) throws {
        let directory = try Self.directory(holding: ["Tests/WidgetTests/WidgetTests.swift": "import Testing\nimport Widget\nimport Sidecar\n"])
        let with = wording == "xcode 27"
            ? Self.failedBeforeTests(Self.xcode27MissingModule(in: directory), xcodebuild: true)
            : Self.failedBeforeTests("Tests/WidgetTests/WidgetTests.swift:3:8: error: no such module 'Sidecar'\n")

        let judged = Self.judged(without: Self.run(["shoutingWorks()": false]), with: with, workingDirectory: directory)
        let lines = judged.render().text.split(separator: "\n").map(String.init)

        #expect(lines.first == "✘ the tests do not compile with Sources/ — nothing was proven", "\(lines)")
        #expect(lines.contains("  with it, the tests did not compile:"), "\(lines)")
        #expect(!lines.contains { $0.contains("could not be found") }, "\(lines)")
        #expect(!judged.proven)
    }

    /// Where a path set aside could be what provides the module — a build definition, a lockfile or a module map, a file in a folder named for it with or without an extension, or a built module's own file — the answer says the change may provide it, and still counts it neither way: nothing it checked tells the two readings apart.
    @Test(arguments: [
        "Package.swift", "Kit/Package@swift-6.0.swift", "App.xcodeproj/project.pbxproj", "App.xcworkspace/contents.xcworkspacedata",
        "Config/Base.xcconfig", "project.yml", "Project.swift", "Sources/Sidecar/Sidecar.swift",
        "Package.resolved", "Sources/csidecar/include/module.modulemap",
        "Frameworks/Sidecar.xcframework/Info.plist",
        "Frameworks/Sidecar.xcframework/macos-arm64/Kit.framework/Modules/Kit.swiftmodule/arm64-apple-macos.swiftinterface",
        "Frameworks/Sidecar.swiftmodule", "Frameworks/Sidecar.private.swiftinterface",
    ])
    func aModuleTheChangeMayProvideIsSaidToBe(_ setAside: String) throws {
        let directory = try Self.directory(holding: ["Tests/WidgetTests/WidgetTests.swift": "import Testing\nimport Widget\nimport Sidecar\n"])
        let without = Self.failedBeforeTests(Self.xcode27MissingModule(in: directory), xcodebuild: true)

        let judged = Self.judged(without: without, with: Self.run(["shoutingWorks()": true]), workingDirectory: directory, alsoSetAside: [setAside])
        let lines = judged.render().text.split(separator: "\n").map(String.init)

        #expect(lines.first == "⚠ module 'Sidecar' could not be found without Sources/ — the change may provide it, or it is only built outside this run's build directory, so it is counted neither way; nothing was proven", "\(lines)")
        #expect(lines.contains("  ⚠ shoutingWorks() — did not run without Sources/; passed with it"), "\(lines)")
        #expect(!judged.proven)
    }

    /// A path that only shares a word with the module — a Swift file named for it in another module's folder, a folder whose name merely starts with it, a document — is not said to provide it: the headline says what was checked, and reads the module as missing from the run's own build directory.
    @Test(arguments: ["Sources/Widget/Sidecar.swift", "Sources/Sidecars/Sidecars.swift", "Docs/Sidecar.md"])
    func aPathOnlyNamedLikeTheModuleIsNotSaidToProvideIt(_ setAside: String) throws {
        let directory = try Self.directory(holding: ["Tests/WidgetTests/WidgetTests.swift": "import Testing\nimport Widget\nimport Sidecar\n"])
        let without = Self.failedBeforeTests(Self.xcode27MissingModule(in: directory), xcodebuild: true)

        let judged = Self.judged(without: without, with: Self.run(["shoutingWorks()": true]), workingDirectory: directory, alsoSetAside: [setAside])
        let lines = judged.render().text.split(separator: "\n").map(String.init)

        #expect(lines.first == "⚠ module 'Sidecar' could not be found without Sources/ — none of the paths set aside is a manifest, lockfile, project, settings or module-map file this recognises, or a folder or built-module file named for it, so it is read as missing from this run's own build directory, not as evidence; nothing was proven", "\(lines)")
        #expect(!judged.proven)
    }

    /// A module `swift test` cannot find without the change is evidence the tests need it, as any other error in a test file is: SwiftPM builds the package's whole graph into the scratch path, so nothing a test there imports is only ever built elsewhere — the module is one the package, as set aside, does not provide.
    ///
    /// The case that makes it matter: a change adds `Sidecar` to a test target's dependencies in `Package.swift` and a test imports it. Set aside, Swift 6.4 prints its dependency scanner's error (``swiftTestMissingModule(in:)``), which is the tests needing `Package.swift` — never a neutral answer. With nothing set aside that could provide the module, it is evidence too, as it always was.
    @Test(arguments: [["Package.swift"], []], ["swift 6.4", "no such module"])
    func aModuleSwiftTestCannotFindWithoutTheChangeIsEvidence(_ setAside: [String], _ wording: String) throws {
        let directory = try Self.directory(holding: ["Tests/WidgetTests/WidgetTests.swift": "import Testing\nimport Widget\nimport Sidecar\n"])
        let without = wording == "swift 6.4"
            ? Self.failedBeforeTests(Self.swiftTestMissingModule(in: directory))
            : Self.failedBeforeTests("Tests/WidgetTests/WidgetTests.swift:3:8: error: no such module 'Sidecar'\n")

        let judged = Self.judged(without: without, with: Self.run(["shoutingWorks()": true]), workingDirectory: directory, alsoSetAside: setAside)
        let lines = judged.render().text.split(separator: "\n").map(String.init)

        #expect(lines.first == "◇ the tests did not compile without Sources/ — evidence they need it, not a failing assertion; 1 of 1 passes with it", "\(lines)")
        #expect(lines.contains { $0.hasPrefix("    Tests/WidgetTests/WidgetTests.swift:3:8: error: ") && $0.contains("'Sidecar'") }, "\(lines)")
        #expect(lines.contains("  ◇ shoutingWorks() — passes with it; without Sources/ it did not compile — needed, not pinned"), "\(lines)")
        #expect(!lines.contains { $0.contains("could not be found") }, "\(lines)")
        #expect(!judged.proven, "tests that did not compile are evidence, not the proof")
    }

    /// Another compile error in a test file beside a missing module is the tests not compiling, as before — evidence — and the module's error is quoted with it rather than standing for the rest.
    @Test(arguments: ["Unable to resolve module dependency: 'Sidecar' (in target 'WidgetTests-product' from project 'Widget')", "no such module 'Sidecar'"])
    func anotherTestCompileErrorBesideAMissingModuleIsStillEvidence(_ missing: String) throws {
        let directory = try Self.directory(holding: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\nimport Widget\nimport Sidecar\n",
            "Tests/WidgetTests/LegacyWidgetTests.swift": "import XCTest\n",
        ])
        let without = Self.failedBeforeTests("""
        Tests/WidgetTests/WidgetTests.swift:3:8: error: \(missing)
        Tests/WidgetTests/LegacyWidgetTests.swift:5:9: error: cannot find 'shout' in scope

        """, xcodebuild: true)

        let judged = Self.judged(without: without, with: Self.run(["shoutingWorks()": true]), workingDirectory: directory)
        let lines = judged.render().text.split(separator: "\n").map(String.init)

        #expect(lines.first == "◇ the tests did not compile without Sources/ — evidence they need it, not a failing assertion; 1 of 1 passes with it", "\(lines)")
        #expect(lines.contains("    Tests/WidgetTests/LegacyWidgetTests.swift:5:9: error: cannot find 'shout' in scope"), "\(lines)")
        #expect(lines.contains("    Tests/WidgetTests/WidgetTests.swift:3:8: error: \(missing)"), "\(lines)")
    }

    /// Where the module rule holds, only its own errors — the ones in test files — are quoted, and every other error the run printed is counted rather than dropped, so an error the change caused elsewhere never vanishes from the answer.
    @Test(arguments: ["Unable to resolve module dependency: 'Sidecar' (in target 'WidgetTests-product' from project 'Widget')", "no such module 'Sidecar'"])
    func aMissingModuleQuotesItsOwnErrorsAndCountsTheRest(_ missing: String) throws {
        let directory = try Self.directory(holding: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\nimport Widget\nimport Sidecar\n",
            "Sources/Widget/Widget.swift": "import Foundation\n",
        ])
        let without = Self.failedBeforeTests("""
        Sources/Widget/Widget.swift:3:5: error: cannot find 'Gadget' in scope
        Tests/WidgetTests/WidgetTests.swift:3:8: error: \(missing)

        """, xcodebuild: true)

        let judged = Self.judged(without: without, with: Self.run(["shoutingWorks()": true]), workingDirectory: directory)
        let lines = judged.render().text.split(separator: "\n").map(String.init)

        #expect(lines.first?.hasPrefix("⚠ module 'Sidecar' could not be found without Sources/ — ") == true, "\(lines)")
        #expect(lines.contains("  without Sources/, module 'Sidecar' could not be found:"), "\(lines)")
        #expect(lines.contains("    Tests/WidgetTests/WidgetTests.swift:3:8: error: \(missing)"), "\(lines)")
        #expect(lines.contains("    +1 other error — see the raw log"), "\(lines)")
        #expect(!lines.contains { $0.contains("Sources/Widget/Widget.swift:3:5") }, "\(lines)")
    }
}

// MARK: - Pathspecs run together with the command

extension RunWithoutAnswerTests {
    /// A second pathspec written beside the first, rather than behind a `--without` of its own, is refused for what it is — and the refusal hands back the whole command, every pathspec behind a flag of its own.
    ///
    /// Passthrough capture reads it as the command, so the refusal a caller used to get was "`Sources/Depot.swift -- swift test --filter …` is neither" — true, unhelpful, and the reason the workaround was to name the directory above both and set aside everything under it. The remedy is runnable as it stands, so it spells the pathspecs `--without` already took as well: one that spelled only the run-together ones would set aside half the change and call the rest unpinned.
    @Test
    func extraPathspecsBesideTheFirstAreRefusedAsPathspecs() {
        Self.expectPathspecRefusal(
            of: ["Sources/Orchard.swift", "--", "swift", "test", "--filter", "WidgetTests"],
            besides: ["Sources/Depot.swift"],
            naming: ["Sources/Orchard.swift"],
            remedy: "--without Sources/Depot.swift --without Sources/Orchard.swift"
        )
        Self.expectPathspecRefusal(
            of: ["Sources/Orchard.swift", "Tests/WidgetTests/WidgetTests.swift", "--", "xcodebuild", "test", "-only-testing:WidgetTests"],
            besides: ["Sources/Depot.swift"],
            naming: ["Sources/Orchard.swift", "Tests/WidgetTests/WidgetTests.swift"],
            remedy: "--without Sources/Depot.swift --without Sources/Orchard.swift --without Tests/WidgetTests/WidgetTests.swift"
        )
    }

    /// A `--without-line` run with a stray token before its command names the flag it was actually given, not `--without`: the run named itself `--without-line`, and the refusal reads that back rather than assuming the other flag.
    @Test
    func extraPathspecsBesideALineRunNameTheLineFlag() throws {
        do {
            try RunWithoutArguments.check(
                ["Sources/Orchard.swift", "--", "swift", "test", "--filter", "WidgetTests"],
                pathspecs: [],
                environment: [:],
                flag: "--without-line"
            )
            Issue.record("a pathspec run together with a --without-line command was accepted")
        } catch let error as RunWithoutError {
            guard case let .pathspecsRunTogether(_, all, flag) = error else {
                Issue.record("refused as \(error)")
                return
            }
            #expect(flag == "--without-line")
            #expect(all == ["Sources/Orchard.swift"])
            #expect(error.description.contains("`--without-line Sources/Orchard.swift`"), "\(error.description)")
            #expect(!error.description.contains(" --without "), "\(error.description)")
        }
    }

    /// Checks that `arguments`, beside the pathspecs `--without` already took, is refused for the pathspecs run together with the command — naming them, and handing back `remedy` as the whole corrected flag list.
    private static func expectPathspecRefusal(
        of arguments: [String],
        besides pathspecs: [String],
        naming extra: [String],
        remedy: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            try RunWithoutArguments.check(arguments, pathspecs: pathspecs, environment: [:])
            Issue.record("\(arguments) was accepted", sourceLocation: sourceLocation)
        } catch let error as RunWithoutError {
            guard case let .pathspecsRunTogether(named, all, _) = error else {
                Issue.record("\(arguments) was refused as \(error)", sourceLocation: sourceLocation)
                return
            }
            #expect(named == extra, sourceLocation: sourceLocation)
            #expect(all == pathspecs + extra, sourceLocation: sourceLocation)
            #expect(error.description.contains("takes one pathspec, and repeats"), sourceLocation: sourceLocation)
            #expect(error.description.contains("`\(remedy)`"), "\(error.description)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("\(arguments) was refused as \(error)", sourceLocation: sourceLocation)
        }
    }

    /// The terminator is optional — `sift run swift build` is a spelling of its own — so the same mistake written without one draws the same refusal: what makes it that mistake is a command starting partway along the list, not a `--` in front of it.
    @Test
    func extraPathspecsAreRefusedWithoutATerminatorToo() throws {
        do {
            try RunWithoutArguments.check(
                ["Sources/Orchard.swift", "swift", "test", "--filter", "WidgetTests"],
                pathspecs: ["Sources/Depot.swift"],
                environment: [:]
            )
            Issue.record("a pathspec run together with a command carrying no terminator was accepted")
        } catch let error as RunWithoutError {
            guard case let .pathspecsRunTogether(named, all, _) = error else {
                Issue.record("refused as \(error)")
                return
            }
            #expect(named == ["Sources/Orchard.swift"])
            #expect(all == ["Sources/Depot.swift", "Sources/Orchard.swift"])
        }
    }

    /// A terminator the wrapped command carries itself is not a pathspec run together with it: the tokens in front of one name the command, and the refusal owed is about the command.
    @Test
    func aCommandThatCarriesItsOwnTerminatorIsNotReadAsAPathspec() throws {
        try RunWithoutArguments.check(["swift", "test", "--filter", "WidgetTests", "--", "--verbose"], pathspecs: [], environment: [:])

        do {
            // Nothing further along names a command either, so what is in front of it is no pathspec.
            try RunWithoutArguments.check(["Sources/Depot.swift", "--", "ls"], pathspecs: [], environment: [:])
            Issue.record("a command this cannot run was accepted")
        } catch let error as RunWithoutError {
            guard case .notATestRun = error else {
                Issue.record("refused as \(error)")
                return
            }
        }
    }

    /// A wrapper ahead of the command — `env FOO=1`, `xcrun`, `caffeinate` — is not a pathspec run together with it just because it sits in front of a recognised command too: neither token looks like a path (no `/`, no known extension, nothing on disk by that name), so the weaker refusal is owed instead of one that would tell the caller to set `env` and `FOO=1` aside.
    @Test
    func aWrapperAheadOfTheCommandIsNotReadAsAPathspec() throws {
        do {
            try RunWithoutArguments.check(
                ["/usr/bin/env", "FOO=1", "swift", "test", "--filter", "X"],
                pathspecs: ["Sources/Depot.swift"],
                environment: [:]
            )
            Issue.record("a wrapper ahead of the command was accepted")
        } catch let error as RunWithoutError {
            guard case .notATestRun = error else {
                Issue.record("refused as \(error), which tells the caller to set aside a wrapper token")
                return
            }
        }
    }
}

// MARK: - A test file set aside beside the sources

extension RunWithoutAnswerTests {
    /// A test file set aside beside the sources means the committed test ran, and the verdict that it pins nothing says so rather than leaving the caller to read it as their fix being unpinned.
    ///
    /// The committed test passes against the committed sources by construction, so the line is true of a test they did not write. The remedy it names is the technique, since no flag can do it: the test has to compile against the old sources to run against them — which a change that declares what the test names leaves no way to do, and the note says that too.
    @Test
    func aTestFileSetAsideBesideTheSourcesIsSaidUnderTheVerdict() throws {
        let directory = try Self.directory(holding: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\n@testable import Widgets\n@Test func shoutingWorks() {}\n",
        ])

        let judged = Self.judged(
            without: Self.run(["shoutingWorks()": true]),
            with: Self.run(["shoutingWorks()": true]),
            // The record's paths are the repository's, and the run was made a directory down from it.
            workingDirectory: directory.appendingPathComponent("Tests"),
            repositoryRoot: directory,
            alsoSetAside: ["Tests/WidgetTests/WidgetTests.swift"]
        )
        let lines = judged.render().text.split(separator: "\n").map(String.init)

        #expect(lines.contains("  ✘ shoutingWorks() — passes without Sources/ too, so it pins nothing"))
        #expect(lines.contains("  note: Tests/WidgetTests/WidgetTests.swift was also set aside, so this ran the committed test, not your edited one. To gate an edited test against old sources, leave the test file out of --without and write its assertions to compile against them. Where the change declares what the test has to name — a new case, method or type — no assertion compiles against the old sources, and the most this can show is that the tests needed the change, not a failing assertion."), "\(lines)")
    }

    /// The note is said of a set-aside file that declares the test however the file imports: one spelled past a pattern, or re-exported through another module, would otherwise leave the committed test's verdict read as the edited one's.
    @Test(arguments: [
        "@preconcurrency import Testing\n",
        "import Widgets\n",
    ])
    func theNoteIsSaidOfATestFileHoweverItImports(imports: String) throws {
        let directory = try Self.directory(holding: [
            "Tests/WidgetTests/WidgetTests.swift": imports + "@Test func shoutingWorks() {}\n",
        ])

        let judged = Self.judged(
            without: Self.run(["shoutingWorks()": true]),
            with: Self.run(["shoutingWorks()": true]),
            workingDirectory: directory,
            alsoSetAside: ["Tests/WidgetTests/WidgetTests.swift"]
        )

        #expect(judged.render().text.contains("  note: Tests/WidgetTests/WidgetTests.swift was also set aside, so this ran the committed test, not your edited one."), "\(imports)")
    }

    /// The note is said of a set-aside file whose test is declared past the window a partial read of the file would stop at: a file this large must still be read whole, or a change that only touched a late test reads as pinning nothing.
    @Test
    func theNoteIsSaidOfATestDeclaredPastAPartialReadsWindow() throws {
        let padding = String(repeating: "// padding\n", count: 30000)
        let directory = try Self.directory(holding: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\n" + padding + "@Test func shoutingWorks() {}\n",
        ])

        let judged = Self.judged(
            without: Self.run(["shoutingWorks()": true]),
            with: Self.run(["shoutingWorks()": true]),
            workingDirectory: directory.appendingPathComponent("Tests"),
            repositoryRoot: directory,
            alsoSetAside: ["Tests/WidgetTests/WidgetTests.swift"]
        )

        #expect(judged.render().text.contains("  note: Tests/WidgetTests/WidgetTests.swift was also set aside, so this ran the committed test, not your edited one."))
    }

    /// A test framework's import is recognised however it is spelled — behind attributes, an access level, or naming one declaration out of the module — and a module that merely begins with the framework's name is not one.
    @Test(arguments: [
        ("import Testing\n", true),
        ("@testable import XCTest\n", true),
        ("@preconcurrency import Testing\n", true),
        ("@_exported import XCTest\n", true),
        ("@_spi(Experimental) import Testing\n", true),
        ("public import Testing\n", true),
        ("@preconcurrency internal import XCTest\n", true),
        ("import struct Testing.Test\n", true),
        ("import func XCTest.XCTAssertEqual\n", true),
        ("import Foundation\n", false),
        ("import Testings\n", false),
        ("// import Testing is what this would need\n", false),
    ])
    func aTestFrameworkImportIsRecognisedHoweverItIsSpelled(text: String, imports: Bool) {
        #expect(RunWithoutAnswer.importsATestFramework(text) == imports, "\(text)")
    }

    /// The note is owed only where all three facts meet: a test file was set aside, some test's verdict is that it pins nothing, and that file is where that test is written.
    ///
    /// A test file set aside beside a test that ran from the tree all along explains nothing about that test's verdict, which is honest as it stands — and a note over it talks the caller out of a correct negative, which is the failure this note exists to prevent, inverted.
    @Test
    func theNoteIsSaidOnlyOfATestTheSetAsideTookOutOfTheTree() throws {
        let directory = try Self.directory(holding: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\n@testable import Widgets\n@Test func shoutingWorks() {}\n",
            "Tests/WidgetTests/HelperTests.swift": "import Testing\n@testable import Widgets\n@Test func reachesWidgetThroughTheHelper() {}\n",
            "Sources/Widgets/Widget.swift": "import Foundation\n",
        ])
        func judged(alsoSetAside: [String], without: [String: Bool]) -> RunWithoutAnswer {
            Self.judged(
                without: Self.run(without),
                with: Self.run(["shoutingWorks()": true]),
                workingDirectory: directory,
                alsoSetAside: alsoSetAside
            )
        }

        let sourcesOnly = judged(alsoSetAside: ["Sources/Widgets/Widget.swift"], without: ["shoutingWorks()": true])
        let pinning = judged(alsoSetAside: ["Tests/WidgetTests/WidgetTests.swift"], without: ["shoutingWorks()": false])
        let anotherTestFile = judged(alsoSetAside: ["Tests/WidgetTests/HelperTests.swift"], without: ["shoutingWorks()": true])

        #expect(!sourcesOnly.render().text.contains("note:"), "no test file was set aside")
        #expect(!pinning.render().text.contains("note:"), "every test pinned, so no verdict is owed a note")
        #expect(!anotherTestFile.render().text.contains("note:"), "the test that pinned nothing was never out of the tree")
    }

    /// A set-aside file that merely mentions the pinning-nothing test's name — in a comment, not a declaration — is not attributed as the reason: the test that pinned nothing lives in a file that was never set aside, and a note here would be the false attribution the docstring says this must avoid.
    @Test
    func aFileThatOnlyMentionsTheTestsNameIsNotAttributed() throws {
        let directory = try Self.directory(holding: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\n@testable import Widgets\n@Test func testNaming() {}\n",
            "Tests/WidgetTests/HelperTests.swift": "import Testing\n@testable import Widgets\n// See testNaming() for how names are chosen.\n@Test func reachesWidgetThroughTheHelper() {}\n",
        ])

        let judged = Self.judged(
            without: Self.run(["testNaming()": true]),
            with: Self.run(["testNaming()": true]),
            workingDirectory: directory,
            alsoSetAside: ["Tests/WidgetTests/HelperTests.swift"]
        )

        #expect(!judged.render().text.contains("note:"), "\(judged.render().text)")
    }
}

extension RunWithoutAnswerTests {
    /// A compiler crash as a build before its tests prints one: its only line at a file and line is the crash reader's.
    private static var compilerCrash: String {
        """
        <unknown>:0: error: fatal error encountered during compilation; please submit a bug report (https://swift.org/contributing/#reporting-bugs) and include the crash backtrace
        Please submit a bug report (https://swift.org/contributing/#reporting-bugs) and include the crash backtrace.
        Stack dump:
        0.\tProgram arguments: swift-frontend -frontend -c Sources/Widgets/Widget.swift
        1.\tWhile running pass #12 SILFunctionTransform "CopyPropagation" on SILFunction "@$s6Widget6RunnerV3runyyKF".
        error: Build failed

        """
    }

    /// A run that failed with `log` and reported no test — `xcodebuild test` where `xcodebuild`, `swift test` otherwise.
    static func failedBeforeTests(_ log: String, xcodebuild: Bool = false) -> RunOutcome {
        let contract = xcodebuild ? RunVerdict.Contract.of(["xcodebuild", "test", "-only-testing:WidgetTests"]) ?? .unreadable : .runTally
        var filter = RunOutputFilter(expecting: contract)
        filter.consume(Data(log.utf8))
        return RunOutcome(
            kind: xcodebuild ? .xcodebuild : .swiftTest,
            logKey: xcodebuild ? "xcodebuild test" : "swift test",
            exitCode: xcodebuild ? 65 : 1,
            report: filter.finish(),
            log: nil,
            repositoryRoot: nil
        )
    }

    /// What `xcodebuild test -only-testing:` printed under Xcode 27 when a test imported a module nothing built — captured from a scratch package, with its names replaced by this suite's and its absolute path by `directory`'s.
    private static func xcode27MissingModule(in directory: URL) -> String {
        let file = directory.appendingPathComponent("Tests/WidgetTests/WidgetTests.swift").path
        return """
        SwiftDriver WidgetTests normal arm64 com.apple.xcode.tools.swift.compiler (in target 'WidgetTests-product' from project 'Widget')
        \(file):3:8: error: Unable to resolve module dependency: 'Sidecar' (in target 'WidgetTests-product' from project 'Widget')
            note: A dependency of main module 'WidgetTests'
        \(file):3:8: note: A dependency of main module 'WidgetTests'
        import Sidecar
               ^ (in target 'WidgetTests-product' from project 'Widget')

        Testing failed:
        \tUnable to resolve module dependency: 'Sidecar'
        \tTesting cancelled because the build failed.

        ** TEST FAILED **


        The following build commands failed:
        \tSwiftDriver WidgetTests normal arm64 com.apple.xcode.tools.swift.compiler (in target 'WidgetTests-product' from project 'Widget')
        \tTesting workspace Widget with scheme Widget-Package
        (2 failures)

        """
    }

    /// What `swift test` printed under Swift 6.4 for the same package — the location after the severity, then the build system's own failures — with the names and path replaced the same way and the driver's command line cut short.
    private static func swiftTestMissingModule(in directory: URL) -> String {
        let file = directory.appendingPathComponent("Tests/WidgetTests/WidgetTests.swift").path
        return """
        Building for debugging...
        [Planning deferred tasks]
        error: \(file):3:8 unable to resolve module dependency: 'Sidecar'
        error: SwiftDriver WidgetTests normal arm64 com.apple.xcode.tools.swift.compiler failed with a nonzero exit code. Command line:     cd \(directory.path)/.build
            builtin-SwiftDriver -- swiftc -parse-as-library -module-name WidgetTests -Onone
        error: Build failed
        error: fatalError

        """
    }

    /// A temporary directory holding `files`, each at its relative path.
    static func directory(holding files: [String: String]) throws -> URL {
        let directory = try TemporaryDirectory.make("answer").appendingPathComponent("answer")
        for (path, text) in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return directory
    }

    /// A `swift test` run in which each named test passed or failed.
    static func run(_ results: [String: Bool]) -> RunOutcome {
        var transcript = ""
        for (name, passed) in results.sorted(by: { $0.key < $1.key }) {
            if passed {
                transcript += "\u{10105B}  Test \(name) passed after 0.001 seconds.\n"
            } else {
                transcript += "\u{1008A4}  Test \(name) recorded an issue at WidgetTests.swift:7:9: Expectation failed: (reflowed → 3) == 1\n"
                transcript += "\u{1008A4}  Test \(name) failed after 0.001 seconds with 1 issue.\n"
            }
        }
        let failures = results.values.count { !$0 }
        let verdict = failures == 0 ? "passed after 0.001 seconds." : "failed after 0.001 seconds with \(failures) issue\(failures == 1 ? "" : "s")."
        transcript += "\u{10105B}  Test run with \(results.count) test\(results.count == 1 ? "" : "s") in 1 suite \(verdict)\n"
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(Data(transcript.utf8))
        return RunOutcome(kind: .swiftTest, logKey: "swift test", exitCode: failures == 0 ? 0 : 1, report: filter.finish(), log: nil, repositoryRoot: nil)
    }

    static func judged(
        without: RunOutcome,
        with: RunOutcome,
        workingDirectory: URL = URL(fileURLWithPath: "/nonexistent"),
        repositoryRoot: URL? = nil,
        leftInPlace: [String] = [],
        stragglers: Int = 0,
        headNow: String? = nil,
        retries: Bool = false,
        buildDirectory: String? = nil,
        buildDirectorySize: Int64? = nil,
        changedTests: Set<String>? = nil,
        alsoSetAside: [String] = [],
        newFiles: [String] = [],
        since: String? = nil,
        selector: RunTestSelector? = nil
    ) -> RunWithoutAnswer {
        let record = SetAsideRecord(
            id: "0123456789",
            pathspecs: ["Sources/"],
            directory: "",
            head: String(repeating: "a", count: 40),
            since: since,
            owner: 1,
            entries: [
                SetAsideRecord.Entry(path: "Sources/staged.txt", status: "1 M. N... 100644 100644 100644 a b", head: nil, index: .absent, worktree: .absent),
                SetAsideRecord.Entry(path: "Sources/new.txt", status: "?", head: nil, index: .absent, worktree: .absent),
            ] + alsoSetAside.map { SetAsideRecord.Entry(path: $0, status: "?", head: nil, index: .absent, worktree: .absent) }
                // Untracked, and the tree held a file at it: the two together are what a set-aside removes outright.
                + newFiles.enumerated().map { number, path in
                    SetAsideRecord.Entry(
                        path: path,
                        status: "?",
                        head: nil,
                        index: .absent,
                        worktree: .file(permissions: 0o644, sha256: String(repeating: "b", count: 64), copy: "\(number)")
                    )
                },
            leftInPlace: leftInPlace
        )
        return RunWithoutAnswer(
            pathspecs: "Sources/",
            without: without,
            with: with,
            restored: SetAside.Restored(record: record, kept: [], headNow: nil),
            workingDirectory: workingDirectory,
            repositoryRoot: repositoryRoot ?? workingDirectory,
            stragglers: stragglers,
            headNow: headNow,
            retriesFailures: retries,
            buildDirectory: buildDirectory,
            buildDirectorySize: buildDirectorySize,
            changedTests: changedTests,
            selector: selector
        )
    }

    private static func answer(without: RunOutcome, with: RunOutcome) -> RunOutcome.Answer {
        judged(without: without, with: with).render()
    }
}

// MARK: - The tests the change never wrote

/// Covers the listing's fold: a test the change did not write passing both ways is the expected case, counted into one line, and only a test it *did* write draws the verdict that it pins nothing.
extension RunWithoutAnswerTests {
    /// A filter naming a whole suite runs mostly tests the change never touched, and one line apiece for them buries the two that mattered — so they are counted instead.
    @Test
    func theTestsTheChangeNeverWroteAreCountedIntoOneLine() {
        let results = ["shoutingWorks()": false, "sizeIsCarried()": true, "theGridReflows()": true, "theGridReflowsAfterARotation()": true]
        let judged = Self.judged(
            without: Self.run(results),
            with: Self.run(results.mapValues { _ in true }),
            changedTests: ["shoutingWorks"]
        )
        let lines = judged.render().text.split(separator: "\n").map(String.init)

        #expect(lines.contains("  3 tests the change does not touch pass without Sources/ too — expected, so they are not listed"), "\(lines)")
        #expect(lines.contains("  ✔ shoutingWorks() — fails without Sources/, passes with it"))
        #expect(!lines.contains { $0.contains("sizeIsCarried") }, "an untouched test is counted, not named")
        // The headline counts the tests the listing names, not the ones folded beside them.
        #expect(lines.first == "✔ 1 of 1 fails without Sources/ and passes with it")
    }

    /// A suite-wide filter over one written test that pins is a proof, however many untouched tests ran beside it — the case the fold exists for, so it must not headline a failure or exit as one.
    @Test
    func aWrittenTestThatPinsIsProvenWhateverFoldedBesideIt() {
        var results = ["shoutingWorks()": false]
        for number in 0 ..< 25 {
            results["theGridReflows\(number)()"] = true
        }
        let judged = Self.judged(
            without: Self.run(results),
            with: Self.run(results.mapValues { _ in true }),
            changedTests: ["shoutingWorks"]
        )

        #expect(judged.render().text.hasPrefix("✔ 1 of 1 fails without Sources/ and passes with it\n"), "\(judged.render().text)")
        #expect(judged.proven, "every test the change wrote pins, so the run exits 0")
    }

    /// A written test that pins nothing still stops the proof, whatever folded beside it.
    @Test
    func aWrittenTestThatPinsNothingIsNotProvenBesideFoldedOnes() {
        let results = ["shoutingWorks()": true, "sizeIsCarried()": true, "theGridReflows()": true]
        let judged = Self.judged(
            without: Self.run(results),
            with: Self.run(results),
            changedTests: ["shoutingWorks"]
        )

        #expect(judged.render().text.hasPrefix("✘ 0 of 1 fail without Sources/ and pass with it\n"), "\(judged.render().text)")
        #expect(!judged.proven)
    }

    /// A test the change *did* write, passing both ways, is the finding this whole answer exists to make — it keeps its own line and its own words.
    @Test
    func aTestTheChangeWroteKeepsItsVerdictThatItPinsNothing() {
        let results = ["shoutingWorks()": true, "sizeIsCarried()": true, "theGridReflows()": true]
        let judged = Self.judged(
            without: Self.run(results),
            with: Self.run(results),
            changedTests: ["shoutingWorks"]
        )
        let lines = judged.render().text.split(separator: "\n").map(String.init)

        #expect(lines.contains("  ✘ shoutingWorks() — passes without Sources/ too, so it pins nothing"), "\(lines)")
        #expect(lines.contains("  2 tests the change does not touch pass without Sources/ too — expected, so they are not listed"))
    }

    /// One test folded is said in the singular, because a line that reads `1 tests` is a line nobody wrote on purpose.
    @Test
    func oneTestTheChangeNeverWroteIsSaidInTheSingular() {
        let results = ["shoutingWorks()": true, "sizeIsCarried()": true]
        let judged = Self.judged(
            without: Self.run(results),
            with: Self.run(results),
            changedTests: ["shoutingWorks"]
        )

        #expect(judged.render().text.contains("  1 test the change does not touch passes without Sources/ too — expected, so it is not listed"))
    }

    /// A set read and empty is the change touching no test at all, so every test that passes both ways is expected — and counted.
    @Test
    func aChangeThatTouchesNoTestFoldsEveryOneOfThem() {
        let results = ["shoutingWorks()": true, "sizeIsCarried()": true, "theGridReflows()": true]
        let judged = Self.judged(without: Self.run(results), with: Self.run(results), changedTests: [])
        let lines = judged.render().text.split(separator: "\n").map(String.init)

        #expect(lines.contains("  3 tests the change does not touch pass without Sources/ too — expected, so they are not listed"), "\(lines)")
        #expect(!lines.contains { $0.hasPrefix("  ✘ ") }, "no test was named individually")
    }

    /// Every standing here folds away as untouched-and-expected, so no test the change wrote ran: the headline says that rather than glyphing ✘ off standings the run no longer shows anybody, and nothing is proven.
    @Test
    func anAllExpectedRunDoesNotHeadlineAFailureGlyph() {
        let results = ["shoutingWorks()": true, "sizeIsCarried()": true, "theGridReflows()": true]
        let judged = Self.judged(without: Self.run(results), with: Self.run(results), changedTests: [])

        #expect(judged.render().text.hasPrefix("⚠ no test the change wrote ran under this filter — 3 untouched pass both ways; nothing was proven\n"), "\(judged.render().text)")
        #expect(!judged.proven, "no test the change wrote ran, so the run exits 1")
    }

    /// Unread — git refused, an unborn branch, a side that would not read — folds nothing: a listing is never made quieter than the evidence behind it.
    @Test
    func aChangeWhoseTestsCouldNotBeReadFoldsNothing() {
        let results = ["shoutingWorks()": true, "sizeIsCarried()": true]
        let unread = Self.judged(without: Self.run(results), with: Self.run(results), changedTests: nil)
        let lines = unread.render().text.split(separator: "\n").map(String.init)

        #expect(lines.contains("  ✘ shoutingWorks() — passes without Sources/ too, so it pins nothing"))
        #expect(lines.contains("  ✘ sizeIsCarried() — passes without Sources/ too, so it pins nothing"))
        #expect(!unread.render().text.contains("the change does not touch"))
    }

    /// The fold happens before the cap, so what keeps a long run inside it is the fold rather than the cap hiding the tests that matter.
    @Test
    func theFoldIsMadeBeforeTheListingIsCapped() {
        var results = ["shoutingWorks()": false]
        for number in 0 ..< RunWithoutAnswer.testLineCap + 4 {
            results["theGridReflows\(number)()"] = true
        }
        let judged = Self.judged(
            without: Self.run(results),
            with: Self.run(results.mapValues { _ in true }),
            changedTests: ["shoutingWorks"]
        )
        let lines = judged.render().text.split(separator: "\n").map(String.init)

        #expect(lines.contains("  \(RunWithoutAnswer.testLineCap + 4) tests the change does not touch pass without Sources/ too — expected, so they are not listed"), "\(lines)")
        #expect(lines.contains("  ✔ shoutingWorks() — fails without Sources/, passes with it"))
        #expect(!judged.render().text.contains("more: "), "the fold left the listing inside the cap")
    }

    /// A test counted away as untouched draws no note about the set-aside either: the run compared a committed test the change never wrote, which is the expected case rather than a verdict anybody could be talked out of.
    @Test
    func aTestCountedAwayDrawsNoNoteAboutTheSetAside() throws {
        let directory = try Self.directory(holding: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\n@testable import Widgets\n@Test func shoutingWorks() {}\n",
        ])
        func judged(changedTests: Set<String>?) -> RunWithoutAnswer {
            Self.judged(
                without: Self.run(["shoutingWorks()": true]),
                with: Self.run(["shoutingWorks()": true]),
                workingDirectory: directory,
                changedTests: changedTests,
                alsoSetAside: ["Tests/WidgetTests/WidgetTests.swift"]
            )
        }

        #expect(!judged(changedTests: []).render().text.contains("note:"), "the change never wrote this test")
        #expect(judged(changedTests: ["shoutingWorks"]).render().text.contains("note:"), "the change wrote it, so the verdict is owed its note")
    }

    /// A test declared `@Test("…")` prints its display name, and there is no declaration identifier inside it to match — so it is undetermined, and counting it away would delete the very line the caller needs.
    @Test
    func aTestWhoseNameIsADisplayNameIsNeverCountedAway() {
        let results = ["\"the widget keeps its heading\"": true, "sizeIsCarried()": true, "shoutingWorks()": true]
        let judged = Self.judged(
            without: Self.run(results),
            with: Self.run(results),
            // The change wrote the display-named test; nothing in the set can ever spell its printed name.
            changedTests: ["theGridReflows", "shoutingWorks"]
        )
        let lines = judged.render().text.split(separator: "\n").map(String.init)

        #expect(
            lines.contains { $0.contains("the widget keeps its heading") && $0.contains("pins nothing") },
            "a display name resolves to no declaration, so it is undetermined rather than untouched: \(lines)"
        )
        #expect(lines.contains("  1 test the change does not touch passes without Sources/ too — expected, so it is not listed"), "\(lines)")
    }

    /// The `+N more:` tail counts tests, not lines: a fold that lands past the cap still has to add up, or the tail says a smaller number than the run had.
    @Test
    func theTailCountsTheTestsACountedLineStandsFor() {
        let written = (0 ..< RunWithoutAnswer.testLineCap + 5).map { "theGridReflows\(String(format: "%02d", $0))()" }
        let untouched = (0 ..< 5).map { "theGridReflowsAfterARotation\($0)()" }
        // Every one of them passes both ways; the written ones are listed apiece, and the rest sort after them.
        let results = Dictionary(uniqueKeysWithValues: (written + untouched).map { ($0, true) })
        let judged = Self.judged(
            without: Self.run(results),
            with: Self.run(results),
            changedTests: Set(written.map { String($0.dropLast(2)) })
        )
        let lines = judged.render().text.split(separator: "\n").map(String.init)

        // 5 written tests past the cap, and the counted line standing for 5 more.
        #expect(lines.contains("  +10 more: 0 fail without Sources/ and pass with it, 10 do not — see the raw logs"), "\(lines)")
    }
}

// MARK: - Reading which tests a change wrote, from git

/// Covers ``ChangedTests/identifiers(since:in:)`` — the half that reads the range, where an answer of `[]` where `nil` is owed would count away every test on a git failure.
extension RunWithoutAnswerTests {
    /// A directory git knows nothing about cannot say what a change wrote, and the answer it owes is "unread" — which counts nothing away — rather than "nothing changed", which counts everything away.
    @Test
    func aDirectoryThatIsNoRepositoryIsUnreadRatherThanEmpty() throws {
        let directory = try TestSources.makeTempDirectory()

        #expect(ChangedTests.identifiers(since: nil, in: directory) == nil)
    }

    /// The uncommitted change, read against `HEAD`: a test file added but never committed is a test the change wrote.
    @Test
    func theTestsAnUncommittedChangeWroteAreRead() throws {
        let repository = try Self.repository(committing: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\n@Test func sizeIsCarried() {}\n",
        ])
        try "import Testing\n@Test func shoutingWorks() {}\n"
            .write(to: repository.appendingPathComponent("Tests/WidgetTests/GizmoTests.swift"), atomically: true, encoding: .utf8)

        #expect(ChangedTests.identifiers(since: nil, in: repository) == ["shoutingWorks"])
    }

    /// A range, read against the revision `--since` named: what the commits since it wrote, not what the tree holds.
    @Test
    func theTestsTheCommitsSinceARevisionWroteAreRead() throws {
        let repository = try Self.repository(committing: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\n@Test func sizeIsCarried() {}\n",
        ])
        let base = try TestSources.runGit(["rev-parse", "HEAD"], in: repository).trimmingCharacters(in: .whitespacesAndNewlines)
        try "import Testing\n@Test func sizeIsCarried() {}\n@Test func shoutingWorks() {}\n"
            .write(to: repository.appendingPathComponent("Tests/WidgetTests/WidgetTests.swift"), atomically: true, encoding: .utf8)
        try TestSources.runGit(["add", "-A"], in: repository)
        try TestSources.runGit(["commit", "-m", "a test"], in: repository)

        #expect(ChangedTests.identifiers(since: base, in: repository) == ["shoutingWorks"])
    }

    /// A range is everything since the revision, the uncommitted work beside the commits included: the set-aside leaves an uncommitted test outside its pathspecs in the tree for both runs, and a range read from its commits alone would fold that test away as untouched.
    @Test
    func aRangeReadsTheTestsWrittenUncommittedBesideItsCommits() throws {
        let repository = try Self.repository(committing: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\n@Test func sizeIsCarried() {}\n",
        ])
        let base = try TestSources.runGit(["rev-parse", "HEAD"], in: repository).trimmingCharacters(in: .whitespacesAndNewlines)
        try "import Testing\n@Test func sizeIsCarried() {}\n@Test func shoutingWorks() {}\n"
            .write(to: repository.appendingPathComponent("Tests/WidgetTests/WidgetTests.swift"), atomically: true, encoding: .utf8)
        try TestSources.runGit(["add", "-A"], in: repository)
        try TestSources.runGit(["commit", "-m", "a test"], in: repository)
        try "import Testing\n@Test func theGridReflows() {}\n"
            .write(to: repository.appendingPathComponent("Tests/WidgetTests/GizmoTests.swift"), atomically: true, encoding: .utf8)

        #expect(ChangedTests.identifiers(since: base, in: repository) == ["shoutingWorks", "theGridReflows"])
    }

    /// With no `--since`, a test committed on the branch is one the change wrote: the range runs from the branch's merge-base with the default branch, not from `HEAD`.
    ///
    /// The usual negative gate commits the test and leaves the fix uncommitted, and read against `HEAD` alone that test would fold away as untouched — leaving a neighbour that pins to carry the exit code.
    @Test
    func aTestCommittedOnTheBranchIsWrittenWithoutASince() throws {
        let repository = try Self.repository(committing: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\n@Test func sizeIsCarried() {}\n",
            "Sources/Widget/Widget.swift": "struct Widget {}\n",
        ])
        try TestSources.runGit(["switch", "-c", "feature"], in: repository)
        try "import Testing\n@Test func sizeIsCarried() {}\n@Test func shoutingWorks() {}\n"
            .write(to: repository.appendingPathComponent("Tests/WidgetTests/WidgetTests.swift"), atomically: true, encoding: .utf8)
        try TestSources.runGit(["add", "-A"], in: repository)
        try TestSources.runGit(["commit", "-m", "a test"], in: repository)
        try "struct Widget { var loud = true }\n"
            .write(to: repository.appendingPathComponent("Sources/Widget/Widget.swift"), atomically: true, encoding: .utf8)

        #expect(ChangedTests.identifiers(since: nil, in: repository) == ["shoutingWorks"])
    }

    /// Where no default branch resolves there is no merge-base to read from, and the change is the working tree against `HEAD` alone: a committed test is untouched, an uncommitted one written.
    @Test
    func withNoDefaultBranchTheChangeIsTheUncommittedOne() throws {
        let repository = try Self.repository(committing: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\n@Test func sizeIsCarried() {}\n",
        ])
        try TestSources.runGit(["branch", "-m", "trunk"], in: repository)
        try "import Testing\n@Test func sizeIsCarried() {}\n@Test func shoutingWorks() {}\n"
            .write(to: repository.appendingPathComponent("Tests/WidgetTests/WidgetTests.swift"), atomically: true, encoding: .utf8)
        try TestSources.runGit(["add", "-A"], in: repository)
        try TestSources.runGit(["commit", "-m", "a test"], in: repository)
        try "import Testing\n@Test func theGridReflows() {}\n"
            .write(to: repository.appendingPathComponent("Tests/WidgetTests/GizmoTests.swift"), atomically: true, encoding: .utf8)

        #expect(ChangedTests.identifiers(since: nil, in: repository) == ["theGridReflows"])
    }

    /// A branch already fast-forwarded into the default branch locally reads no committed range either — its merge-base with the default branch is `HEAD`, though `HEAD` is not the default branch itself — and the fold line says so and names `--since <base>`, rather than the committed test going quiet.
    @Test
    func aBranchFastForwardedIntoTheDefaultBranchDrawsNoBranchRangeNoteOnTheFoldLine() throws {
        let repository = try Self.repository(committing: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\n@Test func sizeIsCarried() {}\n",
        ])
        try TestSources.runGit(["switch", "-c", "feature"], in: repository)
        try "import Testing\n@Test func sizeIsCarried() {}\n@Test func shoutingWorks() {}\n"
            .write(to: repository.appendingPathComponent("Tests/WidgetTests/WidgetTests.swift"), atomically: true, encoding: .utf8)
        try TestSources.runGit(["add", "-A"], in: repository)
        try TestSources.runGit(["commit", "-m", "a test"], in: repository)
        // Gated again after the merge: main is force-moved onto the feature branch's own tip, still checked
        // out on feature — the branch's merge-base with main is now `HEAD`, exactly as if it had none.
        try TestSources.runGit(["branch", "-f", "main", "feature"], in: repository)

        #expect(ChangedTests.identifiers(since: nil, in: repository) == [], "no committed range is read, so the committed test itself is not among what the change wrote")

        let results = ["shoutingWorks()": true, "sizeIsCarried()": true]
        let judged = Self.judged(
            without: Self.run(results),
            with: Self.run(results),
            workingDirectory: repository,
            repositoryRoot: repository,
            changedTests: []
        )
        let text = judged.render().text

        #expect(text.contains("no branch range was found"), "\(text)")
        #expect(text.contains("--since <base>"), "\(text)")
    }

    /// A branch just created with no commits of its own reads the same empty merge-base as a fast-forwarded one, for an unrelated reason — there is nothing to name a base for, and `--since <base>` would change nothing — as every agent worktree reads before its first commit.
    @Test
    func aFreshBranchWithNoCommitsOfItsOwnDrawsNoNote() throws {
        let repository = try Self.repository(committing: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\n@Test func sizeIsCarried() {}\n",
        ])
        try TestSources.runGit(["switch", "-c", "fix/x"], in: repository)

        #expect(ChangedTests.noBranchRangeNote(since: nil, in: repository) == nil)
    }

    /// A branch that has never diverged from the default branch — created from an earlier point of it and never committed to since — reads the same empty merge-base as a fast-forwarded one, but has taken no commits of its own for `--since <base>` to name.
    @Test
    func aBranchBehindTheDefaultBranchDrawsNoNote() throws {
        let repository = try Self.repository(committing: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\n@Test func sizeIsCarried() {}\n",
        ])
        try TestSources.runGit(["switch", "-c", "feature"], in: repository)
        try TestSources.runGit(["switch", "main"], in: repository)
        try "import Testing\n@Test func sizeIsCarried() {}\n@Test func shoutingWorks() {}\n"
            .write(to: repository.appendingPathComponent("Tests/WidgetTests/WidgetTests.swift"), atomically: true, encoding: .utf8)
        try TestSources.runGit(["add", "-A"], in: repository)
        try TestSources.runGit(["commit", "-m", "main moves on"], in: repository)
        try TestSources.runGit(["switch", "feature"], in: repository)

        #expect(ChangedTests.noBranchRangeNote(since: nil, in: repository) == nil)
    }

    /// A branch behind the default branch that catches up with `merge --ff-only` (what `pull` does under the hood) never committed anything of its own — its reflog's newest entry is the fast-forward, not a commit — so it draws no note despite its merge-base with the default branch now being `HEAD`.
    @Test
    func aBranchCaughtUpByFastForwardMergeDrawsNoNote() throws {
        let repository = try Self.repository(committing: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\n@Test func sizeIsCarried() {}\n",
        ])
        try TestSources.runGit(["switch", "-c", "feature"], in: repository)
        try TestSources.runGit(["switch", "main"], in: repository)
        try "import Testing\n@Test func sizeIsCarried() {}\n@Test func shoutingWorks() {}\n"
            .write(to: repository.appendingPathComponent("Tests/WidgetTests/WidgetTests.swift"), atomically: true, encoding: .utf8)
        try TestSources.runGit(["add", "-A"], in: repository)
        try TestSources.runGit(["commit", "-m", "main moves"], in: repository)
        try TestSources.runGit(["switch", "feature"], in: repository)
        try TestSources.runGit(["merge", "--ff-only", "main"], in: repository)

        #expect(ChangedTests.noBranchRangeNote(since: nil, in: repository) == nil)
    }

    /// A branch that took its own commits and was then `reset --hard` onto the default branch has thrown those commits away as far as its current tip is concerned — the reflog's newest entry is the reset, not the earlier commit — so it draws no note.
    @Test
    func aBranchResetHardOntoTheDefaultBranchDrawsNoNote() throws {
        let repository = try Self.repository(committing: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\n@Test func sizeIsCarried() {}\n",
        ])
        try TestSources.runGit(["switch", "-c", "feature"], in: repository)
        try "import Testing\n@Test func sizeIsCarried() {}\n@Test func shoutingWorks() {}\n"
            .write(to: repository.appendingPathComponent("Tests/WidgetTests/WidgetTests.swift"), atomically: true, encoding: .utf8)
        try TestSources.runGit(["add", "-A"], in: repository)
        try TestSources.runGit(["commit", "-m", "feature work"], in: repository)
        try TestSources.runGit(["reset", "--hard", "main"], in: repository)

        #expect(ChangedTests.noBranchRangeNote(since: nil, in: repository) == nil)
    }

    /// `git branch -f` landing a branch directly onto the default branch's tip — from another branch, since git refuses to force-move the one currently checked out — never records a commit on it either, so it draws no note once the branch is switched back to.
    @Test
    func aBranchForcedOntoTheDefaultBranchDrawsNoNote() throws {
        let repository = try Self.repository(committing: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\n@Test func sizeIsCarried() {}\n",
        ])
        try TestSources.runGit(["switch", "-c", "feature"], in: repository)
        try TestSources.runGit(["switch", "main"], in: repository)
        try "import Testing\n@Test func sizeIsCarried() {}\n@Test func shoutingWorks() {}\n"
            .write(to: repository.appendingPathComponent("Tests/WidgetTests/WidgetTests.swift"), atomically: true, encoding: .utf8)
        try TestSources.runGit(["add", "-A"], in: repository)
        try TestSources.runGit(["commit", "-m", "main moves"], in: repository)
        try TestSources.runGit(["branch", "-f", "feature", "main"], in: repository)
        try TestSources.runGit(["switch", "feature"], in: repository)

        #expect(ChangedTests.noBranchRangeNote(since: nil, in: repository) == nil)
    }

    /// A detached `HEAD` sitting at the default branch's tip reads the same empty merge-base with no branch of its own to name a base for at all.
    @Test
    func aDetachedHeadAtTheDefaultBranchsTipDrawsNoNote() throws {
        let repository = try Self.repository(committing: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\n@Test func sizeIsCarried() {}\n",
        ])
        try TestSources.runGit(["checkout", "--detach", "main"], in: repository)

        #expect(ChangedTests.noBranchRangeNote(since: nil, in: repository) == nil)
    }

    /// On the default branch itself the merge-base with it is `HEAD` by construction, which the design already allows: the fold line draws no note over it.
    @Test
    func onTheDefaultBranchItselfTheFoldLineDrawsNoNote() throws {
        let repository = try Self.repository(committing: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\n@Test func sizeIsCarried() {}\n",
        ])
        let results = ["sizeIsCarried()": true]
        let judged = Self.judged(
            without: Self.run(results),
            with: Self.run(results),
            workingDirectory: repository,
            repositoryRoot: repository,
            changedTests: []
        )

        #expect(!judged.render().text.contains("no branch range was found"))
    }

    /// A changed file whose after side will not read leaves the whole answer unread, which folds nothing, rather than reading as a deletion that would fold its written tests away as untouched.
    @Test
    func aChangedFileThatWillNotReadLeavesTheAnswerUnread() throws {
        let repository = try Self.repository(committing: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\n@Test func sizeIsCarried() {}\n",
        ])
        // A link to nothing: git lists it as untracked, and there is nothing behind it to read.
        try FileManager.default.createSymbolicLink(
            atPath: repository.appendingPathComponent("Tests/WidgetTests/GizmoTests.swift").path,
            withDestinationPath: "Nowhere.swift"
        )

        #expect(ChangedTests.identifiers(since: nil, in: repository) == nil)
    }

    /// A path both committed and dirty takes its new side from disk, not `HEAD`: an edit finished after the last commit is the change, and reading `HEAD` instead would answer with the file as it stood before it.
    @Test
    func aPathCommittedAndDirtyTakesItsNewSideFromDisk() throws {
        let repository = try Self.repository(committing: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\n@Test func sizeIsCarried() {}\n",
        ])
        let base = try TestSources.runGit(["rev-parse", "HEAD"], in: repository).trimmingCharacters(in: .whitespacesAndNewlines)
        try "import Testing\n@Test func sizeIsCarried() {}\n@Test func shoutingWorks() {}\n"
            .write(to: repository.appendingPathComponent("Tests/WidgetTests/WidgetTests.swift"), atomically: true, encoding: .utf8)
        try TestSources.runGit(["add", "-A"], in: repository)
        try TestSources.runGit(["commit", "-m", "a test"], in: repository)
        try "import Testing\n@Test func sizeIsCarried() {}\n@Test func shoutingWorks() {}\n@Test func theGridReflows() {}\n"
            .write(to: repository.appendingPathComponent("Tests/WidgetTests/WidgetTests.swift"), atomically: true, encoding: .utf8)

        #expect(ChangedTests.identifiers(since: base, in: repository) == ["shoutingWorks", "theGridReflows"])
    }

    /// A committed rename's origin is kept for the old side: the moved file's untouched test is not written, but a test the commit added to it is — the rename alone never explains a line missing from the fold.
    @Test
    func aCommittedRenamesOriginIsKeptForTheOldSide() throws {
        let repository = try Self.repository(committing: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\n@Test func sizeIsCarried() {}\n",
        ])
        let base = try TestSources.runGit(["rev-parse", "HEAD"], in: repository).trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.moveItem(
            at: repository.appendingPathComponent("Tests/WidgetTests/WidgetTests.swift"),
            to: repository.appendingPathComponent("Tests/WidgetTests/GizmoTests.swift")
        )
        try TestSources.runGit(["add", "-A"], in: repository)
        try TestSources.runGit(["commit", "-m", "rename"], in: repository)
        try "import Testing\n@Test func sizeIsCarried() {}\n@Test func shoutingWorks() {}\n"
            .write(to: repository.appendingPathComponent("Tests/WidgetTests/GizmoTests.swift"), atomically: true, encoding: .utf8)

        #expect(ChangedTests.identifiers(since: base, in: repository) == ["shoutingWorks"])
    }

    /// A committed rename A→B followed by an uncommitted rename B→C still reads the old side at A: looking the dirty rename's origin up under its own new path (B) would miss it, and count a pure rename chain as a whole new file whose every test is written.
    @Test
    func aRenameChainStillReadsItsOldSideAtTheFirstOrigin() throws {
        let repository = try Self.repository(committing: [
            "Tests/WidgetTests/WidgetTests.swift": "import Testing\n@Test func sizeIsCarried() {}\n",
        ])
        let base = try TestSources.runGit(["rev-parse", "HEAD"], in: repository).trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.moveItem(
            at: repository.appendingPathComponent("Tests/WidgetTests/WidgetTests.swift"),
            to: repository.appendingPathComponent("Tests/WidgetTests/GizmoTests.swift")
        )
        try TestSources.runGit(["add", "-A"], in: repository)
        try TestSources.runGit(["commit", "-m", "rename"], in: repository)
        try FileManager.default.moveItem(
            at: repository.appendingPathComponent("Tests/WidgetTests/GizmoTests.swift"),
            to: repository.appendingPathComponent("Tests/WidgetTests/GadgetTests.swift")
        )
        // Staged, so git's own rename detection reports it as one: an unstaged move alone reads as a
        // deletion and an untracked addition, not the rename this is proving.
        try TestSources.runGit(["add", "-A"], in: repository)

        #expect(ChangedTests.identifiers(since: base, in: repository) == [])
    }

    /// A repository holding `files`, committed, with nothing left uncommitted.
    private static func repository(committing files: [String: String]) throws -> URL {
        let repository = try TestSources.makeTempDirectory()
        try TestSources.runGit(["init", "-b", "main", "."], in: repository)
        try TestSources.runGit(["config", "user.email", "test@example.com"], in: repository)
        try TestSources.runGit(["config", "user.name", "Tester"], in: repository)
        for (path, text) in files {
            let url = repository.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try TestSources.runGit(["add", "-A"], in: repository)
        try TestSources.runGit(["commit", "-m", "seed"], in: repository)
        return repository
    }
}

// MARK: - Which tests a change writes

/// Covers ``ChangedTests`` over two sides of a file as bytes — the declaration-level read the fold above rests on.
extension RunWithoutAnswerTests {
    private static var suite: String {
        """
        import Testing
        @testable import Widgets

        @Suite struct WidgetTests {
            @Test func shoutingWorks() {
                #expect(Widget().shout() == "HI")
            }

            @Test func sizeIsCarried() {
                #expect(Widget().size == 1)
            }
        }
        """
    }

    /// A test added and a test whose body the change edited are both tests it wrote; the one it left alone is not.
    @Test
    func theTestsAFileGainsAndTheOnesItEditsAreRead() {
        let after = Self.suite
            .replacingOccurrences(of: #"#expect(Widget().shout() == "HI")"#, with: #"#expect(Widget().shout() == "HI!")"#)
            .replacingOccurrences(of: "\n}", with: "\n\n    @Test func theGridReflows() {\n        #expect(Widget().columns == 2)\n    }\n}")

        let written = ChangedTests.identifiers(inTestSource: "Tests/WidgetTests/WidgetTests.swift", bytes: (old: Data(Self.suite.utf8), new: Data(after.utf8)))

        #expect(written == ["shoutingWorks", "theGridReflows"])
    }

    /// A whole new suite writes every test in it, which the declaration diff reports as one added container rather than a line per test.
    @Test
    func aWholeNewSuiteWritesEveryTestUnderIt() {
        let written = ChangedTests.identifiers(inTestSource: "Tests/WidgetTests/WidgetTests.swift", bytes: (old: nil, new: Data(Self.suite.utf8)))

        #expect(written == ["shoutingWorks", "sizeIsCarried"])
    }

    /// A test merely moved among its siblings is untouched: its text is what it was, and counting a reorder as written would list every test of a file somebody tidied.
    @Test
    func aTestMovedAmongItsSiblingsIsNotOneTheChangeWrote() {
        let lines = Self.suite.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // The two tests, three lines each, swapped — the blank between them where it was.
        let body = Array(lines[8 ... 10]) + [""] + Array(lines[4 ... 6])
        let after = (Array(lines[0 ... 3]) + body + Array(lines[11...])).joined(separator: "\n")

        let written = ChangedTests.identifiers(inTestSource: "Tests/WidgetTests/WidgetTests.swift", bytes: (old: Data(Self.suite.utf8), new: Data(after.utf8)))

        #expect(written.isEmpty, "\(written)")
    }

    /// A file is read for what it wrote however it imports: an import spelled past any pattern would otherwise pass its tests over, and fold a written one away as untouched.
    @Test(arguments: [
        "@preconcurrency import XCTest\n",
        "import struct Testing.Test\n",
        "public import Testing\n",
        // No test import at all: a function that is no test only keeps a line listed, never folds one away.
        "import Foundation\n",
    ])
    func aFileIsReadForWhatItWroteHoweverItImports(imports: String) {
        let before = imports + "\nfunc sizeIsCarried() {}\n"
        let after = before + "\nfunc shoutingWorks() {}\n"

        let written = ChangedTests.identifiers(inTestSource: "Tests/WidgetTests/WidgetTests.swift", bytes: (old: Data(before.utf8), new: Data(after.utf8)))

        #expect(written == ["shoutingWorks"], "\(imports)")
    }

    /// A written test from a file whose import no pattern recognises, passing both ways beside one that pins, stops the proof: it is not folded away as untouched.
    @Test
    func aWrittenTestBehindAnUnusualImportThatPinsNothingIsNotProven() {
        let file = "@preconcurrency import Testing\n\n@Test func shoutingWorks() {}\n\n@Test func theGridReflows() {}\n"
        let written = ChangedTests.identifiers(inTestSource: "Tests/WidgetTests/GizmoTests.swift", bytes: (old: nil, new: Data(file.utf8)))
        let judged = Self.judged(
            without: Self.run(["shoutingWorks()": false, "theGridReflows()": true]),
            with: Self.run(["shoutingWorks()": true, "theGridReflows()": true]),
            changedTests: written
        )

        #expect(judged.render().text.hasPrefix("✘ 1 of 2 fails without Sources/ and passes with it\n"), "\(judged.render().text)")
        #expect(!judged.proven)
    }
}

extension RunWithoutAnswerTests {
    /// The notice that a new file's removal can show only a build failure is given only when the run without it did not build: a run that built and ran tests has shown otherwise.
    @Test
    func theNewFileNoticeIsGivenOnlyWhenTheRunWithoutTheChangeDidNotBuild() {
        let record = Self.judged(
            without: Self.run(["shoutingWorks()": false]),
            with: Self.run(["shoutingWorks()": true]),
            newFiles: ["Sources/Widgets/Gadget.swift"]
        ).restored.record

        let unbuilt = RunWithoutAnswer.newFilesNotice(record, withoutBuilt: false)

        #expect(unbuilt?.contains("Sources/Widgets/Gadget.swift is not in HEAD") == true, "\(String(describing: unbuilt))")
        #expect(unbuilt?.contains("can show only that") == true)
        #expect(RunWithoutAnswer.newFilesNotice(record, withoutBuilt: true) == nil, "a run that built and ran tests has shown a failing assertion is possible")
    }
}
