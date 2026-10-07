//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A SwiftPM package planned from a duration store shaped like a real one: predictions in wall seconds, and the heavy suites kept apart.
@Suite(.temporaryDirectories)
struct PackageShardWallCostTests {
    /// Each suite's recorded span, in the proportions a real package's store held: one long serialized suite, a dozen heavy ones that ran beside each other, a few light ones.
    private static let spans: [String: Double] = [
        "LongTests": 117.6, "GizmoTests": 74.3, "LampTests": 63.9, "KettleTests": 61.4, "PalletTests": 60.6,
        "ToteStackTests": 53.4, "WidgetTests": 52.6, "DepotStoreTests": 51.6, "HopperGaugeTests": 51.1,
        "ZonePickTests": 51.1, "ConveyorBeltTests": 49.9, "BinLabelTests": 49.9, "AlphaTests": 8.2, "BetaTests": 3.1,
    ]

    /// Each test's own clock, which under in-process parallelism counts the time it waited, so three tests of one suite each read nearly the suite's whole span; `LegacyTests` has no span, as an XCTest suite has none.
    private static let clocks: [String: Double] = [
        "LongTests/one()": 39, "LongTests/two()": 39, "LongTests/three()": 39,
        "GizmoTests/one()": 70, "GizmoTests/two()": 70, "GizmoTests/three()": 70,
        "ToteStackTests/one()": 53.4, "ToteStackTests/two()": 53.3, "ToteStackTests/three()": 53.2,
        "LampTests/one()": 53.9, "LegacyTests/one()": 4, "LegacyTests/two()": 5,
    ]

    /// The store file those spans and clocks make, in the shape `TestDurationStore` writes.
    private static func storeFile() throws -> Data {
        let date = ISO8601DateFormatter().string(from: Date())
        var tests: [String: [[String: Any]]] = [:]
        for (suite, seconds) in spans {
            tests[SuiteSpans.storeKey(for: "LibTests.\(suite)")] = [["date": date, "seconds": seconds]]
        }
        for (test, seconds) in clocks {
            tests["LibTests/\(test)"] = [["date": date, "seconds": seconds]]
        }
        return try JSONSerialization.data(withJSONObject: ["tests": tests, "version": 1])
    }

    @Test func aStoreOfOverlappingSpansIsPlannedInWallSecondsWithTheHeavySuitesApart() throws {
        let root = try TemporaryDirectory.make("wall-cost")
        let file = TestDurationStore.fileURL(in: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.storeFile().write(to: file)
        let durations = TestDurationStore(repositoryRoot: root)
        let names = Set(Self.spans.keys.map { "\($0)/one()" } + Self.clocks.keys)
        let tests = try PackageShardPlanner.listed(names.sorted().map { "LibTests.\($0)" }.joined(separator: "\n"))

        let plan = PackageShardPlanner.plan(
            tests: tests,
            shards: 3,
            duration: { durations.median(for: $0.enumerated) },
            suiteSeconds: { durations.median(for: SuiteSpans.storeKey(for: $0)) }
        )
        let suites = plan.shards.map { Set($0.tests.map(\.type)) }
        let longest = suites.map { $0.compactMap { Self.spans[$0] }.max() ?? 0 }

        #expect(plan.shards.count == 3)
        // The serialized suite outlasts everything else, so nothing heavy may wait behind it.
        let long = try #require(suites.first { $0.contains("LongTests") })
        #expect(long.filter { (Self.spans[$0] ?? 0) >= 45 } == ["LongTests"])
        #expect(Set(["LongTests", "GizmoTests", "LampTests"].compactMap { name in suites.firstIndex { $0.contains(name) } }).count == 3)
        // Summed spans would predict every shard at twice the longest suite and more; a shard runs no shorter than its own longest suite, and in wall seconds none runs much longer than the longest of all.
        for (predicted, floor) in zip(plan.shards.map(\.predictedSeconds), longest) {
            #expect(predicted >= floor)
            #expect(predicted <= 117.6 * 1.5)
        }
    }
}
