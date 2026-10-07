//
// Copyright © Agulhas Labs
//

import Foundation

/// The indexed test files no store holds a unit for, told apart by whether any test file has one: the one classification every `where` reader of them goes through.
///
/// Where no test file has a unit, the test targets were never built — a plain `swift build` never builds them — so a test build adds every one, and references from tests are a lower bound until it runs. Where some do, a test build ran and the rest sit outside any target it builds (a stray file, a fixture, a sample project), which no build adds: advising one there repeats on every answer however often it is followed. Those files are still named, never dropped: in a repo whose modules are all guessed, dropping them would bring back `0 tests`.
struct TestFileCoverage: Equatable {
    /// How many indexed test files no store holds a unit for.
    let withoutUnit: Int
    /// Whether no indexed test file has a unit in any store, so the test targets were never built.
    let neverBuilt: Bool
    let provenance: DiscoveredStore.Provenance

    /// The count the axis reads as `partial`: every file without a unit where the test targets were never built, and none where a test build ran, since no build would add the rest.
    var partialCount: Int {
        neverBuilt ? withoutUnit : 0
    }

    /// The build that adds the files, or empty where no build would.
    var build: String {
        guard neverBuilt else { return "" }
        return provenance == .swiftPMBuild ? "build with `sift run -- swift build --build-tests`" : "build the test target"
    }

    /// How the files are named where a test build ran and no build would add them.
    static func outsideTargets(_ count: Int) -> String {
        "\(count) test file\(count == 1 ? "" : "s") outside any built target"
    }
}
