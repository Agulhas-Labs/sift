//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// One suite and one log, reconciled unsharded by ``RunReconciler`` and sharded by ``ShardMerge`` through a plan ``ShardPlanner`` built from the same inventory, must come to the same verdict.
///
/// Conditional tests are where the two drifted: the plan carried no notion of them, so a switched-off test read missing under `--shards` and undecided without.
@Suite(.temporaryDirectories)
struct ShardConditionalParityTests {
    private static func ended(_ name: String, _ word: String = "passed") -> [String] {
        ["Test \(name) started.", "Test \(name) \(word) after 0.001 seconds."]
    }

    private static var sharedLiteralWithAConditional: String {
        """
        import Testing

        struct AlphaTests {
            @Test("Alpha") func first() {}
        }

        struct BetaTests {
            @Test("Alpha") func second() {}
            @Test("Alpha", .enabled(if: true)) func third() {}
        }
        """
    }

    static let cases: [Case] = [
        Case(
            name: "a lone conditional test that reported nothing",
            source: """
            import Testing

            struct AlphaTests {
                @Test func first() {}
                @Test(.enabled(if: false)) func second() {}
            }
            """,
            reported: ended("first()")
        ),
        Case(
            name: "a lone conditional test claimed by its literal",
            source: """
            import Testing

            struct AlphaTests {
                @Test("Alpha", .enabled(if: true)) func first() {}
            }
            """,
            reported: ended("\"Alpha\"")
        ),
        Case(
            name: "a shared literal with a conditional member, one ending short",
            source: sharedLiteralWithAConditional,
            reported: ended("\"Alpha\"") + ended("\"Alpha\"")
        ),
        Case(
            name: "a shared literal with a conditional member, every one ended",
            source: sharedLiteralWithAConditional,
            reported: ended("\"Alpha\"") + ended("\"Alpha\"") + ended("\"Alpha\"")
        ),
        Case(
            name: "a shared literal with a conditional member, fewer endings than its unconditional members",
            source: sharedLiteralWithAConditional,
            reported: ended("\"Alpha\"")
        ),
        Case(
            name: "a function name a conditional test shares",
            source: """
            import Testing

            struct HopperGaugeTests {
                @Test func shoutingWorks() {}
            }

            struct PalletTests {
                @Test(.enabled(if: true)) func shoutingWorks() {}
            }
            """,
            reported: ended("shoutingWorks()")
        ),
        Case(
            name: "a literal only conditional tests share",
            source: """
            import Testing

            struct AlphaTests {
                @Test("Alpha", .enabled(if: true)) func first() {}
            }

            struct BetaTests {
                @Test("Alpha", .enabled(if: true)) func second() {}
            }
            """,
            reported: ended("\"Alpha\""),
            undecided: ["GizmoTests/AlphaTests/first()", "GizmoTests/BetaTests/second()"]
        ),
        Case(
            name: "a literal only conditional tests share, one ending short of them all",
            source: """
            import Testing

            struct AlphaTests {
                @Test("Alpha", .enabled(if: true)) func first() {}
            }

            struct BetaTests {
                @Test("Alpha", .enabled(if: true)) func second() {}
                @Test("Alpha", .enabled(if: true)) func third() {}
            }
            """,
            reported: ended("\"Alpha\"") + ended("\"Alpha\""),
            undecided: ["GizmoTests/AlphaTests/first()", "GizmoTests/BetaTests/second()", "GizmoTests/BetaTests/third()"]
        ),
        Case(
            name: "every test conditional and none reported",
            source: """
            import Testing

            struct AlphaTests {
                @Test(.enabled(if: false)) func first() {}
            }
            """,
            reported: ["Test run started."]
        ),
    ]

    private static func inventory(_ source: String) throws -> TestInventory {
        let root = try TemporaryDirectory.make("shard-parity")
        let store = try TestSources.makeStore()
        let parsed = try TestSources.parsed(source, path: "GizmoTests/AlphaTests.swift", in: root)
        try store.replaceFiles([parsed]) { path in
            (path.split(separator: "/").first.map(String.init) ?? path, false)
        }
        return try TestInventory.read(store: store, repositoryRoot: root)
    }

