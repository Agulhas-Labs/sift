//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Three gaps a trial found in `sift run`'s answer: a timestamped tool-log line dropped, an expectation cut at 240 bytes, and a nothing-ran answer that said its headline three times.
struct RunAnswerCompletenessTests {
    private static var metadataWarning: String {
        "appintentsmetadataprocessor[58835:11885402] warning: Metadata extraction skipped, no Gizmo.framework dependency found"
    }

    private static var archiveError: String {
        "appintentsnltrainingprocessor[58836:11885403] error: Could not archive SSU artifacts. Check build log."
    }

    private static var logURL: URL {
        URL(fileURLWithPath: "/Users/dev/Widget/.sift/runs/run-20000101-120000-00000000.log")
    }

    /// A passing `xcodebuild` build whose log carries timestamped tool lines: two copies of one warning a second apart, a second warning, and an `error:` line.
    private static func passingBuild() -> RunReport {
        var filter = RunOutputFilter(invokedAs: ["xcodebuild", "build"])
        filter.consume(line: "2026-10-09 18:30:12.100 \(metadataWarning)")
        filter.consume(line: "2026-10-09 18:30:13.200 \(metadataWarning)")
        filter.consume(line: "2026-10-09 18:30:14.300 appintentsmetadataprocessor[58835:11885402] warning: Another thing worth a line")
        filter.consume(line: "2026-10-09 18:30:15.400 \(archiveError)")
        filter.consume(line: "** BUILD SUCCEEDED **")
        return filter.finish(exitCode: 0)
    }

    /// The line parses with no file location, the tool as its source and the timestamp and pid gone.
    @Test
    func aTimestampedToolLineIsADiagnosticNamingItsTool() throws {
        let warning = try #require(RunDiagnostic.parse("2026-10-09 18:30:12.100 \(Self.metadataWarning)"))
        #expect(warning.severity == .warning)
        #expect(warning.path == nil)
        #expect(warning.source == "appintentsmetadataprocessor")
        #expect(warning.described == "appintentsmetadataprocessor: warning: Metadata extraction skipped, no Gizmo.framework dependency found")

        let error = try #require(RunDiagnostic.parse("2026-10-09 18:30:15.400 \(Self.archiveError)"))
        #expect(error.severity == .error)
        #expect(error.described == "appintentsnltrainingprocessor: error: Could not archive SSU artifacts. Check build log.")
    }

    /// Only the whole shape counts: a prefix that merely holds a space is still noise.
    @Test
    func aPrefixThatOnlyResemblesATimestampedToolIsNotADiagnostic() {
        #expect(RunDiagnostic.parse("2026-10-09 18:30:12 appintents warning: nope") == nil)
        #expect(RunDiagnostic.parse("the build said: warning: nope") == nil)
        #expect(RunDiagnostic.parse("2026-10-09 18:30:12.100 tool[12:34] chatter: warning: nope") == nil)
    }

    /// Deduplicated across timestamps and shown under a heading of their own on a build that still passes, with nothing left for a verdict to read.
    @Test
    func theToolLogOfAPassingBuildIsShownUnderItsOwnHeading() {
        let report = Self.passingBuild()
        #expect(report.warnings.isEmpty)
        #expect(report.errors.isEmpty)
        #expect(report.toolLog.count == 3)
        #expect(report.verdict?.state == .succeeded)

        let answer = RunReportRenderer(kind: .xcodebuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"))
            .render(report, exitCode: 0, logURL: Self.logURL)
        let lines = answer.components(separatedBy: "\n")
        #expect(lines.first?.hasPrefix("✔ xcodebuild") == true)
        #expect(lines.contains("tool log (3):"))
        #expect(lines.contains("  appintentsmetadataprocessor: warning: Metadata extraction skipped, no Gizmo.framework dependency found"))
        #expect(lines.contains("  appintentsnltrainingprocessor: error: Could not archive SSU artifacts. Check build log."))
        #expect(!lines.contains { $0.hasPrefix("warnings (") })
    }

    /// An expectation message and its expansion up to a kilobyte is printed whole.
    @Test
    func anExpectationUpToAKilobyteIsShownWhole() {
        let expansion = String(repeating: "(items → [1, 2, 3]) ", count: 24)
        let message = "Expectation failed: \(expansion)"
        #expect(message.utf8.count > RunFailureCensus.wordsCap)
        #expect(message.utf8.count <= 1024)
        let block = RunFailureShape.of(
            [RunFailureShape.Failure(name: "aTest()", location: "T.swift:1:1", message: message)],
            changedFiles: .of([])
        ).rendered()

        #expect(block.contains("    \(message)"))
        #expect(!block.contains { $0.contains("see the raw log") })
    }

    /// Past a kilobyte it is truncated, with the pointer to the raw log.
    @Test
    func anExpectationPastAKilobyteIsTruncatedWithThePointer() {
        let message = String(repeating: "x", count: 1100)
        let block = RunFailureShape.of(
            [RunFailureShape.Failure(name: "aTest()", location: "T.swift:1:1", message: message)],
            changedFiles: .of([])
        ).rendered()

        #expect(block.contains("    \(String(repeating: "x", count: 1024))… (+76 characters — see the raw log)"))
    }

    /// A filter that matched nothing is answered by its headline and the raw-log line: no totals line, no tool summary, no repeat of the tool's own warning.
    @Test
    func aNothingRanAnswerHoldsTheHeadlineAndTheReceiptOnly() throws {
        let arguments = ["swift", "test", "--filter", "Gizmo"]
        let report = try TestSources.runReport("swift-test-no-match", invokedAs: arguments, exitCode: 0)
        let selector = try #require(RunTestSelector.named(in: arguments))
        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"), selector: selector)
            .render(report, exitCode: 0, logURL: Self.logURL)
        let lines = answer.components(separatedBy: "\n")

        #expect(lines.count == 2)
        #expect(lines.first == "✘ swift test — nothing ran: no test matched --filter Gizmo (the command exited 0; sift run exits 4)")
        #expect(lines.last?.hasPrefix("raw: .sift/runs/run-20000101-120000-00000000.log") == true)
        #expect(!answer.contains("totals:"))
        #expect(!answer.contains("Build complete!"))
        #expect(!answer.contains("No matching test cases"))
    }

    /// A different warning on the same run is not the headline's, and stays.
    @Test
    func aWarningThatIsNotTheHeadlinesStaysOnANothingRanAnswer() throws {
        let arguments = ["swift", "test", "--filter", "Gizmo"]
        var filter = RunOutputFilter(invokedAs: arguments)
        filter.consume(line: "Build complete! (0.98 secs)")
        filter.consume(line: "warning: some other thing")
        filter.consume(line: "warning: No matching test cases were run")
        let report = filter.finish(exitCode: 0)
        let selector = try #require(RunTestSelector.named(in: arguments))
        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"), selector: selector)
            .render(report, exitCode: 0, logURL: Self.logURL)

        #expect(answer.contains("warnings (1):"))
        #expect(answer.contains("warning: some other thing"))
        #expect(!answer.contains("No matching test cases"))
    }
}
