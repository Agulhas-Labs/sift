//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The note that says how many shards a SwiftPM run used and what it cut them from.
struct PackageShardNoteTests {
    @Test func aFileScopeTestIsCountedAsAUnitNeverAsASuite() throws {
        let tests = try PackageShardPlanner.listed("LibTests.AlphaTests/testOne()\nLibTests.AlphaTests/testTwo()\nLibTests.BetaTests/testThree()\nLibTests.loose()")

        let note = PackageShardPlanner.shardsNote(shards: 2, requested: 4, tests: tests)

        #expect(note == "2 of 4 shards over 3 units")
        #expect(!note.contains("suite"))
        #expect(PackageShardPlanner.shardsNote(shards: 1, requested: 1, tests: tests) == "1 of 1 shard over 3 units")
    }
}
