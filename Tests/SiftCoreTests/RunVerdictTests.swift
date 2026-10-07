//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the one thing `sift run` must never get wrong: whether the run it wrapped succeeded.
///
/// The corpus is the four verdict-reader captures — see `Fixtures/RunOutput/PROVENANCE.md`. Two of them are the same tree, and the same built products, minutes apart, one green and one red, which is the only cheap protection against a rule that explains a failure by inventing a cause for it; the other two are the states a two-value reader has nowhere to put, an interrupted run and a log that stops mid-suite.
///
/// Each fixture is read against the invocation that produced it, because that is what the tool does: the verdict a command owes comes from argv and never from the output it is being used to judge.
struct RunVerdictTests {
    @Test
    func aPassingRunIsReadAsThePassItIs() throws {
        let report = try TestSources.runReport("xcodebuild-test-execute-success", invokedAs: Self.testWithoutBuilding)
        let verdict = try #require(report.verdict)

        #expect(verdict.state == .succeeded)
        #expect(verdict.line == "** TEST EXECUTE SUCCEEDED **")
        #expect(verdict.answersTheInvokedCommand)
        #expect(Self.answer(report, exitCode: 0).hasPrefix("✔ xcodebuild\n"))
    }

    @Test
    func aFailingRunIsReadAsTheFailureItIs() throws {
        let report = try TestSources.runReport("xcodebuild-test-execute-failure-environmental", invokedAs: Self.testWithoutBuilding)
        let verdict = try #require(report.verdict)

        #expect(verdict.state == .failed)
        #expect(verdict.line == "** TEST EXECUTE FAILED **")
        #expect(verdict.answersTheInvokedCommand)
        #expect(Self.answer(report, exitCode: 65).hasPrefix("✘ xcodebuild — exit 65\n"))
    }

    /// A known issue is a recorded expectation that something is broken, so it is not a failure and its presence alone must not turn a run red.
    ///
    /// Both halves are load-bearing and both are in the corpus. The green capture closes with `with 1 known issue.` — a passing run that carries one, which is exactly the shape a reader that treats "issue" as "failure" reports as a failure — and the red one with `with 667 issues (including 1 known issue).`, where the number a reader wants is the one neither sentence prints.
    @Test
    func aKnownIssueIsCountedOutOfTheFailuresAndNeverTurnsARunRed() throws {
        let green = try TestSources.runReport("xcodebuild-test-execute-success", invokedAs: Self.testWithoutBuilding)
        let red = try TestSources.runReport("xcodebuild-test-execute-failure-environmental", invokedAs: Self.testWithoutBuilding)

        let passing = try #require(green.tally)
        #expect(passing.passed)
        #expect(passing.tests == 2658)
        #expect(passing.suites == 290)
        #expect(passing.issues == 1)
        #expect(passing.knownIssues == 1)
        #expect(passing.failures == 0)
        #expect(green.verdict?.state == .succeeded)

        let failing = try #require(red.tally)
        #expect(!failing.passed)
        #expect(failing.tests == 2658)
        #expect(failing.suites == 290)
        #expect(failing.issues == 667)
        #expect(failing.knownIssues == 1)
        #expect(failing.failures == 666)

        // The arithmetic neither sentence prints is the one the answer states — named after the framework
        // it counts, because the classification line below it counts both frameworks' failures and the two
        // denominators are indistinguishable when they happen to agree, as they do on this pair.
        #expect(Self.answer(green, exitCode: 0).contains("\n  Swift Testing: 0 failures, 1 known issue\n"))
        #expect(Self.answer(red, exitCode: 65).contains("\n  Swift Testing: 666 failures, 1 known issue\n"))
    }

    /// An interrupted run is a third state, and the capture is the case that punishes a reader with only two.
    ///
    /// Its verdict says `** BUILD INTERRUPTED **` while its own suite line says `failed`, so a reader that takes the suite line calls it a failure and a reader that requires `FAILED **` calls it a pass. The glyph therefore follows the verdict and not the exit code — asserted at both a zero and a nonzero exit, because the capture does not record which one it ended on and the answer must not depend on it.
    @Test
    func anInterruptedRunIsNeitherAPassNorAFailure() throws {
        let report = try TestSources.runReport("xcodebuild-build-interrupted", invokedAs: Self.testWithoutBuilding)

        let verdict = try #require(report.verdict)
        #expect(verdict.state == .interrupted)
        #expect(verdict.line == "** BUILD INTERRUPTED **")
        #expect(report.tally?.passed == false)
        for exitCode in [Int32(0), 130] {
            let answer = Self.answer(report, exitCode: exitCode)
            #expect(answer.hasPrefix("◼ xcodebuild — interrupted, exit \(exitCode)"))
            #expect(!answer.hasPrefix("✔"))
            #expect(!answer.hasPrefix("✘"))
        }
    }

