//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a run that named its tests and executed none of them — `swift test --filter`, `xcodebuild -only-testing:` — which both tools report as a success.
///
/// Both captures are real: `swift-test-no-match.txt` and `xcodebuild-test-no-match.txt`. `Fixtures/RunOutput/PROVENANCE.md` says where each came from.
struct RunTestSelectorTests {
    @Test
    func aFilterThatMatchedNothingIsAFailureNamingTheFilter() throws {
        let arguments = ["swift", "test", "--filter", "aFailingTest"]
        let report = try TestSources.runReport("swift-test-no-match", invokedAs: arguments, exitCode: 0)
        let selector = try #require(RunTestSelector.named(in: arguments))
        #expect(selector.matchedNothing(report, exitCode: 0))

        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"), selector: selector)
            .render(report, exitCode: 0, logURL: nil)
        let lines = answer.split(separator: "\n").map(String.init)
        #expect(lines.first == "✘ swift test — nothing ran: no test matched --filter aFailingTest (the command exited 0; sift run exits 4)")
        #expect(lines.contains { $0.hasPrefix("totals: ✘ nothing ran — no test matched --filter aFailingTest") })
        #expect(!answer.contains("✔"))
    }

    @Test
    func anOnlyTestingIdentifierThatMatchedNothingCarriesTheParenthesesHint() throws {
        let arguments = ["xcodebuild", "-project", "Gizmo.xcodeproj", "-scheme", "Gizmo", "test", "-only-testing:GizmoTests/GizmoTests/aTrendIsRead"]
        let report = try TestSources.runReport("xcodebuild-test-no-match", invokedAs: arguments, exitCode: 0)
        // The log's own verdict is a pass, which is exactly what this must not repeat.
        #expect(report.verdict?.state == .succeeded)
        let selector = try #require(RunTestSelector.named(in: arguments))

        let answer = RunReportRenderer(kind: .xcodebuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Gizmo"), selector: selector)
            .render(report, exitCode: 0, logURL: nil)
        let headline = try #require(answer.split(separator: "\n").first.map(String.init))
        #expect(headline.hasPrefix("✘ xcodebuild — nothing ran: no test matched -only-testing:GizmoTests/GizmoTests/aTrendIsRead (the command exited 0; sift run exits 4)"))
        #expect(headline.hasSuffix("if it names a Swift Testing function, spell it with the trailing (): -only-testing:GizmoTests/GizmoTests/aTrendIsRead()"))
        #expect(!answer.contains("✔"))
    }

    /// No hint where a missing `()` means nothing: a whole bundle, or an identifier already spelled with it.
    @Test
    func theParenthesesHintIsOnlyForAnIdentifierBelowABundleWithoutThem() throws {
        let bundle = try #require(RunTestSelector.named(in: ["xcodebuild", "test", "-only-testing", "GizmoTests"]))
        #expect(bundle.spellings == ["-only-testing:GizmoTests"])
        #expect(!bundle.headline(label: "xcodebuild").contains("trailing"))
        let spelled = try #require(RunTestSelector.named(in: ["xcodebuild", "test", "-only-testing:GizmoTests/GizmoTests/aTrendIsRead()"]))
        #expect(!spelled.headline(label: "xcodebuild").contains("trailing"))
    }

    /// A run that named no test keeps the answer it always had, zero tests and all; and a run that did run tests is not judged.
    @Test
    func onlyASelectedRunThatExecutedNothingIsJudged() throws {
        #expect(RunTestSelector.named(in: ["swift", "test"]) == nil)
        #expect(RunTestSelector.named(in: ["xcodebuild", "test", "-skip-testing:GizmoTests"]) == nil)
        #expect(RunTestSelector.named(in: ["swift", "build", "--filter", "aFailingTest"]) == nil)
        #expect(RunTestSelector.named(in: ["swift", "test", "--filter=aFailingTest"])?.spellings == ["--filter aFailingTest"])

        let unselected = try TestSources.runReport("swift-test-no-match", invokedAs: ["swift", "test"], exitCode: 0)
        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"))
            .render(unselected, exitCode: 0, logURL: nil)
        #expect(answer.hasPrefix("⚠ swift test — exit 0, and no verdict in the log"))

        let selector = try #require(RunTestSelector.named(in: ["swift", "test", "--filter", "Widget"]))
        let ran = try TestSources.runReport("swift-test-pass", invokedAs: ["swift", "test"], exitCode: 0)
        #expect(!selector.matchedNothing(ran, exitCode: 0))
        // A nonzero exit already fails on its own terms, and keeps its own headline.
        let failed = try TestSources.runReport("swift-test-no-match", invokedAs: ["swift", "test"], exitCode: 1)
        #expect(!selector.matchedNothing(failed, exitCode: 1))
    }

    /// `swift test --parallel` prints only a progress line for an XCTest it ran and passed: no outcome and no count, which is silence and not a zero.
    @Test
    func aParallelFilteredRunThatPrintedOnlyProgressIsNotJudged() throws {
        let arguments = ["swift", "test", "--filter", "testGamma", "--parallel"]
        let report = try TestSources.runReport("swift-test-parallel-filter-pass", invokedAs: arguments, exitCode: 0)
        let selector = try #require(RunTestSelector.named(in: arguments))
        #expect(!selector.matchedNothing(report, exitCode: 0))

        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Gadget"), selector: selector)
            .render(report, exitCode: 0, logURL: nil)
        #expect(!answer.contains("✘"))
        #expect(!answer.contains("nothing ran"))
    }

    /// `xcodebuild -quiet` prints no test line and no verdict on a clean pass, and that silence over exit 0 is read as a pass, selector or none.
    @Test
    func aQuietSelectedRunIsReadAsTheQuietPassItIs() throws {
        let arguments = ["xcodebuild", "-quiet", "-project", "Gizmo.xcodeproj", "-scheme", "Gizmo", "test", "-only-testing:GizmoTests/GizmoTests/aTrendIsRead"]
        let report = try TestSources.runReport("xcodebuild-quiet-test-success", invokedAs: arguments, exitCode: 0)
        let selector = try #require(RunTestSelector.named(in: arguments))
        #expect(!selector.matchedNothing(report, exitCode: 0))

        let answer = RunReportRenderer(kind: .xcodebuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Gizmo"), selector: selector)
            .render(report, exitCode: 0, logURL: nil)
        #expect(answer.hasPrefix("✔ xcodebuild"))
        #expect(!answer.contains("trailing ()"))
    }

    /// `xcodebuild`'s parallel testing prints a suite's start on its runner and then a `Test case '…' on` line per test; a start with no test under it is a runner that ran nothing, and that is a zero rather than silence.
    ///
    /// The capture is real (`xcodebuild-parallel-test-no-match.txt`): an XCTest method that does not exist, which prints the suite's start, `** TEST EXECUTE SUCCEEDED **`, and nothing else.
    @Test
    func aParallelRunnerThatStartedASuiteAndRanNoTestMatchedNothing() throws {
        let arguments = ["xcodebuild", "-scheme", "Gadget-Package", "-destination", "platform=macOS", "-parallel-testing-enabled", "YES", "test-without-building", "-only-testing:GadgetTests/Legacy/testNope"]
        let report = try TestSources.runReport("xcodebuild-parallel-test-no-match", invokedAs: arguments, exitCode: 0)
        #expect(report.verdict?.state == .succeeded)
        let selector = try #require(RunTestSelector.named(in: arguments))
        #expect(selector.matchedNothing(report, exitCode: 0))

        let answer = RunReportRenderer(kind: .xcodebuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Gadget"), selector: selector)
            .render(report, exitCode: 0, logURL: nil)
        let headline = try #require(answer.split(separator: "\n").first.map(String.init))
        #expect(headline.hasPrefix("✘ xcodebuild — nothing ran: no test matched -only-testing:GadgetTests/Legacy/testNope (the command exited 0; sift run exits 4)"))
        #expect(headline.hasSuffix("spell it with the trailing (): -only-testing:GadgetTests/Legacy/testNope()"))
        #expect(!answer.contains("✔"))
        #expect(!Self.outcome(of: report, exitCode: 0).provedGreen(testBundles: .undetermined, selector: selector))
    }

    /// The same runner with a test under it — the lines a real passing parallel run of `-only-testing:GadgetTests/Legacy/testGamma` printed — ran one, is not judged, and proves its tree.
    @Test
    func aParallelRunnerThatRanATestIsNotJudged() throws {
        let arguments = ["xcodebuild", "-parallel-testing-enabled", "YES", "test-without-building", "-only-testing:GadgetTests/Legacy/testGamma"]
        var filter = RunOutputFilter(invokedAs: arguments)
        filter.consume(Data("""
        ** TEST EXECUTE SUCCEEDED **

        Testing started
        Test suite 'Legacy' started on 'My Mac - xctest (3929)'
        Test case 'Legacy.testGamma()' passed on 'My Mac - xctest (3929)' (0.001 seconds)

        """.utf8))
        let report = filter.finish(exitCode: 0)
        let selector = try #require(RunTestSelector.named(in: arguments))

        #expect(!selector.matchedNothing(report, exitCode: 0))
        #expect(Self.outcome(of: report, exitCode: 0).provedGreen(testBundles: .undetermined, selector: selector))
    }

    /// A non-quiet `xcodebuild` selected run whose printed success banner stands over no test line ran none: the real capture of a Swift Testing function named without its `()` under parallel testing, which printed only `** TEST EXECUTE SUCCEEDED **`, answers `✘` with the `()` hint and proves nothing.
    @Test
    func aPrintedBannerOverNoTestLineIsAZero() throws {
        let arguments = ["xcodebuild", "-parallel-testing-enabled", "YES", "test-without-building", "-only-testing:GadgetTests/Modern/aTrendIsRead"]
        let report = try TestSources.runReport("xcodebuild-parallel-test-unparenthesised", invokedAs: arguments, exitCode: 0)
        let selector = try #require(RunTestSelector.named(in: arguments))

        #expect(report.verdict?.line == "** TEST EXECUTE SUCCEEDED **")
        #expect(selector.matchedNothing(report, exitCode: 0))
        let answer = RunReportRenderer(kind: .xcodebuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Gadget"), selector: selector)
            .render(report, exitCode: 0, logURL: nil)
        let headline = try #require(answer.split(separator: "\n").first.map(String.init))
        #expect(headline.hasPrefix("✘ xcodebuild — nothing ran: no test matched -only-testing:GadgetTests/Modern/aTrendIsRead (the command exited 0; sift run exits 4)"))
        #expect(headline.hasSuffix("spell it with the trailing (): -only-testing:GadgetTests/Modern/aTrendIsRead()"))
        #expect(!answer.contains("✔"))
        #expect(!Self.outcome(of: report, exitCode: 0).provedGreen(testBundles: .undetermined, selector: selector))
    }

    /// A `-quiet` pass prints no line for its tests and no banner either, so its silence is not a zero: it reads as the pass its exit code says, and proves nothing.
    @Test
    func aQuietSelectedRunSilentAboutItsTestsProvesNothing() throws {
        let arguments = ["xcodebuild", "-quiet", "test", "-only-testing:GizmoTests/GizmoTests/aTrendIsRead"]
        let report = try TestSources.runReport("xcodebuild-quiet-test-success", invokedAs: arguments, exitCode: 0)
        let selector = try #require(RunTestSelector.named(in: arguments))

        #expect(!selector.matchedNothing(report, exitCode: 0))
        #expect(!RunTestSelector.showsATestRan(report))
        #expect(!Self.outcome(of: report, exitCode: 0).provedGreen(testBundles: .undetermined, selector: selector))
    }

    /// The banner rule rests on a non-quiet `xcodebuild` printing a line for every test it runs, so every real passing capture of one shows a test ran and is not judged a zero.
    @Test(arguments: [
        "xcodebuild-test-success",
        "xcodebuild-test-execute-success",
        "xcodebuild-retry-iterations",
        "xcodebuild-test-underscored-module",
    ])
    func everyRealPassingXcodebuildRunShowsATestRan(fixture: String) throws {
        let arguments = ["xcodebuild", "test", "-only-testing:GizmoTests"]
        let report = try TestSources.runReport(fixture, invokedAs: arguments, exitCode: 0)
        let selector = try #require(RunTestSelector.named(in: arguments))

        #expect(RunTestSelector.showsATestRan(report))
        #expect(!selector.matchedNothing(report, exitCode: 0))
    }

    /// A non-quiet log cut short before any banner is undecided rather than a zero, whatever it failed to print.
    @Test
    func aLogWithNoBannerIsNotAZero() throws {
        let arguments = ["xcodebuild", "-parallel-testing-enabled", "YES", "test-without-building", "-only-testing:GadgetTests/Modern/aTrendIsRead"]
        var filter = RunOutputFilter(invokedAs: arguments)
        filter.consume(Data("Testing started\n".utf8))
        let report = filter.finish(exitCode: 0)
        let selector = try #require(RunTestSelector.named(in: arguments))

        #expect(report.verdict == nil)
        #expect(!selector.matchedNothing(report, exitCode: 0))
    }

    private static func outcome(of report: RunReport, exitCode: Int32) -> RunOutcome {
        RunOutcome(kind: .xcodebuild, logKey: "xcodebuild test", exitCode: exitCode, report: report, log: nil, repositoryRoot: nil)
    }

    /// A filtered `swift test` whose tests did not compile ran none of them, and says so rather than exiting 1 as a failing test does: a negative gate must not read a compile error as its proof.
    @Test(arguments: ["swift-test-filter-compile-error", "swift-test-linkerror", "swift-test-linkerror-6.4"])
    func aFilteredSwiftTestThatDidNotBuildExitsItsOwnCode(fixture: String) throws {
        let arguments = ["swift", "test", "--filter", "WidgetTests"]
        let report = try TestSources.runReport(fixture, invokedAs: arguments, exitCode: 1)
        let selector = try #require(RunTestSelector.named(in: arguments))
        #expect(selector.ownExitCode(report, exitCode: 1) == RunTestSelector.didNotBuildExitCode)
        #expect(RunTestSelector.didNotBuildExitCode == 5)

        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"), selector: selector)
            .render(report, exitCode: 1, logURL: nil)
        let lines = answer.split(separator: "\n").map(String.init)
        #expect(lines.first == "✘ swift test — did not build — no test ran (the command exited 1; sift run exits 5)")
        #expect(lines.contains { $0.hasPrefix("totals: ✘ did not build — no test ran") })
    }

    /// The same for `xcodebuild -only-testing:`, whose build failure is 65, the code its test failures exit with too.
    @Test
    func anOnlyTestingRunThatDidNotBuildExitsItsOwnCode() throws {
        let arguments = ["xcodebuild", "-scheme", "Widget", "-destination", "platform=macOS", "test", "-only-testing:WidgetTests"]
        let report = try TestSources.runReport("xcodebuild-test-only-testing-compile-error", invokedAs: arguments, exitCode: 65)
        let selector = try #require(RunTestSelector.named(in: arguments))
        #expect(selector.ownExitCode(report, exitCode: 65) == RunTestSelector.didNotBuildExitCode)

        let answer = RunReportRenderer(kind: .xcodebuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"), selector: selector)
            .render(report, exitCode: 65, logURL: nil)
        #expect(answer.split(separator: "\n").first.map(String.init) == "✘ xcodebuild — did not build — no test ran (the command exited 65; sift run exits 5)")
    }

    /// A run that failed its tests, a failure with no compiler error in it, and a run that named no test all keep the exit code they were handed.
    @Test
    func onlyASelectedRunThatFailedToBuildIsReadAsNotBuilding() throws {
        let filtered = try #require(RunTestSelector.named(in: ["swift", "test", "--filter", "Widget"]))
        let failedATest = try TestSources.runReport("swift-test-fail", invokedAs: ["swift", "test", "--filter", "Widget"], exitCode: 1)
        #expect(filtered.ownExitCode(failedATest, exitCode: 1) == nil)

        var filter = RunOutputFilter(invokedAs: ["swift", "test", "--filter", "Widget"])
        filter.consume(Data("error: no tests found; create a target in the 'Tests' directory\n".utf8))
        let unlocated = filter.finish(exitCode: 1)
        #expect(filtered.ownExitCode(unlocated, exitCode: 1) == nil)

        let unfiltered = try TestSources.runReport("swift-test-filter-compile-error", invokedAs: ["swift", "test"], exitCode: 1)
        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"))
            .render(unfiltered, exitCode: 1, logURL: nil)
        #expect(!answer.contains("did not build"))
    }

    /// A build failure `xcodebuild` reports with no `file:line` at all — a signing failure, a missing build input file — still exits 65 as though a test had failed, and leaves `errors` with nothing the file:line rule can key on; `Testing cancelled because the build failed.` is the positive evidence that stands in.
    @Test(arguments: ["xcodebuild-test-signing-failure", "xcodebuild-test-missing-input-file"])
    func aBuildFailureWithNoFileLineStillReadsAsDidNotBuild(fixture: String) throws {
        let arguments = ["xcodebuild", "-scheme", "Widget", "-destination", "platform=macOS", "-derivedDataPath", "/Users/dev/dd", "test", "-only-testing:WidgetTests"]
        let report = try TestSources.runReport(fixture, invokedAs: arguments, exitCode: 65)
        let selector = try #require(RunTestSelector.named(in: arguments))

        #expect(selector.ownExitCode(report, exitCode: 65) == RunTestSelector.didNotBuildExitCode)
    }

    /// A `-quiet` run's own Swift Testing failure line reads exactly like a compiler error at a file and line, but `xcodebuild` only ever prints `Failing tests:` once a named test actually ran and failed — so it must veto `didNotBuild` even where that line is the only diagnostic in the log.
    @Test
    func aFailingTestsBlockVetoesDidNotBuildEvenWithAFileLineError() throws {
        let arguments = ["xcodebuild", "-scheme", "Widget", "-destination", "platform=macOS", "test", "-only-testing:WidgetTests", "-quiet"]
        let report = try TestSources.runReport("xcodebuild-test-quiet-real-failure", invokedAs: arguments, exitCode: 65)
        let selector = try #require(RunTestSelector.named(in: arguments))

        #expect(selector.ownExitCode(report, exitCode: 65) == nil, "a Failing tests: block is a real test failure, not a build that never ran one")
    }

    /// Only an action that executes tests has a selector to judge: `build-for-testing` runs none whatever it names, and an action argv leaves in doubt is not guessed.
    @Test
    func aSelectorIsJudgedOnlyUnderAnActionThatRunsTests() {
        #expect(RunTestSelector.named(in: ["xcodebuild", "build-for-testing", "-scheme", "Gizmo", "-only-testing:GizmoTests/GizmoTests/aTrendIsRead"]) == nil)
        #expect(RunTestSelector.named(in: ["xcodebuild", "-scheme", "Gizmo", "-derivedDataPath", "build", "-only-testing:GizmoTests"]) == nil)
        #expect(RunTestSelector.named(in: ["xcodebuild", "test-without-building", "-only-testing:GizmoTests"])?.spellings == ["-only-testing:GizmoTests"])
    }
}
