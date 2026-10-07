//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A SwiftPM package's shards: suites charged their observed wall-clock span, and a shard that lost tests diagnosed from what it left.
@Suite(.temporaryDirectories)
struct PackageShardCostAndLossTests {
    private static let alpha = test("LibTests.AlphaTests/testOne()")
    private static let beta = test("LibTests.BetaTests/testTwo()")

    /// The identifier `swift test list` would give the line `listed`.
    private static func test(_ listed: String) -> TestIdentifier {
        ((try? PackageShardPlanner.listed(listed)) ?? []).first ?? ((try? PackageShardPlanner.listed("Invalid.Invalid/invalid()")) ?? [])[0]
    }

    private static func event(_ kind: String, _ identifier: String, at instant: Double) -> String {
        #"{"kind":"event","payload":{"instant":{"absolute":\#(instant),"since1970":0},"kind":"\#(kind)","messages":[],"testID":"\#(identifier)"},"version":0}"#
    }

    @Test func aSuiteSpanRunsFromItsFirstStartToItsLastEndAndNeverSumsItsTests() {
        let stream = [
            #"{"kind":"test","payload":{"id":"LibTests.AlphaTests","kind":"suite"},"version":0}"#,
            Self.event("testStarted", #"LibTests.AlphaTests\/one()\/AlphaTests.swift:3:6"#, at: 10),
            Self.event("testStarted", #"LibTests.AlphaTests\/Inner\/two()\/AlphaTests.swift:6:10"#, at: 10.5),
            Self.event("testEnded", #"LibTests.AlphaTests\/one()\/AlphaTests.swift:3:6"#, at: 12),
            Self.event("testEnded", #"LibTests.AlphaTests\/Inner\/two()\/AlphaTests.swift:6:10"#, at: 12.5),
            Self.event("testStarted", #"LibTests.BetaTests\/cut()\/BetaTests.swift:3:6"#, at: 11),
            "not json",
        ].joined(separator: "\n")

        let spans = SuiteSpans.read(stream)

        // Two tests of 2s each overlapping: the suite held the process for 2.5s, not 4s; a suite that never ended has no span.
        #expect(spans == ["LibTests.AlphaTests": 2.5])
    }

    @Test func theEventStreamOptionIsTheOneThisSwiftTestNames() {
        #expect(SuiteSpans.outputOption(inHelp: "  --xunit-output <xunit-output>\n  --event-stream-output-path <event-stream-output-path>\n") == "--event-stream-output-path")
        #expect(SuiteSpans.outputOption(inHelp: "  --experimental-event-stream-output <path>\n") == "--experimental-event-stream-output")
        #expect(SuiteSpans.outputOption(inHelp: "  --xunit-output <xunit-output>\n") == nil)
    }

    @Test func aSuiteIsChargedItsSpanOverItsTestsSummedTime() {
        let tests = (1 ... 4).map { Self.test("LibTests.AlphaTests/test\($0)()") } + [Self.beta]
        let summed = PackageShardPlanner.plan(tests: tests, shards: 2) { _ in 3 }
        let spanned = PackageShardPlanner.plan(tests: tests, shards: 2, duration: { _ in 3 }, suiteSeconds: { $0 == "LibTests.AlphaTests" ? 4 : nil })

        #expect(summed.shards.map(\.predictedSeconds).sorted() == [5, 14])
        #expect(spanned.shards.map(\.predictedSeconds).sorted() == [5, 6])
        #expect(PackageShardPlanner.estimateNote(tests: [Self.alpha], duration: { _ in nil }, suiteSeconds: { _ in 1 }) == nil)
    }

    @Test func aShardsSuiteSpansAreOfferedToTheStoreUnderTheirOwnKeys() {
        let plan = PackageShardPlanner.plan(tests: [Self.alpha], shards: 1) { _ in nil }
        var read = RunTestOutcomes()
        read.read("✔ Test testOne() passed after 9.0 seconds.")
        var outcome = ShardOutcome(outcomes: read, exitCode: 0, wallSeconds: 2, logPath: "log")
        outcome.suiteSeconds = ["LibTests.AlphaTests": 1.5]

        let recording = ShardMerge.reconcile(plan: plan, outcomes: [outcome]).recording(forShard: 1)

        #expect(recording?.observations.contains(TestDurationStore.Timing(identifier: "suite LibTests.AlphaTests", seconds: 1.5)) == true)
        #expect(recording?.missing == 0)
    }

    @Test func aShardThatLostTestsNamesItsExitItsClosingLineAndItsKeptLog() throws {
        let plan = PackageShardPlanner.plan(tests: [Self.alpha, Self.beta], shards: 2) { _ in nil }
        let outcomes = plan.shards.map { shard in
            var read = RunTestOutcomes()
            guard shard.tests == [Self.alpha] else {
                return ShardOutcome(outcomes: read, exitCode: 139, wallSeconds: 1, logPath: "/runs/kept-run-b.log")
            }
            read.read("✔ Test testOne() passed after 0.1 seconds.")
            var outcome = ShardOutcome(outcomes: read, exitCode: 0, wallSeconds: 1, logPath: "/runs/run-a.log")
            outcome.closedWithRunSummary = true
            return outcome
        }
        let lost = try #require(plan.shards.first { $0.tests == [Self.beta] }).index
        let reconciliation = ShardMerge.reconcile(plan: plan, outcomes: outcomes)

        let answer = ShardAnswerRenderer(swiftPackage: true).render(reconciliation, plan: plan)
        let simulator = ShardAnswerRenderer().render(reconciliation, plan: plan)

        #expect(answer.contains("shard \(lost) lost 1 of 1: exit 139 (128 + signal 11, \(String(cString: strsignal(11))), if it was signalled) · no Swift Testing `Test run with …` line in its log · log kept at /runs/kept-run-b.log"))
        #expect(!answer.contains("lost 0"))
        #expect(!simulator.contains(" lost 1 of 1"))
    }

    @Test func aKeptLogOutlivesThePruningOfTheRunsAfterIt() throws {
        let root = try TemporaryDirectory.make("kept-log")
        let temporary = try TemporaryDirectory.make("kept-log-fallback")
        let first = try #require(RunLog.open(inDirectory: root, fallingBackTo: temporary))
        first.append(Data("lost".utf8))
        first.close()

        let kept = try #require(RunLog.keep(first.url.path))
        for _ in 0 ..< RunLog.keptLogs + 1 {
            try #require(RunLog.open(inDirectory: root, fallingBackTo: temporary)).close()
        }

        #expect(FileManager.default.contents(atPath: kept) == Data("lost".utf8))
        #expect(!FileManager.default.fileExists(atPath: first.url.path))
        #expect(RunLog.keep(root.appendingPathComponent("unrelated.log").path) == nil)
    }
}