    /// A log that stops mid-suite carries no verdict, and saying nothing about that is the failure this whole unit exists to prevent.
    ///
    /// The capture is the first 4,000 lines of the passing run — the shape a killed `xcodebuild` leaves behind — and it arrives with exit 0, so nothing downstream will make the answer loud on its behalf. The exit code is stated, as the launcher always states it: without `-quiet`, exit 0 over silence is still no verdict, because `xcodebuild` prints its banner whenever it finishes.
    @Test
    func aLogThatEndsMidRunIsNeverAnsweredAsSuccess() throws {
        let report = try TestSources.runReport("xcodebuild-test-execute-truncated", invokedAs: Self.testWithoutBuilding, exitCode: 0)

        #expect(report.verdict == nil)
        let answer = Self.answer(report, exitCode: 0)
        #expect(answer.hasPrefix("⚠ xcodebuild — exit 0, and no verdict in the log; see the raw output"))
        #expect(!answer.contains("✔"))
        #expect(answer.contains("raw: .sift/runs/run-20260906-194437-1c4de9a2.log ("))
    }

    /// `xcodebuild` prints one `Executed 0 tests` line per run whether or not an `XCTestCase` exists, and it is not a summary.
    ///
    /// All four captures carry it, and on the truncated one it is the *only* thing left in the answer — so read as a summary, a run that never finished renders as `✔ xcodebuild` above one cheerful count of nothing, which is the defect this pins.
    @Test
    func theVestigialExecutedCounterIsNotASummary() throws {
        let raw = try TestSources.runOutput("xcodebuild-test-execute-truncated")
        let report = try TestSources.runReport("xcodebuild-test-execute-truncated", invokedAs: Self.testWithoutBuilding)

        #expect(raw.contains("Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds"))
        #expect(report.summaryLines.isEmpty)
        #expect(!Self.answer(report, exitCode: 0).contains("Executed 0 tests"))
    }

    /// A counter with real numbers in it stays, and the last of them is still the run's own total.
    ///
    /// The three in this capture differ only in their trailing duration, so a rule that dropped the wrong one would look right until the numbers were read.
    @Test
    func aCountedExecutedLineIsKeptAndTheLastOneWins() throws {
        let raw = try TestSources.runOutput("xcodebuild-test-failure")
        let report = try TestSources.runReport("xcodebuild-test-failure")

        #expect(raw.contains("Executed 1 test, with 1 failure (0 unexpected) in 0.312 (0.312) seconds"))
        #expect(report.summaryLines.contains("Executed 1 test, with 1 failure (0 unexpected) in 0.312 (0.314) seconds"))
        #expect(!report.summaryLines.contains("Executed 1 test, with 1 failure (0 unexpected) in 0.312 (0.312) seconds"))
    }

