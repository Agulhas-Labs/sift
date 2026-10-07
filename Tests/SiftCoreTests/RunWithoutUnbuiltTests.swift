//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A run without the change that did not build is answered with the compiler error that stopped it, and the tests that passed with the change are counted in one line rather than listed one apiece.
@Suite(.temporaryDirectories)
struct RunWithoutUnbuiltTests {
    private static var unusedValue: String {
        "Sources/Widgets/Widget.swift:5:13: error: initialization of immutable value 'phase' was never used; consider replacing with assignment to '_' or removing it\n"
    }

    /// The answer names the first compiler error with its file and line, and the tests that passed with the change are one count line: a line apiece says only that nothing ran, twelve times over.
    @Test
    func anUnbuiltRunNamesItsErrorAndCountsTheTestsThatNeverRan() throws {
        let directory = try RunWithoutAnswerTests.directory(holding: ["Sources/Widgets/Widget.swift": "import Foundation\n"])
        let selector = RunTestSelector.named(in: ["swift", "test", "--filter", "shoutingWorks"])
        let tests = (1 ... 12).reduce(into: [String: Bool]()) { $0["check\($1)()"] = true }

        let text = RunWithoutAnswerTests.judged(
            without: RunWithoutAnswerTests.failedBeforeTests(Self.unusedValue),
            with: RunWithoutAnswerTests.run(tests),
            workingDirectory: directory,
            selector: selector
        ).render().text
        let lines = text.split(separator: "\n").map(String.init)

        #expect(lines.contains("    Sources/Widgets/Widget.swift:5:13: error: initialization of immutable value 'phase' was never used; consider replacing with assignment to '_' or removing it"), "\(text)")
        #expect(lines.contains("  12 tests pass with it and did not run without Sources/, which did not build"), "\(text)")
        #expect(!lines.contains { $0.contains("did not run without Sources/;") }, "\(text)")
        #expect(lines.contains { $0.hasPrefix("without Sources/ — ✘ swift test — did not build") }, "\(text)")
    }

    /// A single test is said in the singular, and the folded line is where the test would have been listed.
    @Test
    func oneTestThatNeverRanIsCountedInTheSingular() {
        let text = RunWithoutAnswerTests.judged(
            without: RunWithoutAnswerTests.failedBeforeTests(Self.unusedValue),
            with: RunWithoutAnswerTests.run(["shoutingWorks()": true])
        ).render().text

        #expect(text.contains("\n  1 test passes with it and did not run without Sources/, which did not build\n"), "\(text)")
    }

    /// A test that failed with the change is still listed by name, since it has something to say that a count would lose.
    @Test
    func aTestThatFailedWithTheChangeStaysListed() {
        let text = RunWithoutAnswerTests.judged(
            without: RunWithoutAnswerTests.failedBeforeTests(Self.unusedValue),
            with: RunWithoutAnswerTests.run(["shoutingWorks()": true, "theGridReflows()": false])
        ).render().text
        let lines = text.split(separator: "\n").map(String.init)

        #expect(lines.contains { $0.hasPrefix("  ⚠ theGridReflows() — did not run without Sources/;") }, "\(text)")
        #expect(lines.contains("  1 test passes with it and did not run without Sources/, which did not build"), "\(text)")
    }

    /// A test that passed with the change only on a retry keeps its line, so the retry note is not counted away.
    @Test
    func aPassThatTookARetryStaysListed() {
        var filter = RunOutputFilter(expecting: RunVerdict.Contract.of(["xcodebuild", "test", "-only-testing:WidgetTests"]) ?? .unreadable)
        filter.consume(Data("""
        Test Case '-[WidgetTests.LegacyWidgetTests testNaming]' started.
        Test Case '-[WidgetTests.LegacyWidgetTests testNaming]' failed (0.001 seconds).
        Test Case '-[WidgetTests.LegacyWidgetTests testNaming]' started.
        Test Case '-[WidgetTests.LegacyWidgetTests testNaming]' passed (0.001 seconds).
        ** TEST SUCCEEDED **

        """.utf8))
        let with = RunOutcome(kind: .xcodebuild, logKey: "xcodebuild test", exitCode: 0, report: filter.finish(), log: nil, repositoryRoot: nil)

        let text = RunWithoutAnswerTests.judged(
            without: RunWithoutAnswerTests.failedBeforeTests(Self.unusedValue, xcodebuild: true),
            with: with,
            retries: true
        ).render().text

        #expect(text.contains("testNaming] — ") && text.contains("passed only on a retry, after 1 failure"), "\(text)")
        #expect(!text.contains("which did not build\n"), "\(text)")
    }

    /// Folding the lines changes neither the headline nor what is proven.
    @Test
    func theCountLineLeavesTheHeadlineAndTheProofAlone() {
        let judged = RunWithoutAnswerTests.judged(
            without: RunWithoutAnswerTests.failedBeforeTests(Self.unusedValue),
            with: RunWithoutAnswerTests.run(["shoutingWorks()": true])
        )

        #expect(judged.render().text.hasPrefix("✘ the command failed before running tests without Sources/ — nothing was proven\n"))
        #expect(!judged.proven)
    }
}
