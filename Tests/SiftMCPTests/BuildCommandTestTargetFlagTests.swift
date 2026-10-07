//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import Testing

/// `sift build --analyse --build-tests` is what puts the test targets into the timed build.
struct BuildCommandTestTargetFlagTests {
    @Test
    func theFlagAddsBuildTestsToTheBuildAndItsAbsenceDoesNot() throws {
        let plain = try BuildCommand.parse(["--analyse"])
        let withTests = try BuildCommand.parse(["--analyse", "--build-tests"])

        #expect(!BuildCommand.arguments(buildingTests: plain.buildTests).contains("--build-tests"))
        #expect(BuildCommand.arguments(buildingTests: withTests.buildTests).contains("--build-tests"))
    }
}
