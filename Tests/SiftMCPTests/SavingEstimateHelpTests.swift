@testable import SiftCLI
import SiftCore
import Testing

/// The saving is an estimate, and `--help` is where a reader who wonders what it is measured against looks.
struct SavingEstimateHelpTests {
    private static func words(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test
    func reportHelpStatesTheSavingIsAnEstimateAndItsBaseline() {
        let discussion = Self.words(ReportCommand.configuration.discussion)

        #expect(discussion.contains("The saving is priced against the whole file as its baseline (a located range counts against the file it was cut from), so it leans high."))
        #expect(discussion.contains(TokenEstimate.notMeasured))
    }

    @Test
    func auditHelpPointsAtTheSavingLines() {
        let discussion = Self.words(AuditCommand.configuration.discussion)

        #expect(discussion.contains("The saving lines are estimates, stated gross: see `sift report --help`"))
        #expect(discussion.contains(TokenEstimate.notMeasured))
    }
}
