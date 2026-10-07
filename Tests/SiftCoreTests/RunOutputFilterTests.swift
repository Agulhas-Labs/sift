//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers what `sift run` keeps and what it drops, against real captured toolchain output.
///
/// Every fixture under `Fixtures/RunOutput` is a transcript of a real run — see that directory's `PROVENANCE.md`. Hand-written input would only ever prove the filter matches what the author expected the toolchain to print, which is the assumption most worth not making.
struct RunOutputFilterTests {
    @Test
    func aCleanBuildKeepsItsOwnSummaryAndItsWarnings() throws {
        let report = try TestSources.runReport("swift-build-success")

        #expect(report.summaryLines == ["Build complete! (0.36s)"])
        #expect(report.errors.isEmpty)
        #expect(report.warnings.count == 2)
        #expect(report.testFailures.isEmpty)
    }

    @Test
    func compileErrorsKeepTheirFileLineAndColumn() throws {
        let report = try TestSources.runReport("swift-build-failure")

        #expect(report.errors.count == 2)
        let first = try #require(report.errors.first)
        #expect(first.path == "/Users/dev/Widget/Sources/Widget/Broken.swift")
        #expect(first.line == 4)
        #expect(first.column == 9)
        #expect(first.message == "cannot find 'missingSymbol' in scope")
    }

