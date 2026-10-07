//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import Testing

/// The line `audit --replay --summary` ends on, naming how long the command took.
struct ReplayElapsedTests {
    /// Under a minute the time is seconds alone, rounded to the nearest one.
    @Test func secondsAlone() {
        #expect(AuditCommand.elapsedLine(0) == "elapsed 0s")
        #expect(AuditCommand.elapsedLine(41.6) == "elapsed 42s")
    }

    /// From a minute, the minutes lead and the seconds follow.
    @Test func minutesAndSeconds() {
        #expect(AuditCommand.elapsedLine(60) == "elapsed 1m 0s")
        #expect(AuditCommand.elapsedLine(224) == "elapsed 3m 44s")
    }

    /// From an hour, the hours lead, so a run past the suite's proof reads as one.
    @Test func hoursMinutesAndSeconds() {
        #expect(AuditCommand.elapsedLine(3600 + 2 * 60 + 5) == "elapsed 1h 2m 5s")
        #expect(AuditCommand.elapsedLine(4 * 3600) == "elapsed 4h 0m 0s")
    }
}