    /// The verdict is read against the action that was invoked, not against whichever literal the log happens to carry.
    ///
    /// Synthetic lines rather than a capture: producing this needs a build system that prints one action's verdict for another, which is the anomaly itself. What is under test is the reading — `build-for-testing` closes on `** TEST BUILD SUCCEEDED **`, so a `** BUILD SUCCEEDED **` standing in its place is an earlier phase's verdict where the owed one never came, and accepting it as a pass is how a build-for-testing that died after the build reads as green.
    @Test
    func aVerdictFromAnotherActionIsReportedRatherThanAccepted() throws {
        var filter = try RunOutputFilter(expecting: #require(RunVerdict.Contract.of(["xcodebuild", "build-for-testing", "-scheme", "Gizmo"])))
        filter.consume(line: "** BUILD SUCCEEDED **")
        let report = filter.finish()
        let verdict = try #require(report.verdict)

        #expect(verdict.state == .succeeded)
        #expect(verdict.owed == "** TEST BUILD SUCCEEDED **")
        #expect(!verdict.answersTheInvokedCommand)
        let answer = Self.answer(report, exitCode: 0)
        #expect(answer.hasPrefix("⚠ xcodebuild — exit 0, and the log's verdict is not this command's"))
        #expect(answer.contains("ends on ** TEST BUILD SUCCEEDED **, which the log never reached"))
    }

    /// What a command owes is read from argv, and every action word in the table earns a different wording.
    ///
    /// Each of these was read off `xcodebuild` itself rather than derived from the action word — `docbuild` is the row that proves the table has to be a table, since it closes on `** BUILD DOCUMENTATION SUCCEEDED **` and every reasonable guess would have been `DOCBUILD`.
    @Test
    func eachActionOwesItsOwnVerdict() {
        #expect(RunVerdict.Contract.of(["xcodebuild", "build"]) == .declares(succeeded: "** BUILD SUCCEEDED **", failed: "** BUILD FAILED **"))
        #expect(RunVerdict.Contract.of(["xcodebuild", "build-for-testing"]) == .declares(succeeded: "** TEST BUILD SUCCEEDED **", failed: "** TEST BUILD FAILED **"))
        #expect(RunVerdict.Contract.of(["xcodebuild", "test"]) == .declares(succeeded: "** TEST SUCCEEDED **", failed: "** TEST FAILED **"))
        #expect(RunVerdict.Contract.of(["xcodebuild", "test-without-building"]) == .declares(succeeded: "** TEST EXECUTE SUCCEEDED **", failed: "** TEST EXECUTE FAILED **"))
        #expect(RunVerdict.Contract.of(["xcodebuild", "clean"]) == .declares(succeeded: "** CLEAN SUCCEEDED **", failed: "** CLEAN FAILED **"))
        #expect(RunVerdict.Contract.of(["xcodebuild", "analyze"]) == .declares(succeeded: "** ANALYZE SUCCEEDED **", failed: "** ANALYZE FAILED **"))
        #expect(RunVerdict.Contract.of(["xcodebuild", "archive"]) == .declares(succeeded: "** ARCHIVE SUCCEEDED **", failed: "** ARCHIVE FAILED **"))
        #expect(RunVerdict.Contract.of(["xcodebuild", "install"]) == .declares(succeeded: "** INSTALL SUCCEEDED **", failed: "** INSTALL FAILED **"))
        #expect(RunVerdict.Contract.of(["xcodebuild", "docbuild"]) == .declares(succeeded: "** BUILD DOCUMENTATION SUCCEEDED **", failed: "** BUILD DOCUMENTATION FAILED **"))
        #expect(RunVerdict.Contract.of(["swift", "build"]) == .declares(succeeded: "Build complete!", failed: nil))
        #expect(RunVerdict.Contract.of(["swift", "test"]) == .runTally)
        // An action with no wording is unreadable, not absent — the two are different answers and only
        // the first refuses the log's own literals. `installsrc` was measured to print nothing at all,
        // and an export is a mode that replaces the build and closes on a line nobody here has measured.
        #expect(RunVerdict.Contract.of(["xcodebuild", "installsrc"]) == .unreadable)
        #expect(RunVerdict.Contract.of(["xcodebuild", "-exportArchive", "-archivePath", "A.xcarchive"]) == .unreadable)
        // A command this tool never wraps has no contract at all, which costs nothing: it is never filtered.
        #expect(RunVerdict.Contract.of(["make", "build"]) == nil)
        #expect(RunVerdict.Contract.of([]) == nil)
    }

    /// The last action wins, a bare word that is an option's value is not an action at all, and an invocation naming no action is the `build` the manual page says it is.
    ///
    /// `xcodebuild clean build` performs its actions in order and prints one verdict each, so the run's verdict is the build's — the captured `clean build` runs are exactly this shape. `-scheme test` names a scheme, and reading it as the `test` action would have the command owe a verdict no part of the invocation ever promised; nothing in argv separates that from a flag this reader has never heard of standing in front of a real `test`, so it refuses rather than picking one. And *"build … is the default action, and is used if no action is given"* is the manual page's own sentence, which is what a build script writing `xcodebuild -project X -scheme Y` is relying on.
    @Test
    func theLastActionWinsAndAnOptionsValueIsNotOne() {
        let cleanBuild = ["xcodebuild", "-project", "Gizmo.xcodeproj", "-scheme", "Gizmo", "-destination", "platform=macOS", "clean", "build"]
        let building = RunVerdict.Contract.declares(succeeded: "** BUILD SUCCEEDED **", failed: "** BUILD FAILED **")

        #expect(RunVerdict.Contract.of(cleanBuild) == building)
        #expect(RunVerdict.Contract.of(["xcodebuild", "-scheme", "test", "-project", "Gizmo.xcodeproj"]) == .unreadable)
        #expect(RunVerdict.Contract.of(["/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild", "test"]) == .declares(succeeded: "** TEST SUCCEEDED **", failed: "** TEST FAILED **"))
        #expect(RunVerdict.Contract.of(["xcodebuild", "-project", "Gizmo.xcodeproj", "-scheme", "Gizmo"]) == building)
        #expect(RunVerdict.Contract.of(["xcodebuild"]) == building)
    }

    /// A valueless flag takes nothing behind it, so the action standing there is the invocation's own.
    ///
    /// A reading that asks only whether the word in front begins with `-` makes every one of these swallow its action and answer `⚠` on every run the command ever makes, green ones included. Each flag here is from `xcodebuild -help`'s option list; the colon form carries its value in its own name and is the same case by a different route.
    @Test
    func aValuelessFlagDoesNotSwallowTheActionBehindIt() {
        let testing = RunVerdict.Contract.declares(succeeded: "** TEST SUCCEEDED **", failed: "** TEST FAILED **")
        let building = RunVerdict.Contract.declares(succeeded: "** BUILD SUCCEEDED **", failed: "** BUILD FAILED **")

        #expect(RunVerdict.Contract.of(["xcodebuild", "-scheme", "S", "-quiet", "test"]) == testing)
        #expect(RunVerdict.Contract.of(["xcodebuild", "-scheme", "S", "-only-testing:AlphaTests/aTest", "test"]) == testing)
        #expect(RunVerdict.Contract.of(["xcodebuild", "-skipMacroValidation", "build"]) == building)
        #expect(RunVerdict.Contract.of(["xcodebuild", "-allowProvisioningUpdates", "build"]) == building)
        #expect(RunVerdict.Contract.of(["xcodebuild", "-showBuildTimingSummary", "build"]) == building)
        // And a flag that does take a value still hides whatever stands behind it, which is the half
        // that has to keep working: `-destination` here, `-scheme` above.
        #expect(RunVerdict.Contract.of(["xcodebuild", "-scheme", "S", "-destination", "platform=macOS", "test"]) == testing)
    }

    /// The whole reason `-quiet test-without-building` has to be readable: green or red, the answer it gives is about the log rather than about this tool's own limits.
    ///
    /// Both halves are measured against `xcodebuild` itself. `-quiet` means *do not print any output except for warnings and errors*, so a passing run under it genuinely closes with no verdict line, while a failing run under `-quiet` **does** print `** TEST EXECUTE FAILED **` — and answering that with a `⚠` would mean the action behind the flag went unread.
    ///
    /// **The silent half is read as a pass from its exit code, and that reading is blind to one case, which this capture is.** It is a run cut short, not a clean one — but under `-quiet` the two print the same silence, so with exit 0 it reads as passed exactly as a clean `-quiet` run would. Nothing in the log tells them apart; what the answer can do is say that the pass rests on the exit code of a `-quiet` run, and name the case it cannot see.
    @Test
    func aQuietRunIsJudgedOnWhatItActuallyPrinted() throws {
        let quiet = ["xcodebuild", "-scheme", "Depot-Package", "-quiet", "test-without-building"]
        let failing = try TestSources.runReport("xcodebuild-test-execute-failure-environmental", invokedAs: quiet, exitCode: 65)
        let silent = try TestSources.runReport("xcodebuild-test-execute-truncated", invokedAs: quiet, exitCode: 0)

        #expect(failing.verdict?.line == "** TEST EXECUTE FAILED **")
        #expect(Self.answer(failing, exitCode: 65).hasPrefix("✘ xcodebuild — exit 65\n"))
        let verdict = try #require(silent.verdict)
        #expect(verdict.inferredFromExitCode)
        let answer = Self.answer(silent, exitCode: 0)
        #expect(answer.hasPrefix("✔ xcodebuild — no verdict printed under -quiet; read as passed from exit 0"))
        #expect(answer.contains("a -quiet run cut short that still exited 0 would read the same"))
    }

    /// An `xcodebuild` whose action this reader cannot name answers with no verdict at all, never with whichever literal the log happened to carry — and says which of the two silences that is.
    ///
    /// The refusal is the part to keep. An unread action read as *no contract* leaves the reader free to take any `** … **` in the log as the run's own, so one capture would answer `✔ xcodebuild` under one spelling of the invocation and `⚠ … the log's verdict is not this command's` under another, on nothing but the position of a flag.
    ///
    /// **The wording is the part that can be wrong, and the log two lines below is what would contradict it.** `no verdict in the log` is a claim about the log, and here the log carries `** TEST EXECUTE SUCCEEDED **` — quoted directly beneath the headline denying it. What is true is narrower and is about this tool: it could not tell which line the action owed, so it took none. Both invocations here are genuinely unreadable and neither is common — a scheme named after an action word, and an export mode that closes on a line nobody has measured — because the common shapes (`-quiet test`, `archive`, a bare `xcodebuild`) all resolve properly.
    @Test
    func anXcodebuildWhoseActionCannotBeReadHasNoVerdictAtAll() throws {
        let ambiguous = ["xcodebuild", "-project", "P.xcodeproj", "-scheme", "test"]
        let exporting = ["xcodebuild", "-exportArchive", "-archivePath", "P.xcarchive", "-exportPath", "out"]

        for invocation in [ambiguous, exporting] {
            #expect(RunVerdict.Contract.of(invocation) == .unreadable)
            let report = try TestSources.runReport("xcodebuild-test-execute-success", invokedAs: invocation)

            // The log carries `** TEST EXECUTE SUCCEEDED **`, and it is not this answer's to take.
            #expect(try TestSources.runOutput("xcodebuild-test-execute-success").contains("** TEST EXECUTE SUCCEEDED **"))
            #expect(report.verdict == nil)
            let answer = Self.answer(report, exitCode: 0)
            #expect(answer.hasPrefix("⚠ xcodebuild — exit 0, and this tool could not tell which verdict the command owed, so it read none; see the raw output"))
            #expect(!answer.contains("✔"))
            // The headline says nothing about the log being empty, because the log is not: the line it
            // refused to read is printed directly beneath, which is where a claim about the log comes apart.
            #expect(!answer.contains("no verdict in the log"))
            #expect(answer.contains("\n  ** TEST EXECUTE SUCCEEDED **\n"))
        }
    }

    /// Having no contract at all is read as ``RunVerdict/Contract/unreadable``, because a contract owing nothing accepts everything.
    ///
    /// `Contract.of` answers `nil` for a command this tool never wraps, and carried into the filter that `nil` would take the `declares` path with nothing owed, which makes ``RunVerdict/answersTheInvokedCommand`` vacuously true and hands the run whichever `** … SUCCEEDED **` the log turns up. An unrecognised command is never filtered, so left there the invariant would hold in `RunLauncher` rather than in the type. Mapping it at the boundary makes the safe reading the type's own property, and this pins that reading.
    @Test
    func aCommandWithNoContractAtAllRefusesTheLogsOwnVerdict() throws {
        #expect(RunVerdict.Contract.of(["make", "all"]) == nil)

        let report = try TestSources.runReport("xcodebuild-test-execute-success")

        #expect(report.contract == .unreadable)
        #expect(report.verdict == nil)
        // A verdict belonging to some other action is the shape a contract owing nothing would adopt outright.
        var stray = RunOutputFilter(expecting: .unreadable)
        stray.consume(line: "** CLEAN SUCCEEDED **")

        #expect(stray.finish().verdict == nil)
    }

    /// A log that declares success over a child that exited nonzero is an anomaly of the same family, and it is the one that catches what nobody enumerated.
    ///
    /// The green capture is a real `** TEST EXECUTE SUCCEEDED **` run; handing it a nonzero exit is the shape a `xcodebuild test` takes when a diagnostic came before its closing line. Neither of the other two anomalies fires — the verdict is present and it is the one the command owed — so without this check the answer would be `✔ xcodebuild — exit 65`, a tick over a failure.
    @Test
    func aLogDeclaringSuccessOverANonzeroExitIsAnAnomalyNotAPass() throws {
        let report = try TestSources.runReport("xcodebuild-test-execute-success", invokedAs: Self.testWithoutBuilding)

        #expect(report.verdict?.state == .succeeded)
        #expect(report.verdict?.answersTheInvokedCommand == true)
        let answer = Self.answer(report, exitCode: 65)
        #expect(answer.hasPrefix("⚠ xcodebuild — the log declares success but the command exited 65; see the raw output"))
        #expect(!answer.contains("✔"))
        // And the same report at the exit code it really ended on is still the pass it was.
        #expect(Self.answer(report, exitCode: 0).hasPrefix("✔ xcodebuild\n"))
    }

    /// `swift test` prints no verdict line at all, so its Swift Testing run tally is the only thing that says the run reached its end.
    @Test
    func aSwiftTestRunIsJudgedByItsRunTally() throws {
        let passed = try TestSources.runReport("swift-test-pass", invokedAs: ["swift", "test"])
        let failed = try TestSources.runReport("swift-test-fail", invokedAs: ["swift", "test"])

        #expect(passed.verdict?.state == .succeeded)
        #expect(passed.verdict?.line == "Test run with 2 tests in 1 suite passed after 0.001 seconds.")
        #expect(failed.verdict?.state == .failed)
        #expect(failed.tally?.failures == 2)
    }

    /// A Swift Testing run tally speaks for Swift Testing's half of a `swift test` and for nothing else, so it cannot carry the verdict on its own.
    ///
    /// Two real captures of the same scratch package, one with a Swift Testing suite in it and one without, both with a failing `XCTestCase`. Swift Testing prints its closing sentence either way and it says *passed* either way — `with 0 tests in 0 suites` when the package holds no `@Test` at all, which is every pure-XCTest package, and `with 1 test in 1 suite` when its own half genuinely passed. Judged on that sentence alone both runs would answer `✔ swift test — exit 1`, a tick standing directly above the assertion the same answer has just listed.
    @Test
    func aRunTallyCannotPassARunItsOwnFrameworkDidNotRun() throws {
        for capture in ["swift-test-xctest-only-failure", "swift-test-mixed-xctest-failure"] {
            let raw = try TestSources.runOutput(capture)
            let report = try TestSources.runReport(capture, invokedAs: ["swift", "test"])

            // Swift Testing said the run passed, in its own words, in both captures.
            #expect(raw.contains("passed after"), "\(capture)")
            #expect(try #require(report.tally, "\(capture)").passed, "\(capture)")
            // And XCTest said otherwise, which is what the verdict has to be read against.
            #expect(report.testFailures.contains { $0.name == "-[MixedTests.LegacyTests testOldMath]" }, "\(capture)")
            #expect(report.verdict?.state == .failed, "\(capture)")

            let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Mixed"))
                .render(report, exitCode: 1, logURL: nil)
            #expect(answer.hasPrefix("✘ swift test — exit 1\n"), "\(capture)")
            #expect(!answer.contains("✔"), "\(capture)")
            #expect(answer.contains(#"XCTAssertEqual failed: ("6") is not equal to ("42")"#), "\(capture)")

            // And the build's own verdict is not put back on the screen underneath the run's. `swift test`
            // builds before it runs, so `Build complete!` is in the output and the filter keeps it as the
            // summary line it is — but standing it directly beneath `✘ swift test — exit 1` restates the
            // reading `verdict(from:)` refuses to make, one line below a headline saying the opposite.
            #expect(try TestSources.runOutput(capture).contains("Build complete!"), "\(capture)")
            #expect(report.summaryLines.contains { $0.hasPrefix("Build complete!") }, "\(capture)")
            #expect(!answer.contains("Build complete!"), "\(capture)")
        }
    }

    /// A run with two test bundles closes with two run tallies, and neither of them speaks for the run.
    ///
    /// Swift Testing prints one tally per test *process* and `xcodebuild` runs one process per bundle, so a two-target scheme prints two. Both are kept verbatim rather than the counts being added up — a sum is a number no tool printed, which Docs/Design.md §3 rule 6 forbids — and `passed` is a judgement rather than a count, so a total would also have to decide what "the run passed" means across processes.
    ///
    /// **The second bundle's known issue still gets its own arithmetic line, labelled by its own tally so it cannot be misread as the run's.** The first bundle's two issues are not known ones, so it gets no line of its own — nothing here is ever a package total, and nothing is dropped that a single-bundle run would have printed for the bundle that carries it.
    @Test
    func twoTestBundlesLeaveTwoTalliesAndNoArithmeticOverBoth() throws {
        let raw = try TestSources.runOutput("xcodebuild-test-two-bundles")
        let report = try TestSources.runReport("xcodebuild-test-two-bundles", invokedAs: Self.twoBundles)

        // The capture's own two closing sentences, seventeen lines apart, disagreeing about the run.
        #expect(raw.contains("Test run with 3 tests in 1 suite failed after 0.001 seconds with 2 issues."))
        #expect(raw.contains("Test run with 3 tests in 1 suite passed after 0.001 seconds with 1 known issue."))
        #expect(report.summaryLines == [
            "** TEST FAILED **",
            "Test run with 3 tests in 1 suite failed after 0.001 seconds with 2 issues.",
            "Test run with 3 tests in 1 suite passed after 0.001 seconds with 1 known issue.",
        ])
        // No single tally stands for the run, so there is none — and so no unlabelled line of arithmetic.
        #expect(report.tally == nil)

