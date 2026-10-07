import Foundation
@testable import SiftCore
import Testing

/// A failed `swift build` closes on SwiftPM's own `error: Build failed`, which is the log's closing line and not a sign the log was cut short.
struct RunBuildFailedClosingLineTests {
    /// The real capture ends on `error: Build failed`: the answer quotes it as the build's verdict and says nothing about a missing closing line.
    @Test
    func aBuildThatClosedOnBuildFailedQuotesItInsteadOfSayingTheLineIsMissing() throws {
        let report = try TestSources.runReport("swift-build-colored-failure", invokedAs: ["swift", "build"], exitCode: 1)

        #expect(report.summaryLines == ["error: Build failed"])
        #expect(report.verdict?.state == .failed)
        #expect(report.verdict?.line == "error: Build failed")
        #expect(report.errors.count == 1)
        let answer = Self.answer(report)
        #expect(answer.hasPrefix("✘ swift build — exit 1\n  error: Build failed\n"))
        #expect(!answer.contains("no closing summary line"))
        #expect(!answer.contains("see the raw log"))
        #expect(answer.contains("Sources/Pallet/Pallet.swift:4:16: error: cannot find 'Forklift' in scope"))
    }

    /// Swift 6.4 closes a failed link on both literals, one after the other; the first is the one quoted, once.
    @Test
    func aBuildThatClosedOnBothLiteralsQuotesTheFirstOnce() throws {
        var filter = try RunOutputFilter(expecting: #require(RunVerdict.Contract.of(["swift", "build"])))
        filter.consume(line: "/Users/dev/Pallet/Sources/Pallet/Pallet.swift:4:16: error: cannot find 'Forklift' in scope")
        filter.consume(line: "error: Build failed")
        filter.consume(line: "error: fatalError")
        let report = filter.finish(exitCode: 1)

        #expect(report.summaryLines == ["error: Build failed"])
        #expect(report.verdict?.state == .failed)
        #expect(!Self.answer(report).contains("no closing summary line"))
    }

    /// A log that stops without either literal keeps the note: that is the log the note is for.
    @Test
    func aBuildLogWithNoClosingLineStillSaysSo() throws {
        let report = try TestSources.runReport("swift-build-failure", invokedAs: ["swift", "build"], exitCode: 1)

        #expect(report.summaryLines.isEmpty)
        #expect(Self.answer(report).contains("no closing summary line in the log — the errors below are what it reported"))
    }

    /// The literal quoted inside a compiler error's message is that error's text, never the log's closing line.
    @Test
    func aMessageQuotingTheLiteralIsNoClosingLine() throws {
        var filter = try RunOutputFilter(expecting: #require(RunVerdict.Contract.of(["swift", "build"])))
        filter.consume(line: "/Users/dev/Pallet/Sources/Pallet/Pallet.swift:4:16: error: error: Build failed")
        let report = filter.finish(exitCode: 1)

        #expect(report.summaryLines.isEmpty)
        #expect(Self.answer(report).contains("no closing summary line in the log"))
    }

    /// `swift test` closes on its run tally, so a build failure under it is unchanged by the literal.
    @Test
    func aSwiftTestThatFailedToBuildDoesNotTakeTheLiteralAsItsSummary() throws {
        let report = try TestSources.runReport("swift-test-filter-compile-error", invokedAs: ["swift", "test", "--filter", "Pallet"], exitCode: 1)

        #expect(!report.summaryLines.contains("error: Build failed"))
        #expect(!report.summaryLines.contains("error: fatalError"))
    }

    private static func answer(_ report: RunReport) -> String {
        RunReportRenderer(kind: .swiftBuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Pallet")).render(report, exitCode: 1, logURL: nil)
    }
}
