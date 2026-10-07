//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers naming every failed test of a package run once: under its failure record where one names it, and on its own where none does.
struct PackageShardUnrecordedFailureTests {
    /// The identifier `swift test list` would give the line `listed`.
    private static func test(_ listed: String) -> TestIdentifier {
        ((try? PackageShardPlanner.listed(listed)) ?? []).first ?? ((try? PackageShardPlanner.listed("Invalid.Invalid/invalid()")) ?? [])[0]
    }

    /// The stream's identifier for the test `swift test list` spells `listed`, escaped as JSON writes a slash.
    private static func streamID(_ listed: String) -> String {
        "\(listed)/AlphaTests.swift:3:6".replacingOccurrences(of: "/", with: #"\/"#)
    }

    private static func event(_ kind: String, _ listed: String, at instant: Double, issue: String? = nil) -> String {
        let issueField = issue.map { #""issue":\#($0),"# } ?? ""
        return #"{"kind":"event","payload":{\#(issueField)"instant":{"absolute":\#(instant),"since1970":0},"iteration":1,"kind":"\#(kind)","messages":[],"testID":"\#(streamID(listed))"},"version":"6.4.0"}"#
    }

    /// Declares, starts and ends `listed` in the stream, recording a failing issue before the ending.
    private static func failed(_ listed: String) -> [String] {
        [
            #"{"kind":"test","payload":{"id":"\#(streamID(listed))","isParameterized":false,"kind":"function","name":"x"},"version":"6.4.0"}"#,
            event("testStarted", listed, at: 1),
            event("issueRecorded", listed, at: 1.5, issue: #"{"isFailure":true,"isKnown":false,"severity":"error"}"#),
            event("testEnded", listed, at: 2),
        ]
    }

    /// The failure section: everything above the first shard line.
    private static func failureSection(_ rendered: String) -> Substring {
        rendered[..<(rendered.range(of: "\nshard 1:")?.lowerBound ?? rendered.endIndex)]
    }

    /// Two tests failed in the stream and the console kept one of their issue lines: the other has no record to be listed under, and is named on its own rather than left out of the answer.
    @Test func aFailedTestWhoseRecordWasLostIsStillNamed() {
        let recorded = Self.test("LibTests.AlphaTests/one()")
        let lost = Self.test("LibTests.AlphaTests/two()")
        let plan = PackageShardPlanner.plan(tests: [recorded, lost], shards: 1) { _ in nil }
        let record = RunTestFailure(name: "one()", location: "AlphaTests.swift:4", message: "Expectation failed: 1 == 2")
        var outcome = ShardOutcome(outcomes: RunTestOutcomes(), exitCode: 1, wallSeconds: 2, logPath: "log", failures: [record])
        outcome.eventStream = ShardEventStream.read((Self.failed("LibTests.AlphaTests/one()") + Self.failed("LibTests.AlphaTests/two()")).joined(separator: "\n"))

        let reconciliation = ShardMerge.reconcile(plan: plan, outcomes: [outcome])
        let section = Self.failureSection(ShardAnswerRenderer(swiftPackage: true).render(reconciliation, plan: plan))

        #expect(reconciliation.failed == [recorded, lost])
        #expect(section.components(separatedBy: lost.enumerated).count == 2)
        #expect(!section.contains(recorded.enumerated))
        #expect(section.contains("Expectation failed: 1 == 2"))
    }

    /// A test whose condition threw is recorded by the stream under its identifier, which names it: it is listed under that record and not a second time.
    @Test func aStreamRecordNamesItsTest() {
        let gated = Self.test("LibTests.GatedTests/gated()")
        let plan = PackageShardPlanner.plan(tests: [gated], shards: 1, conditional: [gated]) { _ in nil }
        let thrown = #""issue":{"isFailure":true,"isKnown":false,"severity":"error"},"kind":"issueRecorded","messages":[{"symbol":"fail","text":"Caught error: Boom()"}]"#
        var outcome = ShardOutcome(outcomes: RunTestOutcomes(), exitCode: 1, wallSeconds: 2, logPath: "log")
        outcome.eventStream = ShardEventStream.read([
            #"{"kind":"test","payload":{"id":"\#(Self.streamID("LibTests.GatedTests/gated()"))","isParameterized":false,"kind":"function","name":"gated()"},"version":0}"#,
            #"{"kind":"event","payload":{"instant":{"absolute":1,"since1970":0},\#(thrown),"testID":"\#(Self.streamID("LibTests.GatedTests/gated()"))"},"version":0}"#,
        ].joined(separator: "\n"))

        let reconciliation = ShardMerge.reconcile(plan: plan, outcomes: [outcome])
        let section = Self.failureSection(ShardAnswerRenderer(swiftPackage: true).render(reconciliation, plan: plan))

        #expect(reconciliation.failed == [gated])
        #expect(section.components(separatedBy: gated.enumerated).count == 2)
    }

    /// A display-named test's console record carries the literal, which names the test through the plan's display names: it is listed under that record and not a second time.
    @Test func aDisplayNamedRecordNamesItsTest() {
        let named = Self.test("LibTests.AlphaTests/readsItsOwnName()")
        let literal = #""The Test Reads Its Own Name""#
        let plan = PackageShardPlanner.plan(tests: [named], shards: 1, displayNames: [literal: [named]]) { _ in nil }
        var read = RunTestOutcomes()
        ["◇ Test \(literal) started.", "✘ Test \(literal) failed after 0.001 seconds with 1 issue."].forEach { read.read($0) }
        let record = RunTestFailure(name: literal, location: "AlphaTests.swift:9", message: "Expectation failed: 1 == 2")
        let outcome = ShardOutcome(outcomes: read, exitCode: 1, wallSeconds: 2, logPath: "log", failures: [record])

        let reconciliation = ShardMerge.reconcile(plan: plan, outcomes: [outcome])
        let section = Self.failureSection(ShardAnswerRenderer(swiftPackage: true).render(reconciliation, plan: plan))

        #expect(reconciliation.failed == [named])
        #expect(!section.contains(named.enumerated))
    }

    /// A display-named test that failed and then passed on a retry has a record under its literal that the retry overtook: the literal names the test, so the record is dropped rather than listed under `failed 0`.
    @Test func aDisplayNamedRecordARetryOvertookIsDropped() {
        let named = Self.test("LibTests.AlphaTests/readsItsOwnName()")
        let literal = #""The Test Reads Its Own Name""#
        let plan = PackageShardPlanner.plan(tests: [named], shards: 1, displayNames: [literal: [named]]) { _ in nil }
        var read = RunTestOutcomes()
        [
            "◇ Test run started.", "◇ Test \(literal) started.", "✘ Test \(literal) failed after 0.001 seconds with 1 issue.",
            "✘ Test run with 1 test in 1 suite failed after 0.002 seconds with 1 issue.",
            "◇ Test run started.", "◇ Test \(literal) started.", "✔ Test \(literal) passed after 0.001 seconds.",
            "✔ Test run with 1 test in 1 suite passed after 0.002 seconds.",
        ].forEach { read.read($0) }
        let record = RunTestFailure(name: literal, location: "AlphaTests.swift:9", message: "Expectation failed: 1 == 2")
        let outcome = ShardOutcome(outcomes: read, exitCode: 0, wallSeconds: 2, logPath: "log", failures: [record])

        let reconciliation = ShardMerge.reconcile(plan: plan, outcomes: [outcome])

        #expect(reconciliation.counts.failed == 0)
        #expect(reconciliation.counts.passed == 1)
        #expect(reconciliation.failures.isEmpty)
        #expect(reconciliation.notes.isEmpty)
    }

    /// A display name two shards' tests share names only the test of the shard that printed it: the other shard's test ended fine, and must not make the record of a test that failed and then crashed look overtaken.
    @Test func aDisplayNamedRecordIsNotOvertakenByAnotherShardsTest() {
        let passing = Self.test("LibTests.AlphaTests/readsItsOwnName()")
        let crashing = Self.test("LibTests.BetaTests/readsItsOwnName()")
        let literal = #""The Shared Name""#
        let plan = PackageShardPlanner.plan(tests: [passing, crashing], shards: 2, displayNames: [literal: [passing, crashing]]) { _ in nil }
        var passed = RunTestOutcomes()
        ["◇ Test \(literal) started.", "✔ Test \(literal) passed after 0.001 seconds."].forEach { passed.read($0) }
        var crashed = RunTestOutcomes()
        crashed.read("◇ Test \(literal) started.")
        let record = RunTestFailure(name: literal, location: "BetaTests.swift:9", message: "Expectation failed: 1 == 2")
        let ended = ShardOutcome(outcomes: passed, exitCode: 0, wallSeconds: 2, logPath: "log")
        let lost = ShardOutcome(outcomes: crashed, exitCode: 1, wallSeconds: 2, logPath: "log", failures: [record])
        let outcomes = plan.shards.map { $0.tests == [passing] ? ended : lost }

        let reconciliation = ShardMerge.reconcile(plan: plan, outcomes: outcomes)

        #expect(reconciliation.missing.map(\.test) == [crashing])
        #expect(reconciliation.failures.map(\.name) == [literal])
    }

    /// Two suites each fail a test called `same()` and the console kept one record for the bare name: it cannot say which suite printed it, so both tests are named on their own, each once.
    @Test func aBareNameRecordDoesNotCoverTwoSuites() {
        let alpha = Self.test("LibTests.AlphaTests/same()")
        let beta = Self.test("LibTests.BetaTests/same()")
        let plan = PackageShardPlanner.plan(tests: [alpha, beta], shards: 1) { _ in nil }
        let record = RunTestFailure(name: "same()", location: "AlphaTests.swift:4", message: "Expectation failed: 1 == 2")
        var outcome = ShardOutcome(outcomes: RunTestOutcomes(), exitCode: 1, wallSeconds: 2, logPath: "log", failures: [record])
        outcome.eventStream = ShardEventStream.read((Self.failed("LibTests.AlphaTests/same()") + Self.failed("LibTests.BetaTests/same()")).joined(separator: "\n"))

        let reconciliation = ShardMerge.reconcile(plan: plan, outcomes: [outcome])
        let section = Self.failureSection(ShardAnswerRenderer(swiftPackage: true).render(reconciliation, plan: plan))

        #expect(reconciliation.unrecordedFailures == [alpha, beta])
        #expect(section.components(separatedBy: alpha.enumerated).count == 2)
        #expect(section.components(separatedBy: beta.enumerated).count == 2)
    }
}
