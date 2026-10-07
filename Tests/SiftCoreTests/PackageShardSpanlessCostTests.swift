//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// A SwiftPM package's suites that have no recorded span, charged in wall seconds by their framework: a Swift Testing suite's per-test clocks overlap and never add up, an XCTest suite's do.
struct PackageShardSpanlessCostTests {
    /// Forty Swift Testing suites of ten tests, each test's own clock between 20 s and 88 s, in the proportions a real package's store held: under in-process parallelism a clock counts the time its test waited, so the clocks sum to many times the run.
    private static let swiftTestingLines = (0 ..< 40).flatMap { suite in
        (0 ..< 10).map { test in "LibTests.Suite\(suite)/check\(test)()" }
    }

    /// An XCTest suite, listed without parentheses, whose tests ran one after another.
    private static let xctestLines = (0 ..< 4).map { "LibTests.LegacyTests/testStep\($0)" }

    private static func clock(of test: TestIdentifier) -> Double? {
        guard test.type != "LegacyTests" else {
            return 30
        }
        let suite = Int(test.type.dropFirst("Suite".count)) ?? 0
        let index = Int(test.function.dropFirst("check".count).dropLast(2)) ?? 0
        return 20 + Double((suite * 7 + index * 13) % 69)
    }

    private static let largestClock = 88.0

    @Test func listingNamesTheSuitesSwiftTestingAloneDeclares() {
        let listing = ["LibTests.AlphaTests/one()", "LibTests.LegacyTests/testOne", "LibTests.MixedTests/testTwo", "LibTests.MixedTests/three()", "LibTests.loose()"]

        #expect(PackageShardPlanner.swiftTestingSuites(listed: listing.joined(separator: "\n")) == ["LibTests.AlphaTests", "LibTests.loose()"])
    }

    @Test func aStoreWithNoSpansChargesSwiftTestingSuitesTheirLongestClockNotTheirSum() throws {
        let listing = Self.swiftTestingLines.joined(separator: "\n")
        let tests = try PackageShardPlanner.listed(listing)

        let plan = PackageShardPlanner.plan(
            tests: tests,
            shards: 4,
            swiftTestingSuites: PackageShardPlanner.swiftTestingSuites(listed: listing),
            duration: Self.clock(of:)
        )

        #expect(plan.shards.count == 4)
        // Summed, one suite's clocks come to some 500 s and a shard's to some 5,000 s; the process holds no suite longer than its longest test here.
        for shard in plan.shards {
            #expect(shard.predictedSeconds <= Self.largestClock * 1.5, "shard \(shard.index) predicted \(shard.predictedSeconds) s")
        }
    }

    @Test func spanlessSwiftTestingSuitesBesideSpannedOnesAreNotStackedAsSerialTime() throws {
        let listing = (Self.swiftTestingLines + Self.xctestLines).joined(separator: "\n")
        let tests = try PackageShardPlanner.listed(listing)
        // Thirty-five suites have spans between 40 s and 90 s; five never recorded one.
        let spans = (0 ..< 35).reduce(into: [String: Double]()) { spans, suite in spans["LibTests.Suite\(suite)"] = 40 + Double(suite * 11 % 51) }

        let plan = PackageShardPlanner.plan(
            tests: tests,
            shards: 4,
            swiftTestingSuites: PackageShardPlanner.swiftTestingSuites(listed: listing),
            duration: Self.clock(of:),
            suiteSeconds: { spans[$0] }
        )

        #expect(plan.shards.count == 4)
        let legacy = try #require(plan.shards.first { $0.tests.contains { $0.type == "LegacyTests" } })
        for shard in plan.shards where shard.index != legacy.index {
            #expect(shard.predictedSeconds <= 90 * 1.5, "shard \(shard.index) predicted \(shard.predictedSeconds) s")
        }
        // XCTest's clocks are wall time, so its four 30 s tests still add up to 120 s in the shard that runs them.
        #expect(legacy.predictedSeconds >= 120)
    }
}