    private static func outcomes(_ lines: [String]) -> RunTestOutcomes {
        var outcomes = RunTestOutcomes()
        for line in lines {
            outcomes.read(line)
        }
        return outcomes
    }

    @Test(arguments: cases)
    func aShardedRunGivesTheVerdictTheUnshardedRunGives(_ suite: Case) throws {
        let inventory = try Self.inventory(suite.source)
        let unsharded = RunReconciler.reconcile(
            inventory: inventory,
            outcomes: Self.outcomes(suite.reported),
            scope: RunReconciliation.Scope(manifest: "Package.swift", targets: ["GizmoTests"], conditionalTargets: false, logPath: "run.log")
        )
        let plan = ShardPlanner.plan(
            tests: inventory.tests.compactMap(\.identifier),
            shards: 1,
            displayNames: inventory.displayNames,
            conditional: inventory.conditionalTests,
            duration: { _ in nil }
        )
        let sharded = ShardMerge.reconcile(
            plan: plan,
            outcomes: [ShardOutcome(outcomes: Self.outcomes(suite.reported), exitCode: 0, wallSeconds: 30, logPath: "/tmp/shard.log")]
        )

        #expect(sharded.counts == unsharded.counts)
        #expect(sharded.isGreen == unsharded.isGreen)
        #expect(sharded.undecided == unsharded.undecided)
        if let undecided = suite.undecided {
            #expect(unsharded.undecided.map(\.enumerated) == undecided)
        }
        #expect(sharded.missing.map(\.test) == unsharded.missing)
        #expect(sharded.shortfalls.map(\.sentence) == unsharded.shortfalls.map(\.sentence))
        #expect(sharded.undecidedInGroups == unsharded.undecidedInGroups)
        if let first = sharded.undecided.first {
            let rendered = ShardAnswerRenderer().render(sharded, plan: plan).components(separatedBy: "\n")
            let heading = sharded.undecidedInGroups.contains(first)
                ? "conditional and sharing a name whose endings cannot say which of them ran — counted in neither direction:"
                : "conditional and never reported — counted in neither direction:"
            #expect(rendered.contains(heading))
            #expect(rendered.contains("  \(first.enumerated)"))
        }
    }

    @Test(arguments: ["passed", "failed"])
    func aConditionalTestThatEndedInAnotherShardIsMissingFromItsOwnAndNamedAsRunningThere(_ word: String) throws {
        let inventory = try Self.inventory("""
        import Testing

        struct AlphaTests {
            @Test func first() {}
            @Test(.enabled(if: true)) func second() {}
        }
        """)
        let tests = inventory.tests.compactMap(\.identifier).sorted { $0.enumerated < $1.enumerated }
        let second = try #require(tests.first { $0.enumerated.hasSuffix("second()") })
        let first = try #require(tests.first { $0 != second })
        let plan = ShardPlan(
            shards: [
                ShardPlan.Shard(index: 1, tests: [first], predictedSeconds: 21),
                ShardPlan.Shard(index: 2, tests: [second], predictedSeconds: 21),
            ],
            requestedShards: 2,
            overheadSeconds: 20,
            estimatedTests: 0,
            estimatedSeconds: 1,
            displayNames: inventory.displayNames,
            conditional: inventory.conditionalTests,
            lowering: nil
        )
        let sharded = ShardMerge.reconcile(plan: plan, outcomes: [
            ShardOutcome(outcomes: Self.outcomes(Self.ended("first()") + Self.ended("second()", word)), exitCode: 0, wallSeconds: 30, logPath: "/tmp/shard-1.log"),
            ShardOutcome(outcomes: Self.outcomes([]), exitCode: 0, wallSeconds: 30, logPath: "/tmp/shard-2.log"),
        ])

        #expect(!sharded.isGreen)
        #expect(sharded.undecided.isEmpty)
        #expect(sharded.missing == [ShardReconciliation.Missing(shard: 2, test: second)])
        #expect(sharded.counts.expected == 2)
        #expect(sharded.counts.missing == 1)
        #expect(sharded.shards.map(\.recording.missing) == [0, 1])
        #expect(sharded.notes.contains { $0.hasPrefix("\(second.enumerated) reported nothing in shard 2") && $0.contains("ended in shard 1") })
    }