        let answer = RunReportRenderer(kind: .xcodebuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Two"))
            .render(report, exitCode: 65, logURL: nil)
        #expect(answer.hasPrefix("✘ xcodebuild — exit 65\n"))
        // The failing bundle recorded no known issue, so it contributes no arithmetic line of its own —
        // and nothing here reads as a sum of the two bundles' failures.
        #expect(!answer.contains("Swift Testing: 0 failures"))
        #expect(!answer.contains("Swift Testing: 2 failures"))
        // The passing bundle's known issue still prints, labelled by its own tally — and since both
        // bundles' counts happen to agree (3 tests in 1 suite), the label also carries this tally's
        // position among the two, or the line would be indistinguishable from one summing them.
        #expect(answer.contains("\n  Swift Testing (bundle 2 of 2, 3 tests in 1 suite): 0 failures, 1 known issue\n"))
        // And what is left reconciles: two failures, both named — a run this small lists every one of
        // them — under measurements that say the two are two separate problems rather than one twice.
        #expect(report.testFailures.count == 2)
        #expect(answer.contains("\n2 failures · 2 signatures · 1 file · changed files unknown — the working tree was not consulted\n"))
        #expect(answer.contains("\n  labellingIsWrong() — AlphaTests.swift:10:9\n"))
        #expect(answer.contains("\n  doublingIsWrong() — AlphaTests.swift:6:9\n"))
        // Every failure named, so no line of the answer stands for more than one of them.
        #expect(!answer.contains("  ×"))
        #expect(!answer.contains("more signature"))
    }

