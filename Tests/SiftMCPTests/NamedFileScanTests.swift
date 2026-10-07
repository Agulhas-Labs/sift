//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// The audit's scan scores a name grep over Swift files it names as the hook treats it: let run, since a `where` would list the name across the whole tree.
struct NamedFileScanTests {
    /// A name grep the caller scoped to several Swift files, or a glob of them, is not a miss and not cold.
    @Test(arguments: [
        "grep -n SummaryState Sources/App/SummaryState.swift Sources/App/Reader.swift",
        "grep -n SummaryState Sources/App/*.swift",
        "grep -rn SummaryState Sources/App/Reader.swift Sources/App/Writer.swift",
    ])
    func aNameGrepOfNamedFilesThatRanIsNotAMiss(command: String) {
        let tally = TranscriptFixture.tally([
            TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": command, "description": "find it"]),
            TranscriptFixture.toolResult(id: "b1", isError: false),
        ])

        #expect(tally.cold == 0)
        #expect(tally.withheldOnWorth == 1)
    }
}