    private static func plan(_ shards: [[TestIdentifier]], inventory: TestInventory) -> ShardPlan {
        ShardPlan(
            shards: shards.enumerated().map { ShardPlan.Shard(index: $0.offset + 1, tests: $0.element, predictedSeconds: 21) },
            requestedShards: shards.count,
            overheadSeconds: 20,
            estimatedTests: 0,
            estimatedSeconds: 1,
            displayNames: inventory.displayNames,
            conditional: inventory.conditionalTests,
            lowering: nil
        )
    }

    @Test(arguments: ["passed", "failed"])
    func aConditionalTestWhoseLiteralEndedInAnotherShardIsMissingFromItsOwnAndNamedAsRunningThere(_ word: String) throws {
        let inventory = try Self.inventory("""
        import Testing

        struct AlphaTests {
            @Test func first() {}
            @Test("Beta", .enabled(if: true)) func second() {}
        }
        """)
        let tests = inventory.tests.compactMap(\.identifier)
        let second = try #require(tests.first { $0.enumerated.hasSuffix("second()") })
        let first = try #require(tests.first { $0 != second })
        let plan = Self.plan([[first], [second]], inventory: inventory)
        let sharded = ShardMerge.reconcile(plan: plan, outcomes: [
            ShardOutcome(outcomes: Self.outcomes(Self.ended("first()") + Self.ended("\"Beta\"", word)), exitCode: 0, wallSeconds: 30, logPath: "/tmp/shard-1.log"),
            ShardOutcome(outcomes: Self.outcomes([]), exitCode: 0, wallSeconds: 30, logPath: "/tmp/shard-2.log"),
        ])

        #expect(!sharded.isGreen)
        #expect(sharded.undecided.isEmpty)
        #expect(sharded.missing == [ShardReconciliation.Missing(shard: 2, test: second)])
        #expect(sharded.counts.expected == 2)
        #expect(sharded.counts.missing == 1)
        #expect(sharded.shards.map(\.recording.missing) == [0, 1])
        #expect(sharded.notes.contains { $0.hasPrefix("\(second.enumerated) reported nothing in shard 2") && $0.contains("ended in shard 1") })
        #expect(!sharded.notes.contains { $0.contains("named no test the shard was given") })
    }

    @Test
    func aLiteralGroupSplitAcrossShardsGivesTheVerdictTheUnshardedRunGives() throws {
        let inventory = try Self.inventory("""
        import Testing

        struct AlphaTests {
            @Test("Alpha", .enabled(if: true)) func first() {}
        }

        struct BetaTests {
            @Test("Alpha") func second() {}
        }
        """)
        let tests = inventory.tests.compactMap(\.identifier)
        let conditional = try #require(tests.first { $0.enumerated.hasSuffix("first()") })
        let unconditional = try #require(tests.first { $0 != conditional })
        let logs: [[String]] = [[], Self.ended("\"Alpha\"")]
        let unsharded = RunReconciler.reconcile(
            inventory: inventory,
            outcomes: Self.outcomes(logs.flatMap(\.self)),
            scope: RunReconciliation.Scope(manifest: "Package.swift", targets: ["GizmoTests"], conditionalTargets: false, logPath: "run.log")
        )
        let sharded = ShardMerge.reconcile(
            plan: Self.plan([[conditional], [unconditional]], inventory: inventory),
            outcomes: logs.enumerated().map {
                ShardOutcome(outcomes: Self.outcomes($0.element), exitCode: 0, wallSeconds: 30, logPath: "/tmp/shard-\($0.offset + 1).log")
            }
        )

        #expect(!unsharded.isGreen)
        #expect(sharded.counts == unsharded.counts)
        #expect(sharded.isGreen == unsharded.isGreen)
        #expect(sharded.undecided == unsharded.undecided)
        #expect(sharded.shortfalls.map(\.sentence) == unsharded.shortfalls.map(\.sentence))
        #expect(sharded.shortfalls.map(\.shard) == [1])
        #expect(sharded.shards.map(\.recording.missing) == [1, 0])
    }

