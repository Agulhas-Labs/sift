//
// Copyright © Agulhas Labs
//

@testable import SiftCLI
import Testing

/// `sift run --help` names every exit code sift sets in place of the wrapped command's, the unfiltered zero-test run's included.
struct RunHelpUnfilteredZeroTests {
    /// The help said only a run that names its tests exits 4 for executing none; an unfiltered `swift test` of none does too.
    @Test
    func theHelpNamesTheUnfilteredZeroTestExit() {
        let discussion = RunCommand.configuration.discussion.replacingOccurrences(of: "\n", with: " ")

        #expect(discussion.contains("An unfiltered `swift test` of a package whose manifest declares test targets that exits 0 having executed no test answers ✘ … nothing ran: no test executed and exits 4 as well."), "\(discussion)")
    }
}
