//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// An answer with no `totals:` line and three or more content lines closes on its headline said again, directly above the receipt, so a `tail -3` keeps the verdict.
@Suite(.temporaryDirectories)
struct RunClosingVerdictTests {
    /// The real capture of a build with two warnings: the line before the receipt is the verdict.
    @Test
    func aBuildWithWarningsClosesOnItsVerdict() throws {
        let report = try TestSources.runReport("swift-build-success", invokedAs: ["swift", "build"], exitCode: 0)
        let lines = Self.lines(of: Self.answer(report, kind: .swiftBuild, exitCode: 0))

        #expect(lines[lines.count - 2] == "verdict: ✔ swift build")
        #expect(lines.last?.hasPrefix("raw:") == true)
    }

    /// The real capture of a failed build: the verdict carries the exit status.
    @Test
    func aFailedBuildClosesOnItsVerdictWithTheExitStatus() throws {
        let report = try TestSources.runReport("swift-build-failure", invokedAs: ["swift", "build"], exitCode: 1)
        let lines = Self.lines(of: Self.answer(report, kind: .swiftBuild, exitCode: 1))

        #expect(lines[lines.count - 2] == "verdict: ✘ swift build — exit 1")
    }

    /// A headline and its summary alone is two lines before the receipt, and the headline is already within the last three.
    @Test
    func aBuildAnswerOfHeadlinePlusSummaryHasNoVerdictLine() {
        var filter = RunOutputFilter(invokedAs: ["swift", "build"])
        filter.consume(line: "Build complete! (1.21s)")
        let answer = Self.answer(filter.finish(exitCode: 0), kind: .swiftBuild, exitCode: 0)

        #expect(!answer.contains("verdict:"))
    }

    /// A `swift test` answer ends on its `totals:` line and is left as it was.
    @Test
    func aTestAnswerHasNoVerdictLine() throws {
        let report = try TestSources.runReport("swift-test-pass", invokedAs: ["swift", "test"], exitCode: 0)
        let answer = Self.answer(report, kind: .swiftTest, exitCode: 0)

        #expect(answer.contains("totals:"))
        #expect(!answer.contains("verdict:"))
    }

    /// The `-quiet` pass read off the exit code, with warnings: the case that showed a tail with no verdict.
    @Test
    func anInferredQuietPassWithWarningsClosesOnItsFullHeadline() {
        var filter = RunOutputFilter(invokedAs: ["xcodebuild", "-scheme", "Widget-Package", "build", "-quiet"])
        filter.consume(line: "/Users/dev/Widget/Sources/Widget/Widget.swift:2:9: warning: initialization of variable 'unused' was never used; consider replacing with assignment to '_' or removing it")
        filter.consume(line: "/Users/dev/Widget/Sources/Widget/Widget.swift:3:9: warning: variable 'a' was never mutated; consider changing to 'let' constant")
        let lines = Self.lines(of: Self.answer(filter.finish(exitCode: 0), kind: .xcodebuild, exitCode: 0))
        let verdict = lines[lines.count - 2]

        #expect(verdict.hasPrefix("verdict: ✔ xcodebuild — no verdict printed under -quiet; "))
        #expect(verdict == "verdict: " + lines[0])
        #expect(lines.last?.hasPrefix("raw:") == true)
    }

    /// The receipt's `N out` is the rendered answer's own line count.
    @Test
    func theReceiptCountsTheVerdictLine() throws {
        let report = try TestSources.runReport("swift-build-success", invokedAs: ["swift", "build"], exitCode: 0)
        let lines = Self.lines(of: Self.answer(report, kind: .swiftBuild, exitCode: 0))
        let receipt = try #require(lines.last)

        #expect(lines[lines.count - 2].hasPrefix("verdict: "))
        #expect(receipt.contains(", \(lines.count) out)"))
    }

    private static func lines(of answer: String) -> [String] {
        answer.components(separatedBy: "\n")
    }

    private static func answer(_ report: RunReport, kind: RunCommandKind, exitCode: Int32) -> String {
        let log = URL(fileURLWithPath: "/Users/dev/Widget/.sift/runs/run-1.log")
        return RunReportRenderer(kind: kind, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget")).render(report, exitCode: exitCode, logURL: log)
    }
}