    /// A conditional test in shard 1 and an unconditional one in shard 2 declaring the same literal, reconciled unsharded and sharded over what each shard's log printed.
    private static func splitLiteral(_ logs: [[String]], sourceLocation: SourceLocation = #_sourceLocation) throws -> SplitRun {
        let inventory = try inventory("""
        import Testing

        struct AlphaTests {
            @Test("Alpha", .enabled(if: true)) func first() {}
        }

        struct BetaTests {
            @Test("Alpha") func second() {}
        }
        """)
        let tests = inventory.tests.compactMap(\.identifier)
        let conditional = try #require(tests.first { $0.enumerated.hasSuffix("first()") }, sourceLocation: sourceLocation)
        let unconditional = try #require(tests.first { $0 != conditional }, sourceLocation: sourceLocation)
        let plan = plan([[conditional], [unconditional]], inventory: inventory)
        return SplitRun(
            conditional: conditional,
            unconditional: unconditional,
            unsharded: RunReconciler.reconcile(
                inventory: inventory,
                outcomes: outcomes(logs.flatMap(\.self)),
                scope: RunReconciliation.Scope(manifest: "Package.swift", targets: ["GizmoTests"], conditionalTargets: false, logPath: "run.log")
            ),
            sharded: ShardMerge.reconcile(
                plan: plan,
                outcomes: logs.enumerated().map {
                    ShardOutcome(outcomes: outcomes($0.element), exitCode: 0, wallSeconds: 30, logPath: "/tmp/shard-\($0.offset + 1).log")
                }
            ),
            plan: plan
        )
    }

    /// Two endings of a literal in the shard given one of its two declarers are one surplus, whichever way it happened: the unconditional test ran twice, or the conditional one ran in the wrong shard.
    ///
    /// It is counted once, with no name, and the conditional test stays undecided rather than owed a shortfall the surplus already explains.
    @Test
    func aSurplusOfASharedLiteralInTheShardGivenOneDeclarerIsOneDuplicateWithNoName() throws {
        let run = try Self.splitLiteral([[], Self.ended("\"Alpha\"") + Self.ended("\"Alpha\"")])
        let sharded = run.sharded

        #expect(!sharded.isGreen)
        #expect(sharded.counts.duplicated == 1)
        #expect(sharded.duplicated.isEmpty)
        #expect(sharded.shortfalls.isEmpty)
        #expect(sharded.missing.isEmpty)
        #expect(sharded.undecided == [run.conditional])
        let surplus = sharded.notes.filter { $0.hasPrefix("shard 2: \"Alpha\": the shard ended this name 1 time more") }
        #expect(surplus.count == 1)
        #expect(surplus.allSatisfy { $0.contains(run.conditional.enumerated) && $0.contains(run.unconditional.enumerated) })
        #expect(!ShardAnswerRenderer().render(sharded, plan: run.plan).contains("\(run.unconditional.enumerated) ended"))
        // Deliberate: the unsharded run reads the two endings as the group's two members.
        #expect(run.unsharded.isGreen)
    }

    /// A literal that ended nowhere has no ending that could be the conditional test's, so that test is undecided as a lone one is and the unconditional test is missing by name, which is what the unsharded run says of the same log.
    @Test
    func aConditionalTestWhoseSharedLiteralEndedNowhereIsUndecided() throws {
        let run = try Self.splitLiteral([[], []])

        #expect(run.sharded.missing == [ShardReconciliation.Missing(shard: 2, test: run.unconditional)])
        #expect(run.sharded.undecided == [run.conditional])
        #expect(run.sharded.shortfalls.isEmpty)
        #expect(run.sharded.counts == run.unsharded.counts)
        #expect(run.sharded.undecided == run.unsharded.undecided)
        #expect(run.sharded.missing.map(\.test) == run.unsharded.missing)
    }

