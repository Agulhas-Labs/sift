import Foundation
@testable import SiftCore
import Testing

/// A failed build whose only error is the compiler's crash diagnostic, which has a `file:line:col` and is placed like any other error.
struct RunPlacedErrorNoteIssue426Tests {
    @Test
    func aPlacedCrashDiagnosticIsNotFollowedByASummaryNotFoundNote() throws {
        var filter = try RunOutputFilter(expecting: #require(RunVerdict.Contract.of(["swift", "build"])))
        filter.consume(line: "Sources/Probe/Widget.swift:26:13: error: failed to produce diagnostic for expression; please submit a bug report (https://swift.org/contributing/#reporting-bugs)")
        let report = filter.finish()

        #expect(report.errors.count == 1)
        let answer = RunReportRenderer(kind: .swiftBuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Probe"))
            .render(report, exitCode: 1, logURL: nil)
        #expect(!answer.contains("summary not found"))
        #expect(!answer.contains("see the raw log"))
        #expect(answer.contains("Sources/Probe/Widget.swift:26:13: error: failed to produce diagnostic"))
    }
}