    /// A run with two XCTest bundles closes with two `Executed …` counters, and the last of them is not the run's either.
    ///
    /// The Swift Testing side is a list for exactly this reason, and an XCTest side kept as one value lets a passing bundle's count overwrite a failing one's: `Executed 4 tests, with 0 failures (0 unexpected)` printed directly beneath `✘ xcodebuild — exit 65`, with the twelve tests and three failures that produced the exit code nowhere in the answer. The two-bundle capture cannot catch it — both of its `Executed` lines are the `0 tests` boilerplate — so this one has two bundles of real `XCTestCase`s, `AlphaTests` failing three of twelve and `BetaTests` passing all four.
    @Test
    func twoXCTestBundlesLeaveBothCountersAndTheFailingOneIsNotOverwritten() throws {
        let raw = try TestSources.runOutput("xcodebuild-test-two-xctest-bundles")
        let report = try TestSources.runReport("xcodebuild-test-two-xctest-bundles", invokedAs: Self.duoBundles)

        // Each bundle prints its counter three times — per suite, per bundle, per run — and only the last
        // of those speaks for the process, which is what makes last-wins right inside one and wrong across two.
        #expect(raw.components(separatedBy: "Executed 12 tests, with 3 failures").count - 1 == 3)
        #expect(raw.components(separatedBy: "Executed 4 tests, with 0 failures").count - 1 == 3)
        #expect(report.summaryLines == [
            "** TEST FAILED **",
            "Executed 12 tests, with 3 failures (0 unexpected) in 0.315 (0.318) seconds",
            "Executed 4 tests, with 0 failures (0 unexpected) in 0.003 (0.005) seconds",
        ])

        let answer = RunReportRenderer(kind: .xcodebuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Duo"))
            .render(report, exitCode: 65, logURL: nil)
        #expect(answer.hasPrefix("✘ xcodebuild — exit 65\n"))
        #expect(answer.contains("\n  Executed 12 tests, with 3 failures (0 unexpected) in 0.315 (0.318) seconds\n"))
        // And the three failures the counter names are the three the answer names.
        #expect(report.testFailures.map(\.name).sorted() == [
            "-[AlphaTests.AlphaTests testDoubling02]",
            "-[AlphaTests.AlphaTests testDoubling05]",
            "-[AlphaTests.AlphaTests testDoubling09]",
        ])
    }

    /// An option value spelled like an action word is doubt, and a later bare action word settles it.
    ///
    /// Returning ``RunVerdict/Contract/unreadable`` on the spot at the collision would throw away every argument behind it: `-derivedDataPath build … test` stops at `build` and never reaches the bare `test` four words later, so a shape a CI script writes constantly draws `⚠ … could not tell which verdict the command owed` over a log closing on `** TEST SUCCEEDED **`. The `⚠` is the signal this whole path exists for, and spending it on a green run is what makes it stop being read.
    ///
    /// **A collision standing *after* the last bare action still refuses**, and that half is what keeps the reading safe: if this table is wrong about the flag in front of it taking a value, that word is the run's last action and the wording owed is a different one.
    @Test
    func aCollidingOptionValueIsDoubtALaterActionCanSettle() throws {
        let testing = RunVerdict.Contract.declares(succeeded: "** TEST SUCCEEDED **", failed: "** TEST FAILED **")
        let derived = ["xcodebuild", "-derivedDataPath", "build", "-scheme", "App", "-destination", "platform=macOS", "test"]

        #expect(RunVerdict.Contract.of(derived) == testing)
        #expect(RunVerdict.Contract.of(["xcodebuild", "-resultBundlePath", "archive", "-scheme", "App", "test"]) == testing)
        #expect(RunVerdict.Contract.of(["xcodebuild", "-derivedDataPath", "clean", "build"])
            == .declares(succeeded: "** BUILD SUCCEEDED **", failed: "** BUILD FAILED **"))
        // Behind the last bare action there is nothing left to settle it, so the doubt stands.
        #expect(RunVerdict.Contract.of(["xcodebuild", "test", "-derivedDataPath", "build"]) == .unreadable)
        // And a collision with no bare action anywhere is unreadable either way.
        #expect(RunVerdict.Contract.of(["xcodebuild", "-scheme", "test", "-project", "Gizmo.xcodeproj"]) == .unreadable)

        // End to end: the green capture under that invocation is a pass, not a `⚠`.
        let report = try TestSources.runReport("xcodebuild-test-success", invokedAs: derived)
        #expect(Self.answer(report, exitCode: 0).hasPrefix("✔ xcodebuild\n"))
    }

    /// `swift build` announces failure only as the errors it printed, so the absence of `Build complete!` is the verdict rather than the absence of one.
    @Test
    func aSwiftBuildFailureIsFailedByItsOwnErrors() throws {
        let report = try TestSources.runReport("swift-build-failure", invokedAs: ["swift", "build"])
        let verdict = try #require(report.verdict)

        #expect(verdict.state == .failed)
        #expect(verdict.line == nil)
        #expect(RunReportRenderer(kind: .swiftBuild, workingDirectory: Self.workingDirectory)
            .render(report, exitCode: 1, logURL: nil)
            .hasPrefix("✘ swift build — exit 1"))
    }

    /// A package with more than one Swift Testing test target closes `swift test` with more than one tally, one per process — and a package whose bundles all pass is a package that passed, named by no single line because none of the bundles' own sentences speaks for the pair of them.
    @Test
    func twoPassingSwiftTestBundlesSucceedAsAPackage() {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(line: "✔ Test run with 4 tests in 2 suites passed after 0.010 seconds.")
        filter.consume(line: "✔ Test run with 6 tests in 3 suites passed after 0.020 seconds.")
        let report = filter.finish()

        #expect(report.verdict?.state == .succeeded)
        #expect(report.verdict?.line == nil)
        // No single tally speaks for the pair, so none is invented as the answer's own count either.
        #expect(report.tally == nil)
    }

    /// Any bundle failing fails the package regardless of which one the log prints first, and the verdict names that bundle's own tally rather than the other one or a sum of the two.
    @Test
    func eitherOrderOfAFailingBundleFailsThePackage() {
        let passing = "✔ Test run with 4 tests in 2 suites passed after 0.010 seconds."
        let failing = "✘ Test run with 6 tests in 3 suites failed after 0.020 seconds with 2 issues."
        // The verdict's line is the undecorated sentence `RunOutputFilter` files, its own status glyph
        // already stripped — see ``RunOutputFilter/undecorated(_:)``.
        let failingSentence = "Test run with 6 tests in 3 suites failed after 0.020 seconds with 2 issues."
        for lines in [[passing, failing], [failing, passing]] {
            var filter = RunOutputFilter(expecting: .runTally)
            for line in lines {
                filter.consume(line: line)
            }
            let report = filter.finish()

            #expect(report.verdict?.state == .failed, "\(lines)")
            #expect(report.verdict?.line == failingSentence, "\(lines)")
        }
    }

    /// The exact shape a real two-bundle `swift test` closes on.
    ///
    /// Each process's XCTest half opens and closes with the `Executed 0 tests` boilerplate — because neither bundle holds a single `XCTestCase` — before either bundle's Swift Testing half has printed a line, and two Swift Testing tallies follow, far apart, both `passed`. This is the shape that read as `⚠ swift test — exit 0, and no verdict in the log` over a fully green two-bundle package before ``RunOutputFilter/multiBundleTallyVerdict()`` existed to reconcile more than one tally.
    @Test
    func theTwoVestigialXCTestCountersInFrontOfTwoTalliesDoNotHideThePass() {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "Test Suite 'All tests' started at 2026-09-12 18:25:47.288.",
            "Test Suite 'All tests' passed at 2026-09-12 18:25:47.289.",
            "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds",
            "Test Suite 'All tests' started at 2026-09-12 18:25:47.366.",
            "Test Suite 'All tests' passed at 2026-09-12 18:25:47.366.",
            "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds",
            "✔ Test run with 977 tests in 87 suites passed after 70.576 seconds.",
            "✔ Test run with 1091 tests in 95 suites passed after 42.373 seconds.",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish()

        #expect(report.verdict?.state == .succeeded)
        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: Self.workingDirectory)
            .render(report, exitCode: 0, logURL: nil)
        #expect(answer.hasPrefix("✔ swift test\n"))
    }

    /// The invocation the four verdict-reader captures were taken under, recorded in `PROVENANCE.md` and in each capture's own `Command line invocation:` line.
    private static var testWithoutBuilding: [String] {
        ["xcodebuild", "-scheme", "Depot-Package", "-destination", "id=00000000-0000-0000-0000-000000000000", "test-without-building"]
    }

    /// The invocation the two-bundle capture was taken under, recorded in `PROVENANCE.md`.
    private static var twoBundles: [String] {
        ["xcodebuild", "-scheme", "Two-Package", "-destination", "platform=macOS", "test"]
    }

    /// The invocation the two-XCTest-bundle capture was taken under, recorded in `PROVENANCE.md`.
    private static var duoBundles: [String] {
        ["xcodebuild", "-scheme", "Duo-Package", "-destination", "platform=macOS", "test"]
    }

    private static var workingDirectory: URL {
        URL(fileURLWithPath: "/Users/dev/Depot")
    }

    private static func answer(_ report: RunReport, exitCode: Int32) -> String {
        RunReportRenderer(kind: .xcodebuild, workingDirectory: workingDirectory)
            .render(report, exitCode: exitCode, logURL: URL(fileURLWithPath: "/Users/dev/Depot/.sift/runs/run-20260906-194437-1c4de9a2.log"))
    }
}