    /// The literal ended once, in the conditional test's own shard, and the unconditional test was lost.
    ///
    /// The sharded run knows which shard was given which test, so it names the unconditional test missing; the unsharded run cannot, so it states one shortfall over the group. Same counts and verdict, deliberately different sentences.
    @Test
    func aLostUnconditionalTestIsNamedWhenShardedAndAShortfallWhenNot() throws {
        let run = try Self.splitLiteral([Self.ended("\"Alpha\""), []])

        #expect(run.sharded.missing == [ShardReconciliation.Missing(shard: 2, test: run.unconditional)])
        #expect(run.sharded.shortfalls.isEmpty)
        #expect(run.unsharded.missing.isEmpty)
        #expect(run.unsharded.shortfalls.map(\.sentence) == [
            "1 of these 2 never reported, and 1 of the 2 is conditional, so the log cannot say whether a conditional test was skipped or a test was lost",
        ])
        #expect(run.sharded.counts == run.unsharded.counts)
        #expect(run.sharded.isGreen == run.unsharded.isGreen)
    }

    /// Two conditional tests sharing a literal, split across shards, and one ending in the first shard: the sharded run knows the second never reported, and the unsharded run, which cannot say which of the two did, names both undecided rather than neither.
    @Test
    func anAllConditionalLiteralTheEndingsDoNotReachIsUndecidedInBothRuns() throws {
        let inventory = try Self.inventory("""
        import Testing

        struct AlphaTests {
            @Test("Alpha", .enabled(if: true)) func first() {}
        }

        struct BetaTests {
            @Test("Alpha", .enabled(if: true)) func second() {}
        }
        """)
        let tests = inventory.tests.compactMap(\.identifier).sorted { $0.enumerated < $1.enumerated }
        let first = try #require(tests.first)
        let second = try #require(tests.last)
        let logs: [[String]] = [Self.ended("\"Alpha\""), []]
        let unsharded = RunReconciler.reconcile(
            inventory: inventory,
            outcomes: Self.outcomes(logs.flatMap(\.self)),
            scope: RunReconciliation.Scope(manifest: "Package.swift", targets: ["GizmoTests"], conditionalTargets: false, logPath: "run.log")
        )
        let sharded = ShardMerge.reconcile(
            plan: Self.plan([[first], [second]], inventory: inventory),
            outcomes: logs.enumerated().map {
                ShardOutcome(outcomes: Self.outcomes($0.element), exitCode: 0, wallSeconds: 30, logPath: "/tmp/shard-\($0.offset + 1).log")
            }
        )

        #expect(sharded.undecided == [second])
        #expect(unsharded.undecided == [first, second])
        #expect(unsharded.notes.contains { $0.hasPrefix("\"Alpha\": 1 of the 2 conditional tests this name cannot tell apart reported nothing") })
        #expect(sharded.counts == unsharded.counts)
    }
}

/// Where a shared literal's endings were printed, and how both answers name the tests they could not reach.
extension ShardConditionalParityTests {
    /// An ending of a shared literal printed in a shard given none of its declarers is unattributed, which never reds, so it cannot count toward the group: the conditional test is still owed a shortfall in its own shard, as it is when that ending was never printed.
    @Test
    func anEndingOfASharedLiteralInAShardGivenNoDeclarerDoesNotExcuseTheShortfall() throws {
        let inventory = try Self.inventory("""
        import Testing

        struct AlphaTests {
            @Test("Alpha", .enabled(if: true)) func first() {}
            @Test func zeta() {}
        }

        struct BetaTests {
            @Test("Alpha") func second() {}
        }
        """)
        let tests = inventory.tests.compactMap(\.identifier)
        let conditional = try #require(tests.first { $0.enumerated.hasSuffix("first()") })
        let other = try #require(tests.first { $0.enumerated.hasSuffix("zeta()") })
        let unconditional = try #require(tests.first { $0.enumerated.hasSuffix("second()") })
        let logs: [[String]] = [[], Self.ended("\"Alpha\""), Self.ended("zeta()") + Self.ended("\"Alpha\"")]
        let sharded = ShardMerge.reconcile(
            plan: Self.plan([[conditional], [unconditional], [other]], inventory: inventory),
            outcomes: logs.enumerated().map {
                ShardOutcome(outcomes: Self.outcomes($0.element), exitCode: 0, wallSeconds: 30, logPath: "/tmp/shard-\($0.offset + 1).log")
            }
        )

        #expect(!sharded.isGreen)
        #expect(sharded.undecided.isEmpty)
        #expect(sharded.shortfalls.map(\.shard) == [1])
        #expect(sharded.counts.missing == 1)
    }

