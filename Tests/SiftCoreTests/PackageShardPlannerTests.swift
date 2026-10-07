//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A SwiftPM package's shards: read from `swift test list`, partitioned by suite on known cost, and reconciled across shards.
struct PackageShardPlannerTests {
    /// The identifier `spelled` names, read the way `swift test list` output is, so a misspelt fixture fails its test rather than trapping.
    private static func test(_ spelled: String, sourceLocation: SourceLocation = #_sourceLocation) -> TestIdentifier {
        let parts = spelled.split(separator: "/")
        let listed = (try? PackageShardPlanner.listed("\(parts.first ?? "").\(parts.dropFirst().joined(separator: "/"))")) ?? []
        #expect(listed.count == 1, "not an identifier: \(spelled)", sourceLocation: sourceLocation)
        return listed.first ?? ((try? PackageShardPlanner.listed("Invalid.Invalid/invalid()")) ?? [])[0]
    }

    @Test func listingReadsBothFrameworksAndRefusesAnyOtherLine() throws {
        let listed = try PackageShardPlanner.listed("LibTests.LampTests/testThree\nLibTests.AlphaTests/testOne()\n")

        #expect(listed.map(\.enumerated) == ["LibTests/LampTests/testThree()", "LibTests/AlphaTests/testOne()"])
        #expect(throws: TestRunError.self) {
            try PackageShardPlanner.listed("warning: x\nLibTests.LampTests/testThree\n")
        }
    }

    @Test func everySuiteLandsInExactlyOneShardAndTheLongestAreSpread() {
        let seconds = ["Slow": 79.0, "Mid": 70, "Small": 10, "Tiny": 5]
        let tests = seconds.keys.flatMap { suite in [Self.test("T/\(suite)/a()"), Self.test("T/\(suite)/b()")] } + [Self.test("T/Unknown/c()")]
        let plan = PackageShardPlanner.plan(tests: tests, shards: 2) { seconds[$0.type].map { $0 / 2 } }
        let suites = plan.shards.map { Set($0.tests.map(PackageShardPlanner.suite(of:))) }

        #expect(plan.shards.count == 2)
        #expect(plan.testCount == tests.count)
        #expect(suites[0].isDisjoint(with: suites[1]))
        #expect(suites[0].union(suites[1]).count == 5)
        #expect(!(suites[0].contains("T.Slow") && suites[0].contains("T.Mid")))
        #expect(!(suites[1].contains("T.Slow") && suites[1].contains("T.Mid")))
        // Unknown is charged the median of the timed suites, 40s; longest first onto the lighter shard gives 79+10+5 and 70+40, each plus the 2s launch.
        #expect(plan.shards.map(\.predictedSeconds).sorted() == [96, 112])
    }

    @Test func theFilterSelectsItsSuitesAndNoSuiteThatMerelySharesAPrefix() throws {
        let pattern = PackageShardPlanner.filter(for: [Self.test("LibTests/AlphaTests/a()")])
        let regex = try Regex(pattern)

        #expect("LibTests.AlphaTests/a()".contains(regex))
        #expect(!("LibTests.AlphaTests" + "BetaTests/a()").contains(regex))
        #expect(!"DemoUnitTests.AlphaTests/a()".contains(regex))
    }

    @Test func aMissingShardAndATestEndedTwiceAreBothNamed() {
        let alpha = Self.test("LibTests/AlphaTests/testOne()")
        let beta = Self.test("LibTests/BetaTests/testTwo()")
        let gamma = Self.test("LibTests/LampTests/testThree()")
        let plan = PackageShardPlanner.plan(tests: [alpha, beta, gamma], shards: 3) { _ in nil }
        #expect(plan.shards.count == 3)
        var outcomes: [ShardOutcome] = []
        for shard in plan.shards {
            var read = RunTestOutcomes()
            if shard.tests == [alpha] {
                read.read("✔ Test testOne() passed after 0.1 seconds.")
                read.read("✔ Test testOne() passed after 0.1 seconds.")
            } else if shard.tests == [gamma] {
                read.read("Test Case '-[LibTests.LampTests testThree]' passed (0.1 seconds).")
            }
            outcomes.append(ShardOutcome(outcomes: read, exitCode: shard.tests == [beta] ? 137 : 0, wallSeconds: 1, logPath: "log"))
        }
        let merged = ShardMerge.reconcile(plan: plan, outcomes: outcomes)
        #expect(merged.counts.expected == 3)
        #expect(merged.missing.map(\.test) == [beta])
        #expect(merged.duplicated.map(\.test) == [alpha])
        #expect(!merged.isGreen)
    }
}
