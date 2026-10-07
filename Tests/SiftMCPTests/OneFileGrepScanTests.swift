//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// The audit's scan scores a non-recursive name grep of one Swift file as the hook treats it: offered that file's own digest, so a run of it is a miss.
struct OneFileGrepScanTests {
    /// A name grep of one Swift file that ran is cold, and not withheld on worth.
    @Test func aNameGrepOfOneFileThatRanIsCold() {
        let tally = TranscriptFixture.tally([
            TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "grep -n SummaryState Sources/App/SummaryState.swift", "description": "find it"]),
            TranscriptFixture.toolResult(id: "b1", isError: false),
        ])

        #expect(tally.cold == 1)
        #expect(tally.withheldOnWorth == 0)
    }
}
