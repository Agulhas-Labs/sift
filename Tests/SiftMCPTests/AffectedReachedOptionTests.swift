//
// Copyright © Agulhas Labs
//

import ArgumentParser
@testable import SiftCLI
import Testing

/// `affected --reached` is an additive CLI option: absent it the command asks nothing about one test.
struct AffectedReachedOptionTests {
    @Test
    func theOptionIsReadAndIsAbsentByDefault() throws {
        #expect(try AffectedCommand.parse(["--reached", "LibTests.GadgetTests/uses3()"]).reached == ["LibTests.GadgetTests/uses3()"])
        #expect(try AffectedCommand.parse([]).reached.isEmpty)
    }
}