    /// Two conditional tests sharing a literal and one ending: both answers name them under a heading that says the count cannot tell which ran, and keep the heading for tests that never reported to the one that did not.
    @Test
    func theMembersOfAGroupTheEndingsDoNotReachAreNamedApartFromATestThatNeverReported() throws {
        let inventory = try Self.inventory("""
        import Testing

        struct AlphaTests {
            @Test("Alpha", .enabled(if: true)) func first() {}
        }

        struct BetaTests {
            @Test("Alpha", .enabled(if: true)) func second() {}
            @Test(.enabled(if: true)) func third() {}
        }
        """)
        let tests = inventory.tests.compactMap(\.identifier).sorted { $0.enumerated < $1.enumerated }
        let reported = Self.ended("\"Alpha\"")
        let unsharded = RunReconciler.reconcile(
            inventory: inventory,
            outcomes: Self.outcomes(reported),
            scope: RunReconciliation.Scope(manifest: "Package.swift", targets: ["GizmoTests"], conditionalTargets: false, logPath: "run.log")
        )
        let plan = Self.plan([tests], inventory: inventory)
        let sharded = ShardMerge.reconcile(
            plan: plan,
            outcomes: [ShardOutcome(outcomes: Self.outcomes(reported), exitCode: 0, wallSeconds: 30, logPath: "/tmp/shard.log")]
        )
        let lone = "conditional and never reported — counted in neither direction"
        let members = "conditional and sharing a name whose endings cannot say which of them ran — counted in neither direction"

        #expect(unsharded.undecided.map(\.enumerated) == ["GizmoTests/AlphaTests/first()", "GizmoTests/BetaTests/second()", "GizmoTests/BetaTests/third()"])
        #expect(sharded.undecided == unsharded.undecided)
        #expect(unsharded.undecidedInGroups.map(\.enumerated) == ["GizmoTests/AlphaTests/first()", "GizmoTests/BetaTests/second()"])
        #expect(sharded.undecidedInGroups == unsharded.undecidedInGroups)
        #expect(sharded.counts == unsharded.counts)

        let unshardedLines = RunReconciliationRenderer().render(unsharded).components(separatedBy: "\n")
        let shardedLines = ShardAnswerRenderer().render(sharded, plan: plan).components(separatedBy: "\n")
        for (lines, loneHeading, membersHeading) in [(unshardedLines, "\(lone) (1):", "\(members) (2):"), (shardedLines, "\(lone):", "\(members):")] {
            let loneAt = try #require(lines.firstIndex(of: loneHeading))
            let membersAt = try #require(lines.firstIndex(of: membersHeading))
            #expect(lines[loneAt + 1] == "  GizmoTests/BetaTests/third()")
            #expect(loneAt < membersAt)
            #expect(lines.count(where: { $0.hasPrefix("  GizmoTests/") }) == 3)
            #expect(Array(lines[(membersAt + 1)...].prefix(2)) == ["  GizmoTests/AlphaTests/first()", "  GizmoTests/BetaTests/second()"])
        }
    }
}

extension ShardConditionalParityTests {
    /// One suite split across two shards, reconciled both ways.
    struct SplitRun {
        let conditional: TestIdentifier
        let unconditional: TestIdentifier
        let unsharded: RunReconciliation
        let sharded: ShardReconciliation
        let plan: ShardPlan
    }

    /// A suite and the lines its run printed.
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let source: String
        let reported: [String]
        /// The tests both runs must name undecided, where the case pins them rather than only their agreeing.
        var undecided: [String]?

        var testDescription: String {
            name
        }
    }
}