    @Test
    func aBuildThatPrintedNoSummaryIsNotGivenOne() throws {
        let report = try TestSources.runReport("swift-build-failure")

        #expect(report.summaryLines.isEmpty)
        let answer = RunReportRenderer(kind: .swiftBuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"))
            .render(report, exitCode: 1, logURL: nil)
        #expect(answer.contains("no closing summary line in the log — the errors below are what it reported"))
        #expect(!answer.contains("see the raw log"))
    }

    @Test
    func bothTestFrameworksReportTheirFailures() throws {
        let report = try TestSources.runReport("swift-test-fail")

        // One XCTest assertion and two Swift Testing expectations, from the same `swift test` run.
        #expect(report.testFailures.count == 3)
        let names = report.testFailures.map(\.name)
        #expect(names.contains("-[WidgetTests.LegacyWidgetTests testNaming]"))
        #expect(names.contains("shoutingWorks()"))
        #expect(names.contains("sizeIsCarried()"))
        let expectation = try #require(report.testFailures.first { $0.name == "sizeIsCarried()" })
        #expect(expectation.location == "WidgetTests.swift:14:9")
        #expect(expectation.message == "Expectation failed: (Widget(size: 4).size → 4) == 5")
        let assertion = try #require(report.testFailures.first { $0.name.hasPrefix("-[") })
        #expect(assertion.location == "/Users/dev/Widget/Tests/WidgetTests/LegacyWidgetTests.swift:10")
        #expect(assertion.message == "XCTAssertEqual failed: (\"X\") is not equal to (\"x\")")
    }

    @Test
    func aPassingRunKeepsEveryFrameworksCountAndNothingElse() throws {
        let report = try TestSources.runReport("swift-test-pass")

        #expect(report.testFailures.isEmpty)
        #expect(report.errors.isEmpty)
        #expect(report.summaryLines.contains("Executed 2 tests, with 0 failures (0 unexpected) in 0.001 (0.003) seconds"))
        #expect(report.summaryLines.contains("Test run with 2 tests in 1 suite passed after 0.001 seconds."))
        // The Swift Testing glyph is decoration; the sentence is the summary.
        #expect(report.summaryLines.allSatisfy { !$0.hasPrefix("\u{1005DB}") })
    }

    @Test
    func anUndefinedSymbolsBlockIsKeptWhole() throws {
        let report = try TestSources.runReport("swift-test-linkerror")

        let block = try #require(report.errors.first { $0.message.hasPrefix("Undefined symbols") })

        #expect(block.detail.contains { $0.contains("\"_widget_missing_helper\", referenced from:") })
        #expect(block.detail.contains { $0.contains("Widget.callMissingHelper() -> Swift.Int in Linkless.swift.o") })
        // The two lines the linker closes with belong to the block, not to the noise after it.
        #expect(block.detail.contains("ld: symbol(s) not found for architecture arm64"))
        #expect(block.detail.contains("clang: error: linker command failed with exit code 1 (use -v to see invocation)"))
    }

    @Test
    func anErrorLineEndingInAColonCarriesItsCauseWithIt() throws {
        // `error: Could not resolve package dependencies:` is a heading —
        // the reason is the indented block beneath it, and dropping that leaves the answer saying only
        // that resolution failed, which the exit code already said.
        let report = try TestSources.runReport("xcodebuild-build-failure-unresolved-package")

        #expect(report.errors.count == 1)
        let error = try #require(report.errors.first)
        #expect(error.message == "Could not resolve package dependencies:")
        #expect(error.detail == [
            "  Failed to clone repository https://example.com/sift-fixture-org/DepotKit:",
            "    Cloning into bare repository '/Users/dev/Gizmo/DerivedData/SourcePackages/repositories/DepotKit-e5357a9c'...",
            "    fatal: repository 'https://example.com/sift-fixture-org/DepotKit/' not found",
        ])
    }

    @Test
    func xcodebuildRepeatingADiagnosticReportsItOnce() throws {
        let raw = try TestSources.runOutput("xcodebuild-build-failure-dup")
        let report = try TestSources.runReport("xcodebuild-build-failure-dup")

        // xcodebuild reported this one twice — once emitting the module, once compiling the file.
        #expect(raw.components(separatedBy: "error: cannot find type 'MissingWidget' in scope").count - 1 == 2)
        #expect(report.errors.filter { $0.message == "cannot find type 'MissingWidget' in scope" }.count == 1)
        #expect(report.errors.count == 2)
        #expect(report.summaryLines == ["** BUILD FAILED **"])
    }

    @Test
    func aFailingXcodebuildTestRunNamesTheTestAndTheResult() throws {
        let report = try TestSources.runReport("xcodebuild-test-failure")

        #expect(report.testFailures.count == 1)
        let failure = try #require(report.testFailures.first)
        #expect(failure.name == "-[GizmoTests.GizmoTests testDoubling]")
        #expect(failure.message == "XCTAssertEqual failed: (\"6\") is not equal to (\"7\")")
        #expect(report.summaryLines.contains("** TEST FAILED **"))
        #expect(report.summaryLines.contains("Executed 1 test, with 1 failure (0 unexpected) in 0.312 (0.314) seconds"))
    }

    @Test
    func aPassingXcodebuildRunIsTenLinesOutOfEightHundred() throws {
        let report = try TestSources.runReport("xcodebuild-test-success")

        #expect(report.totalLines > 800)
        #expect(report.summaryLines == [
            "** TEST SUCCEEDED **",
            "Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.003) seconds",
        ])
        #expect(report.errors.isEmpty)
        #expect(report.testFailures.isEmpty)
        // Two summary lines and the three warnings the build genuinely raised; nothing else survives.
        #expect(report.warnings.count == 3)
        // And the answer they make is those five plus a headline, a warnings heading, a blank line and
        // the receipt — nine lines over eight hundred, which the receipt states about itself.
        let answer = RunReportRenderer(kind: .xcodebuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Gizmo"))
            .render(report, exitCode: 0, logURL: nil)
        #expect(answer.split(separator: "\n", omittingEmptySubsequences: false).count == 9)
        #expect(answer.contains("(\(report.totalLines) lines in, 9 out)"))
    }

    @Test
    func theBuildSystemsOwnChatterIsDropped() throws {
        let answer = try renderedAnswer("xcodebuild-build-success", kind: .xcodebuild, exitCode: 0)

        // The per-file invocations and their argument dumps are the bulk of an xcodebuild log and the
        // whole reason this command exists.
        #expect(!answer.contains("CompileC "))
        #expect(!answer.contains("builtin-copy"))
        #expect(!answer.contains("ExtractAppIntentsMetadata"))
        #expect(!answer.contains("-index-store-path"))
        #expect(answer.contains("** BUILD SUCCEEDED **"))
    }

    @Test
    func aTimestampedToolLogIsNotReadAsADiagnostic() throws {
        let report = try TestSources.runReport("xcodebuild-test-success")

        // `… appintentsmetadataprocessor[60634:31513990] warning: Metadata extraction skipped …` looks
        // like a diagnostic and is not one; only a line number or a tool naming itself earns that reading.
        #expect(!report.warnings.contains { $0.message.hasPrefix("Metadata extraction skipped") })
    }

    @Test
    func aLinkerNamingItselfStillCounts() throws {
        let report = try TestSources.runReport("xcodebuild-test-failure")

        #expect(report.warnings.contains { $0.path == nil && $0.message.hasPrefix("building for macOS-13.0") })
    }

    /// Every answer's receipt states the size of the answer it sits at the bottom of, on every capture in the corpus.
    ///
    /// The receipt is the one line the whole compression is trusted on, so what it says has to be a fact about the text above it rather than a number arrived at separately. A number arrived at separately — a `shownLines` accumulated while parsing, counting every input line whose text survived *somewhere* — stops describing the answer the moment the failures are served as a shape rather than a listing, and the receipt then claims hundreds of lines shown over an answer of a couple of dozen.
    @Test
    func everyFixturesReceiptStatesTheSizeOfTheAnswerItEnds() throws {
        for name in Self.fixtureNames {
            let report = try TestSources.runReport(name)
            let answer = RunReportRenderer(kind: .xcodebuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Gizmo"))
                .render(report, exitCode: 0, logURL: nil)
            let lines = answer.split(separator: "\n", omittingEmptySubsequences: false)

            #expect(lines.last == "raw: none (\(report.totalLines) lines in, \(lines.count) out) — the raw log could not be written, so what is above is all there is", "\(name)")
            // And the saving is real on every one of them: no answer is longer than the log it stands for.
            #expect(lines.count <= report.totalLines, "\(name)")
        }
    }

    /// No answer is longer than the log it stands for — and that is held by the code rather than by the corpus.
    ///
    /// The assertion above says it of every capture, and every capture happens to satisfy it; nothing made it true. A listed failure costs two to four answer lines against as few as one or two of log, so twenty Swift Testing tests recording three issues each print about 110 lines and would list as about 126 — a receipt reading `110 lines in, 126 out`, the wrapper announcing in its own arithmetic that it has expanded what it exists to compress. A fixed five-entry cap would bound that by accident, and ``RunFailureCensus/listingBudget`` does not, because sixty failures are only 6 KB.
    @Test
    func anAnswerIsNeverLongerThanTheLogItStandsFor() {
        let report = Self.crowdedTestRun
        let shape = RunFailureShape.of(
            report.testFailures.map { RunFailureShape.Failure(name: $0.name, location: $0.location, message: $0.message) },
            changedFiles: .unavailable("the working tree was not consulted")
        )
        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"))
            .render(report, exitCode: 1, logURL: nil)
        let lines = answer.split(separator: "\n", omittingEmptySubsequences: false)

        // Neither of the other two rules refuses this listing: it is 6 KB of sixty distinct signatures,
        // weighed by the block that would serve it — see ``TestSources/listingBytes(of:)-(RunFailureShape)``.
        #expect(TestSources.listingBytes(of: shape) < RunFailureCensus.listingBudget)
        #expect(!shape.census.isChieflyRepetition)
        // So the log's own size is what refuses it, and the receipt beneath states a saving rather than a cost.
        #expect(lines.count <= report.totalLines)
        #expect(answer.contains("(\(report.totalLines) lines in, \(lines.count) out)"))
        #expect(answer.contains("  +\(Self.crowdedFailures - RunFailureCensus.signatureCap) more signatures, covering \(Self.crowdedFailures - RunFailureCensus.signatureCap) failures — see the raw log"))
    }

    /// One answer, one ``RunFailureCensus/listingBudget`` — never one per section in a report carrying both.
    ///
    /// The constant has to be *spent* and not merely *read*: a section that measures its listing against the whole of it hands an answer with both sections twice what every sentence defining the number says it bounds. Ninety distinct compile errors and sixty distinct test failures over one 303-line log would list both — 90 error lines and 120 failure lines, over 12 KB against a documented 8,192 — while the line allowance beside it is threaded between the two sections. No capture in the corpus carries both at once, which is why the corpus cannot show it.
    ///
    /// **The two premises come first, because without them this would pass for one of the other two rules.** Each listing fits the budget on its own, and the pair does not: so what the answer does with them is the whole of what this test decides.
    @Test
    func theTwoSectionsOfOneAnswerSpendOneListingBudgetBetweenThem() {
        let report = Self.crowdedBuildAndTestRun
        let errors = RunErrorShape.of(report.errors, changedFiles: .of([]))
        let failures = RunFailureShape.of(
            report.testFailures.map { RunFailureShape.Failure(name: $0.name, location: $0.location, message: $0.message) },
            changedFiles: .of([])
        )
        let (byErrors, byFailures) = (TestSources.listingBytes(of: errors), TestSources.listingBytes(of: failures))

        #expect(byErrors < RunFailureCensus.listingBudget)
        #expect(byFailures < RunFailureCensus.listingBudget)
        #expect(byErrors + byFailures > RunFailureCensus.listingBudget)

        let answer = RunReportRenderer(
            kind: .swiftTest,
            workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"),
            changedFiles: .of([])
        ).render(report, exitCode: 1, logURL: nil)
        let lines = answer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // The errors are listed, and listing them is most of what the answer had to spend.
        #expect(lines.contains("\(Self.crowdedErrors) errors · \(Self.crowdedErrors) signatures · \(Self.crowdedErrors) files · 0 in changed files (matched by name)"))
        #expect(lines.filter { $0.contains(": error: ") }.count == Self.crowdedErrors)
        // What is left will not pay for a second listing, so the failures are served as the shape they have.
        #expect(lines.contains("\(Self.crowdedFailures) failures · \(Self.crowdedFailures) signatures · 1 file · 0 in changed files (matched by name)"))
        #expect(lines.contains("  +\(Self.crowdedFailures - RunFailureCensus.signatureCap) more signatures, covering \(Self.crowdedFailures - RunFailureCensus.signatureCap) failures — see the raw log"))
        // And the log is not what refused it — 303 lines in, and a long way short of that out.
        #expect(lines.count < report.totalLines)
    }

    /// The allowance the two listing sections share is a count of lines, so it is never a negative number — not even where the section above it spent more than the log had.
    ///
    /// ``RunErrorShape``'s sample prints an `Undefined symbols` block's symbol list whole, bounded by neither ``RunFailureCensus/listingBudget`` nor this allowance, because a header naming symbols the answer does not carry is worse than a long answer. So a linker dumping several hundred undefined symbols renders a block longer than the log it stands for, and subtracting it would leave a negative count standing where a number of lines belongs. Zero and a negative both refuse a listing, so what this pins is the arithmetic rather than a different answer: the exemption stays, documented where it is taken, and the receipt states the overrun out loud.
    @Test
    func theAllowanceTheTwoListingSectionsShareIsNeverNegative() {
        let renderer = RunReportRenderer(kind: .swiftBuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"))
        let short = Self.report(totalLines: 3)

        // A log shorter than the answer's own frame, and one an exempt errors block has overrun.
        #expect(renderer.allowance(of: short, beside: 2) == 0)
        #expect(renderer.allowance(of: short, beside: 400) == 0)
        // A floor and not a rewrite: an ordinary log still hands over everything it has left.
        #expect(renderer.allowance(of: Self.report(totalLines: 200), beside: 10) == 189)
    }

    @Test
    func aStreamSplitAtArbitraryByteBoundariesReadsTheSame() throws {
        let raw = try Data(TestSources.runOutput("xcodebuild-test-failure").utf8)
        var chunked = RunOutputFilter(expecting: .unreadable)
        var offset = raw.startIndex
        while offset < raw.endIndex {
            let end = raw.index(offset, offsetBy: 7, limitedBy: raw.endIndex) ?? raw.endIndex
            chunked.consume(raw[offset ..< end])
            offset = end
        }
        let byChunks = chunked.finish()
        let whole = try TestSources.runReport("xcodebuild-test-failure")

        #expect(byChunks.totalLines == whole.totalLines)
        #expect(byChunks.errors.count == whole.errors.count)
        #expect(byChunks.warnings.count == whole.warnings.count)
        #expect(byChunks.testFailures.map(\.name) == whole.testFailures.map(\.name))
        #expect(byChunks.summaryLines == whole.summaryLines)
    }

    @Test
    func warningsPastTheCapAreCountedRatherThanListed() {
        var filter = RunOutputFilter(expecting: .unreadable)
        for index in 0 ..< 25 {
            filter.consume(line: "/Users/dev/Widget/Sources/Widget/File\(index).swift:1:1: warning: unused value \(index)")
        }
        let report = filter.finish()

        #expect(report.warnings.count == 25)
        let answer = RunReportRenderer(kind: .swiftBuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"))
            .render(report, exitCode: 0, logURL: URL(fileURLWithPath: "/Users/dev/Widget/.sift/runs/run-20260818-101503-4f2a91c7.log"))
        #expect(answer.contains("warnings (25):"))
        #expect(answer.contains("+5 more warnings — see the raw log"))
        #expect(answer.contains("Sources/Widget/File19.swift:1:1: warning: unused value 19"))
        #expect(!answer.contains("unused value 20"))
        // The five it withheld cost the answer nothing, and its receipt counts only what it printed:
        // 25 lines in, and the twenty it listed plus a headline, a heading, the withheld count, a
        // blank line, the summary note and the receipt itself.
        #expect(answer.contains("(25 lines in, 26 out)"))
    }

    @Test
    func outputTheFilterCannotReadIsNeverPresentedAsSuccess() {
        var filter = RunOutputFilter(expecting: .unreadable)
        filter.consume(Data("\u{FFFE}garbage\u{0}\u{1}\nmore noise\nno diagnostics here\n".utf8))
        let report = filter.finish()

        #expect(report.errors.isEmpty)
        #expect(report.summaryLines.isEmpty)
        // A failed command the filter cannot explain must not be answered at all; the caller serves raw.
        #expect(!report.isUsable(exitCode: 65))
        #expect(report.isUsable(exitCode: 0))
    }

    /// A summary line is a verdict, not an explanation, and does not lift a failed run out of the fallback.
    ///
    /// `** BUILD FAILED **` / `** TEST FAILED **` is captured on *every* failing xcodebuild, so counting a summary as an explanation would make Docs/Design.md §3 rule 4's raw-log fallback unreachable for the one tool whose logs are longest. Here the two lines that actually said why are shapes the filter drops, which is the whole point: what is left is a restatement of the exit code the caller already has.
    @Test
    func anXcodebuildVerdictOnItsOwnExplainsNothing() {
        var filter = RunOutputFilter(expecting: .unreadable)
        filter.consume(line: "Testing failed:")
        filter.consume(line: "\tTest runner exited before starting test execution.")
        filter.consume(line: "** TEST FAILED **")
        let report = filter.finish()

        #expect(report.summaryLines == ["** TEST FAILED **"])
        #expect(report.errors.isEmpty)
        #expect(report.testFailures.isEmpty)
        #expect(!report.isUsable(exitCode: 65))
        // A passing run has nothing to explain, so the same report is perfectly serveable at exit 0.
        #expect(report.isUsable(exitCode: 0))
    }

    /// `Build complete!` standing over a nonzero exit is the same mistake in a friendlier voice, and it is caught in the headline rather than only in the fallback.
    ///
    /// Both halves matter. The fallback keeps a *cause-less* failure from being answered at all — but the moment the run prints one line the filter can read, the fallback stops firing and the answer goes out with whatever the headline says about it. Taking the log's own `Build complete!` as the run's verdict, it would say `✔ swift build — exit 1`, over the diagnostic listed three lines below it. So the second half of this test gives the run a diagnostic — the difference between the two cases is one parseable line — and asserts what the reader is handed.
    @Test
    func aSuccessfulBuildSummaryDoesNotExcuseAFailedRun() throws {
        var filter = RunOutputFilter(expecting: .unreadable)
        filter.consume(line: "Build complete! (7.00s)")
        filter.consume(line: "Fatal error: the test harness crashed")
        let report = filter.finish()

        #expect(report.summaryLines == ["Build complete! (7.00s)"])
        #expect(!report.isUsable(exitCode: 1))

        var explained = try RunOutputFilter(expecting: #require(RunVerdict.Contract.of(["swift", "build"])))
        explained.consume(line: "Build complete! (7.00s)")
        explained.consume(line: "/Users/dev/Widget/Sources/Widget/Harness.swift:12:5: error: the test harness crashed")
        let served = explained.finish()

        #expect(served.isUsable(exitCode: 1))
        #expect(served.verdict?.state == .succeeded)
        let answer = RunReportRenderer(kind: .swiftBuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"))
            .render(served, exitCode: 1, logURL: nil)
        #expect(answer.hasPrefix("⚠ swift build — the log declares success but the command exited 1; see the raw output"))
        #expect(!answer.contains("✔"))
        #expect(answer.contains("Sources/Widget/Harness.swift:12:5: error: the test harness crashed"))
    }

    /// xcodebuild reports a project-level failure — signing, provisioning, `Multiple commands produce` — against a path with no line number, and dropping those leaves such a run with no cause in the answer at all.
    ///
    /// Synthetic lines rather than a capture: reproducing a signing failure needs a real team and a real project, and what is under test is the parser's reading of one line. The captures in `Fixtures/RunOutput/` stay real.
    @Test
    func aDiagnosticLocatedOnlyByPathIsKept() throws {
        let signing = try #require(RunDiagnostic.parse(
            #"/Users/dev/Gizmo/Gizmo.xcodeproj: error: Signing for "Gizmo" requires a development team."#
        ))
        #expect(signing.severity == .error)
        #expect(signing.path == "/Users/dev/Gizmo/Gizmo.xcodeproj")
        #expect(signing.line == nil)
        #expect(signing.message == #"Signing for "Gizmo" requires a development team."#)

        let warning = try #require(RunDiagnostic.parse("Package.swift: warning: 'macOS 13' is deprecated"))
        #expect(warning.severity == .warning)
        #expect(warning.path == "Package.swift")

        // `xcrun` names itself where a path would stand, and has neither a slash nor a dot to be read as
        // one — so a toolchain that cannot find the utility it was asked for says so, and dropping that
        // leaves the same "failure with no cause" this rule exists to prevent.
        let missing = try #require(RunDiagnostic.parse(#"xcrun: error: unable to find utility "xctest", not a developer tool or in PATH"#))
        #expect(missing.severity == .error)
        #expect(missing.path == nil)
        #expect(missing.message == #"unable to find utility "xctest", not a developer tool or in PATH"#)
    }

    /// The false positive that rule has to clear: a timestamped tool log naming a severity is not a diagnostic.
    ///
    /// The two are discriminable without guessing — a log prefix carries whitespace and a `[pid:tid]` bracket, and a path carries neither.
    @Test
    func aTimestampedToolLogIsStillNotADiagnostic() {
        #expect(RunDiagnostic.parse("2026-08-18 10:00:00.000 xcodebuild[123:456]: warning: unrecognised option") == nil)
        #expect(RunDiagnostic.parse("xcodebuild[123:456]: error: could not attach") == nil)
        #expect(RunDiagnostic.parse("note[7]: warning: nothing here names a file") == nil)
        // And the tool names that were always allowed to stand where a path would still are.
        #expect(RunDiagnostic.parse("ld: warning: ignoring duplicate libraries")?.path == nil)
    }

    /// The build system saying one of its own subcommands exited nonzero is not a diagnostic, and the tool that names itself saying the same thing still is.
    ///
    /// Both directions, because the two lines are the same sentence and only the prefix tells them apart. `error: emit-module command failed with exit code 1` names no file and says nothing the errors the subcommand printed have not — on a build with eight distinct errors, counting it makes a ninth that takes one of the five slots the shape has to illustrate them with. `clang: error: linker command failed with exit code 1` is the real report of a link failure, and dropping it on the message alone would take the only line that says the link is what went wrong.
    @Test
    func aSubcommandsExitStatusIsNotADiagnosticButAToolNamingItselfStillIs() throws {
        #expect(RunDiagnostic.parse("error: emit-module command failed with exit code 1 (use -v to see invocation)") == nil)
        #expect(RunDiagnostic.parse("error: link command failed with exit code 1 (use -v to see invocation)") == nil)
        #expect(RunDiagnostic.parse("error: compile command failed with exit code 2") == nil)

        let linker = try #require(RunDiagnostic.parse("clang: error: linker command failed with exit code 1 (use -v to see invocation)"))
        #expect(linker.severity == .error)
        #expect(linker.path == nil)
        #expect(linker.message == "linker command failed with exit code 1 (use -v to see invocation)")

        // Narrow on purpose: `namesAFailedSubcommand` drops exactly five shapes — the bare-word subcommand-exit
        // shape tested above, the two bare sentences (`Build failed`, `fatalError`, tested below), and two
        // multi-word shapes tested elsewhere (`-quiet`'s own "the following command failed … no further output",
        // and Swift 6.4's "… failed with a nonzero exit code. Command line:"). Nothing outside those five.
        #expect(RunDiagnostic.parse("error: fatalError") == nil)
        // The exact match a `hasPrefix` regression would miss: this still names a real cause and must survive.
        #expect(RunDiagnostic.parse("error: fatalError: something") != nil)
        #expect(RunDiagnostic.parse("error: the build command failed with exit code 1") != nil)
        #expect(RunDiagnostic.parse("error: emit-module command failed with exit code unknown") != nil)
        #expect(try #require(RunDiagnostic.parse("Sources/Widget/A.swift:1:1: error: link command failed with exit code 1")).path == "Sources/Widget/A.swift")
    }

    /// `error: fatalError` alone is a failed run the filter cannot explain, exactly like a bare `error: Build failed` — the fallback that protects one protects the other.
    @Test
    func aBareFatalErrorAloneLeavesTheRunUnexplained() {
        var filter = RunOutputFilter(expecting: .unreadable)
        filter.consume(line: "error: fatalError")
        let report = filter.finish()

        #expect(report.errors.isEmpty)
        #expect(report.summaryLines.isEmpty)
        #expect(!report.isUsable(exitCode: 1))
    }

    /// And beside a real, located error it disappears without taking a slot from the answer.
    @Test
    func aBareFatalErrorBesideARealErrorDisappearsWithoutIt() throws {
        var filter = RunOutputFilter(expecting: .unreadable)
        filter.consume(line: "Sources/Widget/Broken.swift:4:9: error: cannot find 'missingSymbol' in scope")
        filter.consume(line: "error: fatalError")
        let report = filter.finish()

        #expect(report.errors.count == 1)
        #expect(try #require(report.errors.first).message == "cannot find 'missingSymbol' in scope")
    }

    /// SwiftPM's build system states a compiler error's location after the severity, with a space rather than a colon before the message — `error: /…/T.swift:3:8 unable to resolve module dependency: 'Sidecar'`, captured from `swift test` under Swift 6.4 — and the file it names is still where the error is, so the answer can tell an error in a test file from one anywhere else.
    @Test
    func aLocationStatedAfterTheSeverityIsRead() throws {
        let error = try #require(RunDiagnostic.parse("error: /Users/dev/Widget/Tests/WidgetTests/WidgetTests.swift:3:8 unable to resolve module dependency: 'Sidecar'"))

        #expect(error.severity == .error)
        #expect(error.path == "/Users/dev/Widget/Tests/WidgetTests/WidgetTests.swift")
        #expect(error.line == 3)
        #expect(error.column == 8)
        #expect(error.message == "unable to resolve module dependency: 'Sidecar'")
        // Only an absolute path, a line and a column: anything else after the marker is still an unlocated message.
        #expect(try #require(RunDiagnostic.parse("error: 3:8 is not where anything is")).path == nil)
        #expect(try #require(RunDiagnostic.parse("error: /Users/dev/Widget: no such directory")).path == nil)
    }

    /// And the capture it was measured on: the driver's own exit status and its closing `fatalError` are both gone from the report, while the error the subcommand printed stays.
    @Test
    func theDriversExitStatusIsNotCountedAmongACapturesErrors() throws {
        let report = try TestSources.runReport("swift-test-linkerror")

        #expect(!report.errors.contains { $0.message.hasPrefix("link command failed") })
        #expect(!report.errors.contains { $0.message == "fatalError" })
        #expect(report.errors.count == 1)
        #expect(report.errors.contains { $0.message.hasPrefix("Undefined symbols") })
    }

    /// Swift 6.4 closes the same link failure on `error: Build failed` immediately followed by `error: fatalError` — both dropped, neither taking a slot from the real errors, exactly as when `fatalError` closes a build alone.
    ///
    /// One error survives, as with `swift-test-linkerror.txt`, although SwiftPM 6.4 prefixes the `clang: error: linker command failed …` line with the package manifest path and product name (`/Users/dev/Widget/Package.swift: WidgetTests-product: clang: error: …`): the linker block reads that prefixed form as its closing line too, so it folds into the `Undefined symbols` block's detail instead of surviving as a diagnostic of its own.
    @Test
    func swift64ClosesALinkErrorOnBuildFailedThenFatalErrorAndBothAreDropped() throws {
        let report = try TestSources.runReport("swift-test-linkerror-6.4")

        #expect(!report.errors.contains { $0.message == "Build failed" })
        #expect(!report.errors.contains { $0.message == "fatalError" })
        #expect(!report.errors.contains { $0.message.hasPrefix("Ld ") })
        #expect(report.errors.contains { $0.message.hasPrefix("Undefined symbols") })
        #expect(report.errors.count == 1)
    }

    /// The manifest line above folds whether or not SwiftPM names it with a directory: run from the package's own root, the same closing line has no `/` before `Package.swift` at all (`Package.swift: WidgetTests-product: clang: error: …`), and must fold into the block the same way rather than surviving as a diagnostic of its own.
    @Test
    func aRelativelyNamedManifestClosesTheLinkerBlockTheSameWay() throws {
        var filter = RunOutputFilter(expecting: .unreadable)
        filter.consume(line: "Undefined symbols for architecture arm64:")
        filter.consume(line: "  \"__widget_missing_helper\", referenced from:")
        filter.consume(line: "ld: symbol(s) not found for architecture arm64")
        filter.consume(line: "Package.swift: WidgetTests-product: clang: error: linker command failed with exit code 1 (use -v to see invocation)")
        filter.consume(line: "[72 / 76] WidgetTests-product")
        let report = filter.finish()

        #expect(report.errors.count == 1)
        let error = try #require(report.errors.first)
        #expect(error.message.hasPrefix("Undefined symbols"))
        #expect(error.detail.contains { $0.contains("Package.swift: WidgetTests-product: clang: error:") })
    }

    @Test
    func aFailureTheFrameworkNeverExplainedIsStillReported() throws {
        var filter = RunOutputFilter(expecting: .unreadable)
        filter.consume(line: "Test Case '-[SuiteName testCrashes]' started.")
        filter.consume(line: "Test Case '-[SuiteName testCrashes]' failed (12.004 seconds).")
        let report = filter.finish()

        #expect(report.testFailures.count == 1)
        let failure = try #require(report.testFailures.first)
        #expect(failure.name == "-[SuiteName testCrashes]")
        #expect(failure.message.contains("see the raw log"))
    }

    @Test
    func aTestThatExplainedItselfIsNotCountedTwice() throws {
        let report = try TestSources.runReport("xcodebuild-test-failure")

        // The assertion line and the `Test Case … failed` line describe one failure between them.
        #expect(report.testFailures.count == 1)
    }

    @Test
    func theReceiptNamesTheRawLogAndTheLinesItStandsFor() throws {
        let report = try TestSources.runReport("xcodebuild-test-failure", invokedAs: Self.gizmoTest)
        let answer = RunReportRenderer(kind: .xcodebuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Gizmo"))
            .render(report, exitCode: 65, logURL: URL(fileURLWithPath: "/Users/dev/Gizmo/.sift/runs/run-20260818-101744-9b30e5af.log"))

        #expect(answer.contains("(\(report.totalLines) lines in, \(answer.split(separator: "\n", omittingEmptySubsequences: false).count) out)"))
        #expect(answer.contains("raw: .sift/runs/run-20260818-101744-9b30e5af.log ("))
        #expect(answer.hasPrefix("✘ xcodebuild — exit 65"))
        // Paths inside the working directory are printed the way a follow-up Read would take them.
        #expect(answer.contains("Tests/GizmoTests/GizmoTests.swift:6"))
        #expect(!answer.contains("/Users/dev/Gizmo/Tests"))
    }
}

/// The captured corpus the verdict reader was built against: the whole `xcodebuild` runs from one purpose-built package, and the throwaway packages built to reproduce one printing fault each.
///
/// A second declaration of the same suite rather than a second suite, because the subject is the same — what the filter keeps and what it drops — and naming a new type would put a name on a boundary that is only a length. The boundary is real all the same: above it every fixture is a short capture read for one line, and below it every one is a whole run read for what the run *means*.
extension RunOutputFilterTests {
    /// A linker block arriving while a failure's note is still open takes over without a summary or a next test's line ever closing it, so the note must be closed here — not just on those two paths — or the failure loses both its closest line and its elided-line count for good: nothing later ever asks for either.
    @Test
    func aLinkerBlockClosesTheNoteItInterrupts() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(line: "✘ Test aLongExplanation() recorded an issue at LongTests.swift:9:9: Expectation failed: reason.contains(\"delta line\")")
        filter.consume(line: "↳   reason → \"alpha line one")
        filter.consume(line: "  the second line of the explanation")
        filter.consume(line: "  the third line of the explanation")
        for filler in 1 ... 11 {
            filter.consume(line: "  filler line \(filler)")
        }
        filter.consume(line: "  delta line two\"")
        filter.consume(line: "Undefined symbols for architecture arm64:")
        filter.consume(line: "  \"__widget_missing_helper\", referenced from:")
        let report = filter.finish()
        let failure = try #require(report.testFailures.first)

        #expect(failure.closestLine == "closest line: delta line two")
        #expect(failure.note?.hasSuffix("\n… (+3 more lines — see the raw log)") == true)
    }

    /// A parameterized Swift Testing failure prints its arguments, and without them the answer says the same thing over and over.
    ///
    /// The line is `Test theConveyorBelt…(title:) recorded an issue with 1 argument title → "Drum" at …`, and a reader looking for ` recorded an issue at ` matches none of them, so every argument-carrying issue in this capture falls through to the path that reports a test as having failed with no message of its own, two words away from the message.
    @Test
    func aParameterizedFailureKeepsTheArgumentsItFailedUnder() throws {
        let report = try TestSources.runReport("xcodebuild-test-execute-failure-environmental")

        let failure = try #require(report.testFailures.first { $0.arguments == #"title → "Drum""# })
        #expect(failure.name == "theConveyorBeltCarriesItsOwnTitleAboveItsFirstRow(title:)")
        #expect(failure.location == "ConveyorBeltTests.swift:11:9")
        #expect(failure.message.hasPrefix(#"Expectation failed: (labels → "").contains(title →"#))
        #expect(report.testFailures.filter { $0.arguments != nil }.count == 247)

        // Rendered through the classification block, which lists one example per signature rather than
        // every failure — so the exact line is asserted on this failure's own block, and the full answer
        // is asserted to carry argument-bearing examples at all, which is what proves the wiring.
        let block = RunFailureShape.of(
            [RunFailureShape.Failure(name: failure.name, location: failure.location, message: failure.message, arguments: failure.arguments, note: failure.note)],
            changedFiles: .of([])
        ).rendered()
        #expect(block.contains(#"  theConveyorBeltCarriesItsOwnTitleAboveItsFirstRow(title:) with title → "Drum" — ConveyorBeltTests.swift:11:9"#))

        let answer = RunReportRenderer(kind: .xcodebuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Depot"))
            .render(report, exitCode: 65, logURL: nil)
        // Past testsCap, a signature names its top three tests by their own count rather than an
        // arbitrary one of the tests sharing it — everyBinLabelSignAeIsReadableAtEveryWidth (×12) sits
        // under "+6 more tests" now, while testOne (×20) leads its signature and is the one this answer
        // actually names.
        #expect(answer.contains(#"testOne(expected:) with expected → "Weight""#))
    }

    /// Every issue the log recorded is reported with the message the log printed for it, and none is reported as unexplained.
    ///
    /// This is the whole defect in one assertion. The capture states its own total — `667 issues (including 1 known issue)` — and a known issue is not a failure, so 666 lines of message are sitting in the file, and not one argument-carrying line among them may be answered as "failed with no message of its own".
    @Test
    func everyIssueInTheLogIsAnsweredWithItsOwnMessage() throws {
        let raw = try TestSources.runOutput("xcodebuild-test-execute-failure-environmental")
        let report = try TestSources.runReport("xcodebuild-test-execute-failure-environmental")

        #expect(raw.components(separatedBy: " recorded an issue ").count - 1 == 666)
        #expect(report.testFailures.count == 666)
        #expect(report.testFailures.allSatisfy { !$0.message.contains("no message of its own") })
    }

    /// A parameterized case whose argument holds a newline is still listed, and the answer's count agrees with the run's own tally.
    ///
    /// Swift Testing prints the argument's value as it is, so the `recorded an issue with 1 argument leaf → "a` line breaks inside the value and its location arrives on the next line. Read one line at a time, that failure was dropped: two listed under a tally of three.
    @Test
    func aParameterizedCaseWhoseArgumentHoldsANewlineIsStillListed() throws {
        let report = try TestSources.runReport("swift-test-newline-argument", invokedAs: ["swift", "test"])
        let tally = try #require(report.tally)

        #expect(tally.failures == 3)
        #expect(report.testFailures.count == tally.failures)
        let broken = try #require(report.testFailures.first { $0.arguments == #"leaf → "a\nb""# })
        #expect(broken.name == "steeps(leaf:)")
        #expect(broken.location == "KettleTests.swift:6:5")
        #expect(broken.message == "Expectation failed: leaf.isEmpty")
        #expect(report.testFailures.contains { $0.arguments == #"leaf → "c""# })
        #expect(report.testFailures.contains { $0.name == "boils()" })

        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Kettle"))
            .render(report, exitCode: 1, logURL: nil)
        #expect(answer.contains("3 failures ·"))
        #expect(answer.contains("totals: ✘ failed · Swift Testing 2 tests in 0 suites, 3 failures"))
    }

    /// An argument that runs on for longer than a handful of lines — a fixture string — still reaches the location after it.
    ///
    /// The hold used to give up after 16 lines, listing a 20-line argument as having run on "with no location after them" and losing the failure's location and message.
    @Test
    func aLongMultiLineArgumentStillReachesItsLocation() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        let value = (1 ... 20).map { "line \($0)" }
        filter.consume(line: "✘ Test steeps(leaf:) recorded an issue with 1 argument leaf → \"" + value[0])
        for line in value.dropFirst().dropLast() {
            filter.consume(line: line)
        }
        filter.consume(line: value[19] + "\" at KettleTests.swift:3:54: Expectation failed: leaf.isEmpty")
        let report = filter.finish(exitCode: 1)

        let failure = try #require(report.testFailures.first)

        #expect(report.testFailures.count == 1)
        #expect(failure.location == "KettleTests.swift:3:54")
        #expect(failure.message == "Expectation failed: leaf.isEmpty")
        #expect(failure.arguments == "leaf → \"" + value.joined(separator: #"\n"#) + "\"")
    }

    /// A line of the value that happens to begin with `Test` is the value's: Swift Testing's own events open on a glyph, XCTest's on `Test Case '` or `Test Suite '`.
    @Test
    func aValueLineBeginningWithTestIsNotReadAsAnEvent() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            #"✘ Test steeps(leaf:) recorded an issue with 1 argument leaf → "x"#,
            #"Test y" at KettleTests.swift:6:5: Expectation failed: leaf.isEmpty"#,
        ] {
            filter.consume(line: line)
        }
        let failure = try #require(filter.finish(exitCode: 1).testFailures.first)

        #expect(failure.location == "KettleTests.swift:6:5")
        #expect(failure.arguments == #"leaf → "x\n"# + #"Test y""#)
    }

    /// A real event still ends the hold, whichever framework printed it, and the failure is listed without a location rather than dropped.
    @Test(arguments: ["✘ Test boils() failed after 0.001 seconds with 1 issue.", "Test Case '-[KettleTests.Legacy testOne]' started.", "Test Suite 'Legacy' passed at 2000-01-01 12:00:00.797."])
    func anEventEndsTheHoldOnAnArgumentWithNoLocation(event: String) throws {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [#"✘ Test steeps(leaf:) recorded an issue with 1 argument leaf → "a"#, "b", event] {
            filter.consume(line: line)
        }
        let failure = try #require(filter.finish(exitCode: 1).testFailures.first { $0.name == "steeps(leaf:)" })

        #expect(failure.location == nil)
        #expect(failure.message == "its arguments ran on across 2 lines with no location after them — see the raw log")
    }

    /// A parameterized case whose argument quotes a failure line is a case starting, not a failure: this suite's own run printed exactly these.
    @Test
    func aCaseWhoseArgumentQuotesAFailureIsNotOne() {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "◇ Test case passing 1 argument event → \"✘ Test boils() failed after 0.001 seconds with 1 issue.\" to pours(event:) started.",
            "◇ Test case passing 1 argument event → \"✘ Test boils() recorded an issue at KettleTests.swift:6:5: Expectation failed\" to pours(event:) started.",
            "✔ Test pours(event:) with 2 test cases passed after 0.001 seconds.",
            "✔ Test run with 1 test in 0 suites passed after 0.001 seconds.",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 0)

        #expect(report.testFailures.isEmpty)
        #expect(report.verdict?.state == .succeeded)
    }

    /// A `swift test` owes no `** … **` banner, so one a test process prints is not the run's: this repository's own suite prints `** TEST SUCCEEDED **` from the fake tools it runs.
    @Test
    func aBannerATestPrintsIsNotASwiftTestRunsOwn() {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "Build complete! (0.16 secs)",
            "** TEST SUCCEEDED **",
            "✔ Test run with 1 test in 0 suites passed after 0.001 seconds.",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 0)

        #expect(report.summaryLines == ["Build complete! (0.16 secs)", "Test run with 1 test in 0 suites passed after 0.001 seconds."])
        #expect(report.verdict?.state == .succeeded)
    }

    /// The `↳` comment beneath a failure is the sentence its author wrote, and it is kept as the failure's note.
    ///
    /// It attaches by adjacency and by nothing else, because the same marker heads lines that belong to no failure at all — the run's own `↳ Testing Library Version: 1902` preamble, and the two that follow a *known* issue, which is not a failure and has nothing here to be attached to.
    @Test
    func theCommentBeneathAFailureIsKeptAsItsNote() throws {
        let report = try TestSources.runReport("xcodebuild-test-execute-failure-environmental")

        let failure = try #require(report.testFailures.first { $0.arguments == #"title → "Drum""# })
        #expect(failure.note == "the conveyorbelt lost its title between the rack and the reader")
        #expect(report.testFailures.filter { $0.note != nil }.count == 641)
        #expect(report.testFailures.allSatisfy { $0.note?.hasPrefix("Testing Library Version") != true })

        let block = RunFailureShape.of(
            [RunFailureShape.Failure(name: failure.name, location: failure.location, message: failure.message, arguments: failure.arguments, note: failure.note)],
            changedFiles: .of([])
        ).rendered()
        // And it says what its attribution is worth, on the line it qualifies rather than in a legend.
        #expect(block.contains("    ↳ the conveyorbelt lost its title between the rack and the reader (by adjacency)"))

        // And a note reaches the whole answer, which lists one example per signature rather than every failure.
        let answer = RunReportRenderer(kind: .xcodebuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Depot"))
            .render(report, exitCode: 65, logURL: nil)
        // Same reason as above: theConveyorBeltCarriesItsOwnTitleAboveItsFirstRow leads its own signature
        // (×12, the top of a three-test group with no overflow), so its own note is the one still in the
        // answer once everyBinLabelSignAeIsReadableAtEveryWidth's is folded into "+more".
        #expect(answer.contains("\n    ↳ the conveyorbelt lost its title between the rack and the reader (by adjacency)\n"))
    }

    /// A note that runs to more than one `↳` line is kept whole, because the second line is as much the author's sentence as the first.
    ///
    /// A claim on a failure that expires on the line that consumed it keeps a two-line note's first line and drops its second — and this capture is the case where that is exactly backwards: the first line is the source comment above the expectation and the second is the sentence saying what actually went wrong. Unlike a clipped message, a dropped continuation leaves no trace of itself in the answer.
    @Test
    func aNoteSpanningTwoLinesIsKeptWhole() throws {
        let raw = try TestSources.runOutput("xcodebuild-test-execute-failure-environmental")
        let report = try TestSources.runReport("xcodebuild-test-execute-failure-environmental")

        // The capture prints the lines one after the other, under one failure.
        #expect(raw.contains("↳ // Two elements: the bay sign a crate can only be stacked under"))
        #expect(raw.contains("↳ the crate is not one element under its bay sign: []"))

        let failure = try #require(report.testFailures.first { $0.location == "BinLabelTests.swift:72:9" })
        let note = try #require(failure.note)
        #expect(note.hasPrefix("// Two elements: the bay sign a crate can only be stacked under"))
        #expect(note.hasSuffix("the crate is not one element under its bay sign: []"))
    }

    /// A `↳` comment can itself end on a colon and open a list the next, unmarked, indented line answers — and that line is the one carrying the actual culprit, not the comment introducing it.
    @Test
    func anIndentedLineAfterAMarkedNoteIsKeptAsPartOfIt() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(line: "✘ Test aTestThatFailed() recorded an issue at GizmoTests.swift:9:9: Expectation failed: wrong.isEmpty")
        filter.consume(line: "↳ 1 citation(s) name a line their rule is not on: (by adjacency)")
        filter.consume(line: "  GizmoKit/Sources/Catalogue/UI/Views/Depot/Depot.swift:22 cites `:299 .grp` — depot.css:299 declares .grp .tx span; .grp is at depot.css:180 and depot.css:295")
        filter.consume(line: "✘ Test aTestThatFailed() failed after 0.002 seconds with 1 issue.")
        let report = filter.finish()

        let failure = try #require(report.testFailures.first)

        #expect(failure.note == "1 citation(s) name a line their rule is not on: (by adjacency)\nGizmoKit/Sources/Catalogue/UI/Views/Depot/Depot.swift:22 cites `:299 .grp` — depot.css:299 declares .grp .tx span; .grp is at depot.css:180 and depot.css:295")
    }

    /// Past ``RunOutputFilter/noteContinuationCap``, the rest are counted rather than kept — the same shape ``RunFailureCensus/clipped(_:)`` ends a bounded message on.
    @Test
    func continuationLinesPastTheCapAreCountedRatherThanKept() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(line: "✘ Test aLongExplanation() recorded an issue at LongTests.swift:9:9: Expectation failed: wrong.isEmpty")
        filter.consume(line: "↳ the first line of the explanation")
        for line in 2 ... 16 {
            filter.consume(line: "  explanation line \(line)")
        }
        filter.consume(line: "✘ Test aLongExplanation() failed after 0.002 seconds with 1 issue.")
        let report = filter.finish()

        let failure = try #require(report.testFailures.first)

        let expected = (["the first line of the explanation"] + (2 ... 12).map { "explanation line \($0)" } + ["… (+4 more lines — see the raw log)"]).joined(separator: "\n")

        #expect(failure.note == expected)
    }

    /// The same cap applies when the log ends mid-continuation, with no line afterwards to close the chain.
    @Test
    func continuationLinesPastTheCapAreCountedEvenWhenTheLogEndsThere() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(line: "✘ Test aLongExplanation() recorded an issue at LongTests.swift:9:9: Expectation failed: wrong.isEmpty")
        filter.consume(line: "↳ the first line of the explanation")
        for line in 2 ... 14 {
            filter.consume(line: "  explanation line \(line)")
        }
        let report = filter.finish()

        let failure = try #require(report.testFailures.first)

        let expected = (["the first line of the explanation"] + (2 ... 12).map { "explanation line \($0)" } + ["… (+2 more lines — see the raw log)"]).joined(separator: "\n")

        #expect(failure.note == expected)
    }

    /// An indented line the run's own `Executed …` or `Test run with …` counters recognise is read as theirs even while a failure's note is still open, never folded into the note as if it were unmarked prose.
    @Test
    func anIndentedSummaryLineIsNeverMistakenForAContinuation() throws {
        var filter = RunOutputFilter(invokedAs: ["xcodebuild", "test"])
        filter.consume(line: "✘ Test aFailingTest() recorded an issue at Widget.swift:9:9: Expectation failed: wrong.isEmpty")
        filter.consume(line: "↳ the one line this note should carry")
        filter.consume(line: "\t Executed 1 test, with 1 failure (0 unexpected) in 0.312 (0.312) seconds")
        let report = filter.finish(exitCode: 1)

        let failure = try #require(report.testFailures.first)

        #expect(failure.note == "the one line this note should carry")
        #expect(report.summaryLines.contains("Executed 1 test, with 1 failure (0 unexpected) in 0.312 (0.312) seconds"))
    }

    /// `Test aName(size:) with 3 test cases failed after …` names a function and then counts its cases; the count is not part of the name.
    ///
    /// Taking everything in front of the marker gives the same function two names — one from its issue lines and one from its outcome line — so it is reported twice, once explained and once not.
    @Test
    func aParameterizedTestIsNotNamedAfterItsCaseCount() throws {
        let raw = try TestSources.runOutput("xcodebuild-test-execute-failure-environmental")
        let report = try TestSources.runReport("xcodebuild-test-execute-failure-environmental")

        #expect(raw.contains("with 3 test cases failed after"))
        #expect(report.testFailures.allSatisfy { !$0.name.contains(" test case") })
    }

    /// A test's own name is the framework's word `Test` and everything after it; a display name carrying that word is not a second one.
    ///
    /// Reading the head backwards for ` Test ` finds the *author's* word rather than Swift Testing's the moment a display name contains one, and the suite line is where that stops being cosmetic: `Suite "Reflow Test Grid" failed after …` is read as a failing test called `Grid"`, which nothing else in the run mentions, and `appendUnexplainedFailures` then manufactures a failure for it — a third failure over a run whose own tally says two. It does not stop at the answer: `RunOutcome.reportedTestFailures` files those names into `run.jsonl` and `flakes` reads them back, so the invented name becomes a test that does not exist with a recorded history of failing.
    ///
    /// The capture is real, from a package built for it — see `PROVENANCE.md`. Swift Testing quotes a display name and prints a type name bare, which is why no other capture triggers this: this one holds all four of the corpus's quoted suite lines, and no other fixture names a suite that way at all.
    @Test
    func aDisplayNameCarryingTheWordTestNeitherRenamesATestNorInventsOne() throws {
        let raw = try TestSources.runOutput("swift-test-display-name")
        let report = try TestSources.runReport("swift-test-display-name", invokedAs: ["swift", "test"])

        // Both shapes are in the capture, and both put ` Test ` where a backwards search will find it.
        #expect(raw.contains(#"Suite "Reflow Test Grid" failed after"#))
        #expect(raw.contains(#"Test "The Test Reads Its Own Name" recorded an issue"#))

        // The run said two issues, and the answer says two failures — not three.
        #expect(report.tally?.issues == 2)
        #expect(report.testFailures.count == 2)
        #expect(report.testFailures.map(\.name).sorted() == [#""The Test Reads Its Own Name""#, "theGridReflows()"])
        // The suite is not a test, whatever its display name contains, and nothing was invented for it.
        #expect(!report.testFailures.contains { $0.name.contains("Grid\"") })
        #expect(report.testFailures.allSatisfy { !$0.message.contains("no message of its own") })
    }

    /// A failure whose own message quotes Swift Testing's closing sentence is a failure, not a second run tally.
    ///
    /// A tally matched *anywhere* in the line, by a reader that runs before the one that reads failures, lets one `#expect` comparing against that sentence take three things down at once: a mangled fragment of the failure's message — closing quote and all — is filed as a tally, the count reaching two makes `soleTally()` `nil` so the run headlines `⚠ … no verdict in the log` over a log that plainly carries one, and the failure itself is left with no message.
    ///
    /// **It is self-referential, which is why the capture is a package built for it rather than a hand-written line.** `Fixtures/RunOutput/swift-test-quoted-tally.txt` is a real `swift test` whose suite quotes the sentence; the literal it quotes also sits in this very file, so a failure in *this* repository's own suite would misreport itself the same way.
    @Test
    func aFailureQuotingTheRunTallyIsNotReadAsOne() throws {
        let raw = try TestSources.runOutput("swift-test-quoted-tally")
        let report = try TestSources.runReport("swift-test-quoted-tally", invokedAs: ["swift", "test"])

        // The capture holds the sentence twice: as the run's own closing line, and inside a failure message.
        #expect(raw.contains(#"== "Test run with 2 tests in 1 suite passed after 0.001 seconds.""#))
        #expect(raw.contains("Test run with 2 tests in 1 suite failed after 0.001 seconds with 2 issues."))

        // One tally survives, and it is the one the run printed for itself.
        #expect(report.summaryLines.filter { $0.hasPrefix("Test run with ") }
            == ["Test run with 2 tests in 1 suite failed after 0.001 seconds with 2 issues."])
        #expect(report.tally?.failures == 2)
        #expect(report.verdict?.state == .failed)

        // And the quoting failure keeps the message the reader above it would otherwise take.
        let quoting = try #require(report.testFailures.first { $0.name == "quotesThePhraseInItsFailure()" })
        #expect(quoting.message == #"Expectation failed: (Quoted.phrase → "nope") == "Test run with 2 tests in 1 suite passed after 0.001 seconds.""#)
        #expect(report.testFailures.count == 2)
        #expect(report.testFailures.allSatisfy { !$0.message.contains("no message of its own") })

        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Quoted"))
            .render(report, exitCode: 1, logURL: nil)
        #expect(answer.hasPrefix("✘ swift test — exit 1\n"))
        #expect(!answer.contains("no verdict in the log"))
    }

    /// A tally at the start of a line inside a failure's note is the test's text, not a second run tally.
    ///
    /// A multi-line `#expect` comment prints as a `↳` line and then indented lines, so a test that prints a rendered answer on failure puts `Test run with 2 tests in 0 suites failed after 0.001 seconds with 3 issues.` at the start of an indented line of its own note. Read as a tally, it put a stray tally in the summary and summed its three issues into the run's one, so `totals:` said four failures. `Fixtures/RunOutput/swift-test-noted-tally.txt` is that run.
    @Test
    func aTallyInsideAFailuresNoteIsNotReadAsOne() throws {
        let raw = try TestSources.runOutput("swift-test-noted-tally")
        let report = try TestSources.runReport("swift-test-noted-tally", invokedAs: ["swift", "test"], exitCode: 1)

        // The capture holds a tally twice: indented inside the note, and as the run's own closing line.
        #expect(raw.contains("\n  Test run with 2 tests in 0 suites failed after 0.001 seconds with 3 issues.\n"))
        #expect(raw.contains("Test run with 2 tests in 0 suites failed after 0.001 seconds with 1 issue."))

        #expect(report.summaryLines.filter { $0.hasPrefix("Test run with ") }
            == ["Test run with 2 tests in 0 suites failed after 0.001 seconds with 1 issue."])
        #expect(report.tally?.failures == 1)
        #expect(report.verdict?.state == .failed)

        // The quoted line stays where it was printed: in the failure's note.
        let noted = try #require(report.testFailures.first { $0.name == "printsAnAnswerInItsNote()" })
        #expect(noted.note?.contains("Test run with 2 tests in 0 suites failed after 0.001 seconds with 3 issues.") == true)
        #expect(report.testFailures.count == 1)

        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Noted"))
            .render(report, exitCode: 1, logURL: nil)
        let totals = answer.split(separator: "\n").filter { $0.hasPrefix("totals:") }
        #expect(totals == ["totals: ✘ failed · Swift Testing 2 tests in 0 suites, 1 failure"])
    }

    /// An XCTest counter or a test's ending at the start of a line inside a failure's note is the note's text, under both tools.
    ///
    /// `quotesACount()` quotes `Executed 3 tests, with 2 failures …` on an indented line of its note, and `quotesAnEnding()` quotes `Test ghost() failed after …` and `Test phantom() passed after …`. Read as the run's own, the first put a stray counter in the summary and in `totals:`, and the second a test that never ran into the outcomes and the listing. The real counters beside them stay read: `xcodebuild` runs the `BetaTests` bundle's noted failure and then the `AlphaTests` process, whose own indented `Executed` lines follow. See `Fixtures/RunOutput/*-noted-shapes.txt`.
    @Test(arguments: [
        (fixture: "swift-test-noted-shapes", arguments: ["swift", "test"], exitCode: Int32(1)),
        (fixture: "xcodebuild-test-noted-shapes", arguments: ["xcodebuild", "test-without-building", "-scheme", "Noted-Package"], exitCode: Int32(65)),
    ])
    func aCounterOrAnEndingInsideAFailuresNoteIsNotReadAsOne(fixture: String, arguments: [String], exitCode: Int32) throws {
        let raw = try TestSources.runOutput(fixture)
        let report = try TestSources.runReport(fixture, invokedAs: arguments, exitCode: exitCode)

        // The capture carries the quoted shapes indented inside the notes.
        #expect(raw.contains("\n    Executed 3 tests, with 2 failures (0 unexpected) in 0.100 (0.100) seconds\n"))
        #expect(raw.contains("\n    Test ghost() failed after 0.001 seconds with 1 issue.\n"))

        // Five failures, and not one more for `ghost()`.
        #expect(report.testFailures.map(\.name).sorted() == [
            "-[AlphaTests.LegacyTests testLegacyAnswer]", "-[BetaTests.LegacyTests testLegacyAnswer]",
            "printsAnAnswerInItsNote()", "quotesACount()", "quotesAnEnding()",
        ])
        #expect(!report.summaryLines.contains { $0.contains("Executed 3 tests") })
        #expect(report.testOutcomes["ghost()"] == nil)
        #expect(report.testOutcomes["phantom()"] == nil)
        #expect(report.testOutcomes["quotesAnEnding()"]?.failed == 1)

        let counted = try #require(report.testFailures.first { $0.name == "quotesACount()" })
        #expect(counted.note?.contains("Executed 3 tests, with 2 failures (0 unexpected) in 0.100 (0.100) seconds") == true)
        let ended = try #require(report.testFailures.first { $0.name == "quotesAnEnding()" })
        #expect(ended.note?.contains("Test ghost() failed after 0.001 seconds with 1 issue.") == true)

        let kind: RunCommandKind = fixture.hasPrefix("swift-test") ? .swiftTest : .xcodebuild
        let answer = RunReportRenderer(kind: kind, workingDirectory: URL(fileURLWithPath: "/Users/dev/Noted"))
            .render(report, exitCode: exitCode, logURL: nil)
        let totals = answer.split(separator: "\n").filter { $0.hasPrefix("totals:") }
        // XCTest's real counters, one per bundle, are still read beside the quoted one.
        #expect(report.summaryLines.filter { $0.hasPrefix("Executed ") }.count == 2)
        #expect(totals == [
            "totals: ✘ failed · XCTest 2 tests across 2 bundles, 2 failures · Swift Testing 4 tests in 0 suites across 2 bundles, 3 failures",
        ])
    }

    /// The `summary not found` note is owed by what this answer prints, not by what the report happens to hold.
    ///
    /// Guarding the note on the report's summary lines while the block prints the filtered ones fails on one line that filter drops in practice: `swift test` builds before it runs, so `Build complete!` sits in a failing run's output and is removed for declaring the opposite of the run's verdict. A run whose only summary is that line would then print neither a summary nor the note saying there was none — the headline standing alone.
    @Test
    func aSummaryDroppedForContradictingTheVerdictLeavesTheNoteInItsPlace() throws {
        var filter = try RunOutputFilter(expecting: #require(RunVerdict.Contract.of(["swift", "test"])))
        filter.consume(line: "Build complete! (0.49s)")
        filter.consume(line: "/Users/dev/Widget/Sources/Widget/Harness.swift:12:5: error: the test harness crashed")
        let report = filter.finish()

        // The build's verdict is a real summary and the report keeps it; the run's verdict contradicts it.
        #expect(report.summaryLines == ["Build complete! (0.49s)"])
        #expect(report.verdict?.state == .failed)

        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"))
            .render(report, exitCode: 1, logURL: nil)
        #expect(answer.hasPrefix("✘ swift test — exit 1\n  no closing summary line in the log — the errors below are what it reported\n"))
        #expect(!answer.contains("Build complete!"))
    }

    /// A splice on the head of an issue line costs that failure nothing, because the splice is a known literal and comes off.
    ///
    /// `xcodebuild` writes one test runner's output through the middle of another's, and what that looks like in the corpus is one fixed string: `XCTestOutputBarrier`, in front of an otherwise intact line, four times across the two `xcodebuild -test` captures. Nothing there is a second runner's *content* — `Test .* Test ` occurs zero times in 8,185 lines — so the splice is not a shape to be guessed at but a token to be removed, and ``RunOutputFilter/consume(line:)`` removes it before any reader sees the line.
    ///
    /// Stated synthetically because every splice the corpus caught landed on a `passed after` line, which this filter ignores either way. The case worth asserting is the one it did not catch: the same token on the head of a `recorded an issue` line, where leaving it in place costs the failure its message *and* its `file:line`.
    ///
    /// The property is that nothing is lost: the name Swift Testing wrote, the location, the message, and the `↳` sentence beneath it all survive the splice.
    @Test
    func aBarrierSplicedOntoAnIssueLineIsStrippedBeforeTheLineIsRead() {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(line: "XCTestOutputBarrier✘ Test theHopperGaugePrintsItsSignage() recorded an issue at HopperGaugeTests.swift:59:9: Expectation failed: (labels → \"\").contains(wanted → \"Width\")")
        filter.consume(line: "↳ 'Width' is missing from the hopper gauge's signage")
        filter.consume(line: "✘ Test theHopperGaugePrintsItsSignage() failed after 0.487 seconds with 1 issue.")
        let report = filter.finish()

        #expect(report.testFailures.count == 1)
        let failure = report.testFailures.first
        #expect(failure?.name == "theHopperGaugePrintsItsSignage()")
        #expect(failure?.location == "HopperGaugeTests.swift:59:9")
        #expect(failure?.message == "Expectation failed: (labels → \"\").contains(wanted → \"Width\")")
        #expect(failure?.note == "'Width' is missing from the hopper gauge's signage")
    }

    /// Two runners flushing at once put two barriers in front of one line, and half a strip is worth nothing.
    ///
    /// Not in the corpus, and cheap to hold: the token is written per flush, so nothing about the toolchain says a line carries at most one. A single strip would leave the second in place and the line would be turned away exactly as an unstripped one is.
    @Test
    func aLineCarryingTwoBarriersIsStrippedOfBoth() {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(line: "XCTestOutputBarrierXCTestOutputBarrier✘ Test theHopperGaugeFitsItsLabels() recorded an issue at HopperGaugeTests.swift:71:9: Expectation failed: the label overflowed")
        let report = filter.finish()

        #expect(report.testFailures.count == 1)
        #expect(report.testFailures.first?.name == "theHopperGaugeFitsItsLabels()")
        #expect(report.testFailures.first?.location == "HopperGaugeTests.swift:71:9")
    }

    /// Swift 6.4's SwiftPM colours a compiler diagnostic even when stdout is a pipe — `path:line:col: \e[1;31merror: \e[1;39mcannot find …` — so a warning printed the same way has to survive too, with the escapes gone from its message and not merely from the line's first characters.
    @Test
    func aColoredWarningIsRecognisedOnceItsEscapesAreStripped() throws {
        let report = try TestSources.runReport("swift-build-colored-warning")

        #expect(report.errors.isEmpty)
        #expect(report.warnings.count == 1)
        let warning = try #require(report.warnings.first)
        #expect(warning.path == "/Users/dev/Pallet/Sources/Pallet/Pallet.swift")
        #expect(warning.line == 4)
        #expect(warning.column == 13)
        #expect(warning.message == "initialization of immutable value 'spare' was never used; consider replacing with assignment to '_' or removing it [#NoUsage]")
        #expect(!warning.message.contains("\u{1B}"))
        #expect(report.summaryLines == ["Build complete! (1.31 secs)"])
    }

    /// The exact shape a real build reports: a colour marker sitting between `error:` and the message reads as nothing without stripping it first, and `sift run -- swift build` recognises none of the build's errors.
    @Test
    func aColoredErrorIsRecognisedOnceItsEscapesAreStripped() throws {
        let report = try TestSources.runReport("swift-build-colored-failure")

        #expect(report.errors.count == 1)
        let error = try #require(report.errors.first)
        #expect(error.path == "/Users/dev/Pallet/Sources/Pallet/Pallet.swift")
        #expect(error.line == 4)
        #expect(error.column == 16)
        #expect(error.message == "cannot find 'Forklift' in scope")
        #expect(!error.message.contains("\u{1B}"))
    }

    /// A colour escape earlier in the stream — the build phase every `swift test` runs first — must not survive into what this filter keeps once the run reaches its tests, and the failure that follows has to be read exactly as an uncoloured one would be.
    @Test
    func aColoredWarningDuringATestBuildDoesNotHideTheFailure() throws {
        let report = try TestSources.runReport("swift-test-colored-warning-and-failure", invokedAs: ["swift", "test"])

        #expect(report.warnings.count == 1)
        #expect(!report.warnings[0].message.contains("\u{1B}"))
        #expect(report.testFailures.count == 1)
        let failure = try #require(report.testFailures.first)
        #expect(failure.name == "countIsOne()")
        #expect(failure.location == "PalletTests.swift:5:5")
        #expect(failure.message == "Expectation failed: Pallet().count() == 2")
        #expect(report.verdict?.state == .failed)
    }

    /// `xcodebuild … build -quiet` suppresses `** BUILD SUCCEEDED **` on a clean run, so the log carries no verdict at all even though the build passed — and the exit code is the one thing that lets the silence be read honestly rather than left as "no verdict".
    @Test
    func aQuietCleanXcodebuildBuildReadsAsPassedFromExitCode() throws {
        let report = try TestSources.runReport("xcodebuild-quiet-build-success", invokedAs: ["xcodebuild", "-scheme", "Pallet-Package", "build", "-quiet"], exitCode: 0)

        #expect(report.errors.isEmpty)
        let verdict = try #require(report.verdict)
        #expect(verdict.state == .succeeded)
        #expect(verdict.inferredFromExitCode)
        let answer = RunReportRenderer(kind: .xcodebuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Pallet"))
            .render(report, exitCode: 0, logURL: nil)
        #expect(answer.hasPrefix("✔ xcodebuild — no verdict printed under -quiet; read as passed from exit 0"))
        // A pass has nothing in the raw log to send the reader to: the line under it says what it rests on.
        #expect(!answer.contains("summary not found"))
        #expect(answer.split(separator: "\n").dropFirst().first == "  -quiet prints no closing line on a pass, so this rests on the exit code alone: a -quiet run cut short that still exited 0 would read the same")
    }

    /// The same silence, for `xcodebuild … test -quiet`: -quiet suppresses `** TEST SUCCEEDED **` too, and prints no per-test line to fall back on either.
    @Test
    func aQuietCleanXcodebuildTestReadsAsPassedFromExitCode() throws {
        let report = try TestSources.runReport("xcodebuild-quiet-test-success", invokedAs: ["xcodebuild", "-scheme", "Pallet-Package", "test", "-quiet"], exitCode: 0)

        #expect(report.testFailures.isEmpty)
        let verdict = try #require(report.verdict)
        #expect(verdict.state == .succeeded)
        #expect(verdict.inferredFromExitCode)
    }

    /// Without an exit code to read the silence against, this filter still answers exactly as it always has — the new reading only ever triggers when the caller states what the wrapped command actually returned.
    @Test
    func withoutAnExitCodeAQuietCleanBuildStillReadsAsNoVerdict() throws {
        let report = try TestSources.runReport("xcodebuild-quiet-build-success", invokedAs: ["xcodebuild", "-scheme", "Pallet-Package", "build", "-quiet"])

        #expect(report.verdict == nil)
    }

    /// `xcodebuild -quiet` prints `error: the following command failed with exit code 0 but produced no further output` in front of a real warning even on a build that succeeded — its own heuristic misfiring, not a diagnostic the compiler wrote — and a reader that counted it would never reach the exit-0 fallback above, since `errors` would not be empty.
    @Test
    func aQuietBuildsNoFurtherOutputLineIsNotCountedAsAnError() throws {
        let report = try TestSources.runReport("xcodebuild-quiet-build-success-with-warning", invokedAs: ["xcodebuild", "-scheme", "Pallet-Package", "build", "-quiet"], exitCode: 0)

        #expect(report.errors.isEmpty)
        #expect(report.warnings.count == 1)
        let verdict = try #require(report.verdict)
        #expect(verdict.state == .succeeded)
        #expect(verdict.inferredFromExitCode)
    }

    /// The same line precedes a real error on a build that actually failed, and must not double it: one error, not the noise line plus the diagnostic beneath it, and the run still reads as failed on the strength of the real one alone.
    @Test
    func aQuietBuildsRealFailureIsCountedOnceNotTwice() throws {
        let report = try TestSources.runReport("xcodebuild-quiet-build-failure", invokedAs: ["xcodebuild", "-scheme", "Pallet-Package", "build", "-quiet"], exitCode: 65)

        #expect(report.errors.count == 1)
        #expect(report.errors.first?.message == "cannot find 'Forklift' in scope")
        #expect(report.verdict?.state == .failed)
    }
}

private extension RunOutputFilterTests {
    /// The invocation `xcodebuild-test-failure` was captured under, recorded in `PROVENANCE.md`.
    static let gizmoTest = [
        "xcodebuild", "-project", "Gizmo.xcodeproj", "-scheme", "Gizmo", "-destination", "platform=macOS", "test",
    ]

    /// Sixty distinct failures over a log of 110 lines: twenty Swift Testing tests recording three issues each, which is what a suite failing on one shared precondition looks like.
    static let crowdedFailures = 60

    /// An empty report of a given size, for the arithmetic that only reads `totalLines`.
    static func report(totalLines: Int) -> RunReport {
        RunReport(
            errors: [],
            warnings: [],
            testFailures: [],
            summaryLines: [],
            contract: .unreadable,
            verdict: nil,
            tally: nil,
            totalLines: totalLines
        )
    }

    /// Ninety distinct compile errors, for the answer that carries both sections at once.
    static let crowdedErrors = 90

    /// `count` tokens spelled out of letters alone, since `RunFailureSignature` elides digits and would otherwise read every one of these as the same kind — which is a different rule refusing a listing for a different reason.
    static func tokens(_ count: Int) -> [String] {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        return (0 ..< count).map { String([letters[$0 / 26], letters[$0 % 26]]) }
    }

    /// That run as a report — no verdict, because a `swift test` that ends mid-suite prints no tally to stand as one.
    static var crowdedTestRun: RunReport {
        let failures = tokens(crowdedFailures).enumerated().map { index, name in
            RunTestFailure(
                name: "aTestNamed\(name)()",
                location: "WidgetTests.swift:\(index + 1):9",
                message: "Expectation failed: the \(name) precondition does not hold"
            )
        }
        return RunReport(
            errors: [],
            warnings: [],
            testFailures: failures,
            summaryLines: [],
            contract: .runTally,
            verdict: nil,
            tally: nil,
            totalLines: 110
        )
    }

    /// A `swift test` whose build broke wide and whose suite then failed wider: ninety distinct errors over the sixty distinct failures above, and one 303-line log standing behind both.
    ///
    /// Assembled rather than captured because nothing in the corpus is this shape — every capture there carries errors or failures and never both — which is exactly why the corpus alone cannot notice the budget being spent twice. The errors are read through `RunOutputFilter`, so they are the records the real thing would hold, and their paths are stated as the run printed them: relative, and so unchanged by the directory the answer is read in.
    static var crowdedBuildAndTestRun: RunReport {
        var filter = RunOutputFilter(expecting: .unreadable)
        for (index, name) in tokens(crowdedErrors).enumerated() {
            filter.consume(line: "Sources/Widget/File\(index).swift:1:1: error: cannot find '\(name)' in scope")
        }
        let built = filter.finish()
        return RunReport(
            errors: built.errors,
            warnings: [],
            testFailures: crowdedTestRun.testFailures,
            summaryLines: [],
            contract: .runTally,
            verdict: nil,
            tally: nil,
            totalLines: 303
        )
    }

    static let fixtureNames = [
        "swift-build-success", "swift-build-failure", "swift-build-mass-failure", "swift-build-diverse-failure",
        "swift-test-pass", "swift-test-fail",
        "swift-test-linkerror", "swift-test-linkerror-6.4", "swift-test-xctest-only-failure", "swift-test-mixed-xctest-failure",
        "xcodebuild-build-success", "xcodebuild-build-failure-dup",
        "xcodebuild-test-success", "xcodebuild-test-failure",
        "xcodebuild-test-execute-success", "xcodebuild-test-execute-failure-environmental",
        "xcodebuild-build-interrupted", "xcodebuild-test-execute-truncated",
        "xcodebuild-test-two-bundles", "xcodebuild-test-two-xctest-bundles",
        "swift-test-display-name", "swift-test-quoted-tally", "swift-test-quoted-totals", "swift-test-noted-tally",
        "swift-test-noted-shapes", "xcodebuild-test-noted-shapes",
        "swift-test-xctest-filter-skipped", "swift-test-xctest-filter-two-bundles",
    ]

    func renderedAnswer(_ fixture: String, kind: RunCommandKind, exitCode: Int32) throws -> String {
        let report = try TestSources.runReport(fixture)
        return RunReportRenderer(kind: kind, workingDirectory: URL(fileURLWithPath: "/Users/dev/Gizmo"))
            .render(report, exitCode: exitCode, logURL: URL(fileURLWithPath: "/Users/dev/Gizmo/.sift/runs/run-20260818-101744-9b30e5af.log"))
    }

    /// The `totals:` line is composed content, same as the headline and summary above it, so it has to be charged against ``RunReportRenderer/allowance(of:beside:)`` like they are, not appended for free once the listing sections have already spent what they were given.
    ///
    /// Four distinct failures, each rendered in full, are exactly as long listed as they are sampled — ``RunFailureCensus/signatureCap`` never engages below five — so this shape isolates the totals line's own line, with nothing else able to absorb the one-line overspend on either side of the boundary.
    @Test func theTotalsLineIsChargedAgainstItsOwnAllowance() {
        let failures = (0 ..< 4).map { index in
            RunTestFailure(
                name: "aTestNamed\(index)()",
                location: "WidgetTests.swift:\(index + 1):9",
                message: "Expectation failed: precondition \(index) does not hold"
            )
        }
        let report = RunReport(
            errors: [], warnings: [], testFailures: failures, summaryLines: [],
            contract: .runTally, verdict: nil, tally: nil, totalLines: 14
        )
        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"))
            .render(report, exitCode: 1, logURL: nil)
        let lines = answer.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines.count <= report.totalLines)
    }
}
