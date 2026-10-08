//
// Copyright © Agulhas Labs
//

import ArgumentParser
@testable import SiftCLI
import Testing

/// `affected --reached` may be given more than once, and every value is kept, in the order given.
struct AffectedReachedRepeatTests {
    @Test
    func everyRepeatedValueIsKeptInOrder() throws {
        let command = try AffectedCommand.parse(["--reached", "A", "--reached", "B", "--reached", "C"])

        #expect(command.reached == ["A", "B", "C"])
    }
}
