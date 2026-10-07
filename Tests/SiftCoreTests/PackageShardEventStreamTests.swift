//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A SwiftPM package's shard reconciled from the Swift Testing event stream it wrote, with its console read only for XCTest.
struct PackageShardEventStreamTests {
    /// The identifier `swift test list` would give the line `listed`.
    private static func test(_ listed: String) -> TestIdentifier {
        ((try? PackageShardPlanner.listed(listed)) ?? []).first ?? ((try? PackageShardPlanner.listed("Invalid.Invalid/invalid()")) ?? [])[0]
    }

    /// The stream's identifier for the test `swift test list` spells `listed`, as the testing library writes it.
    private static func streamID(_ listed: String) -> String {
        "\(listed)/AlphaTests.swift:3:6".replacingOccurrences(of: "/", with: #"\/"#)
    }

    private static func declared(_ listed: String) -> String {
        #"{"kind":"test","payload":{"id":"\#(streamID(listed))","isParameterized":false,"kind":"function","name":"x"},"version":"6.4.0"}"#
    }

    private static func event(_ kind: String, _ listed: String, at instant: Double, iteration: Int? = 1, issue: String? = nil) -> String {
        let iterationField = iteration.map { #""iteration":\#($0),"# } ?? ""
        let issueField = issue.map { #""issue":\#($0),"# } ?? ""
        return #"{"kind":"event","payload":{\#(issueField)"instant":{"absolute":\#(instant),"since1970":0},\#(iterationField)"kind":"\#(kind)","messages":[],"testID":"\#(streamID(listed))"},"version":"6.4.0"}"#
    }

    /// Declares, starts and ends `listed`, recording a failing issue first where `fails`.
    private static func ran(_ listed: String, fails: Bool = false) -> [String] {
        [declared(listed), event("testStarted", listed, at: 1)]
            + (fails ? [event("issueRecorded", listed, at: 1.5, issue: #"{"isFailure":true,"isKnown":false,"severity":"error"}"#)] : [])
            + [event("testEnded", listed, at: 2)]
    }

    private static func console(_ lines: [String]) -> RunTestOutcomes {
        var read = RunTestOutcomes()
        lines.forEach { read.read($0) }
        return read
    }

    private static let listed = ["LibTests.AlphaTests/one()", "LibTests.AlphaTests/two()", "LibTests.AlphaTests/three()", "LibTests.AlphaTests/four()"]
    private static let legacy = test("LibTests.LegacyTests/testOne")

    @Test func aShardWhoseConsoleLostItsEndingsIsReconciledFromTheStreamAndCountsAStreamFailure() {
        let tests = Self.listed.map(Self.test) + [Self.legacy]
        let plan = PackageShardPlanner.plan(tests: tests, shards: 1) { _ in nil }
        // The console kept one Swift Testing ending of four and no failure line at all; XCTest's lines came through.
        let read = Self.console([
            "◇ Test run started.",
            "◇ Test one() started.",
            "◇ Test two() started.",
            "✔ Test one() passed after 0.001 seconds.",
            "Test Case '-[LibTests.LegacyTests testOne]' started.",
            "Test Case '-[LibTests.LegacyTests testOne]' passed (0.001 seconds).",
        ])
        let stream = (Self.listed.dropLast().flatMap { Self.ran($0) } + Self.ran("LibTests.AlphaTests/four()", fails: true)).joined(separator: "\n")
        var outcome = ShardOutcome(outcomes: read, exitCode: 1, wallSeconds: 2, logPath: "log")
        outcome.eventStream = ShardEventStream.read(stream)

        let reconciliation = ShardMerge.reconcile(plan: plan, outcomes: [outcome])

        #expect(reconciliation.counts.missing == 0)
        #expect(reconciliation.counts.ran == 5)
        #expect(reconciliation.counts.passed == 4)
        #expect(reconciliation.counts.failed == 1)
        #expect(reconciliation.failed == [Self.test("LibTests.AlphaTests/four()")])
        #expect(reconciliation.notes.isEmpty)
    }

    @Test func aStreamFailsOnlyOnAFailingIssueAndReadsSkipsCasesAndFileScopeTests() {
        let known = #"{"isFailure":false,"isKnown":true,"severity":"error"}"#
        let warning = #"{"isFailure":false,"isKnown":false,"severity":"warning"}"#
        let failing = #"{"isFailure":true,"isKnown":false,"severity":"error"}"#
        let stream = [
            Self.declared("LibTests.AlphaTests/known()"),
            Self.declared("LibTests.AlphaTests/warns()"),
            Self.declared("LibTests.AlphaTests/cases(_:)"),
            Self.declared("LibTests.AlphaTests/off()"),
            Self.declared("LibTests.shoutingWorks()"),
            Self.declared("LibTests.AlphaTests/lost()"),
            #"{"kind":"test","payload":{"id":"LibTests.AlphaTests","kind":"suite","name":"AlphaTests"},"version":"6.4.0"}"#,
            Self.event("issueRecorded", "LibTests.AlphaTests/known()", at: 1, issue: known),
            Self.event("testEnded", "LibTests.AlphaTests/known()", at: 2),
            Self.event("issueRecorded", "LibTests.AlphaTests/warns()", at: 1, issue: warning),
            Self.event("testEnded", "LibTests.AlphaTests/warns()", at: 2),
            // A parameterised test's own start and end carry no iteration, and its cases' issues carry 1.
            Self.event("testStarted", "LibTests.AlphaTests/cases(_:)", at: 1, iteration: nil),
            Self.event("issueRecorded", "LibTests.AlphaTests/cases(_:)", at: 1.5, issue: failing),
            Self.event("testEnded", "LibTests.AlphaTests/cases(_:)", at: 3, iteration: nil),
            Self.event("testSkipped", "LibTests.AlphaTests/off()", at: 1, iteration: nil),
            Self.event("testEnded", "LibTests.shoutingWorks()", at: 2),
            Self.event("testStarted", "LibTests.AlphaTests/lost()", at: 1),
            "not json",
        ].joined(separator: "\n")

        let read = ShardEventStream.read(stream)

        #expect(read.declared.count == 6)
        #expect(read.attempts[Self.test("LibTests.AlphaTests/known()")]?.map(\.ending) == [.passed])
        #expect(read.attempts[Self.test("LibTests.AlphaTests/warns()")]?.map(\.ending) == [.passed])
        #expect(read.attempts[Self.test("LibTests.AlphaTests/cases(_:)")] == [RunTestOutcomes.Attempt(ending: .failed, seconds: 2)])
        #expect(read.attempts[Self.test("LibTests.AlphaTests/off()")] == [RunTestOutcomes.Attempt(ending: .skipped)])
        #expect(read.attempts[Self.test("LibTests.shoutingWorks()")]?.map(\.ending) == [.passed])
        #expect(read.attempts[Self.test("LibTests.AlphaTests/lost()")] == nil)
    }

    @Test func aTestTheStreamEndedThatTheListingNeverNamedMakesTheRunRedByName() {
        let plan = PackageShardPlanner.plan(tests: Self.listed.map(Self.test), shards: 1) { _ in nil }
        let stream = (Self.listed + ["LibTests.AlphaTests/five()"]).flatMap { Self.ran($0) }.joined(separator: "\n")
        var outcome = ShardOutcome(outcomes: RunTestOutcomes(), exitCode: 0, wallSeconds: 2, logPath: "log")
        outcome.eventStream = ShardEventStream.read(stream)

        let reconciliation = ShardMerge.reconcile(plan: plan, outcomes: [outcome])
        let rendered = ShardAnswerRenderer(swiftPackage: true).render(reconciliation, plan: plan)

        #expect(reconciliation.counts.missing == 0)
        #expect(reconciliation.counts.passed == 4)
        #expect(reconciliation.unlisted == ["shard 1: LibTests/AlphaTests/five()"])
        #expect(!reconciliation.isGreen)
        #expect(reconciliation.exitCode == 1)
        #expect(rendered.hasPrefix("✘ sift test — 1 ran but not listed"))
        #expect(rendered.contains("  shard 1: LibTests/AlphaTests/five()"))
    }

    @Test func aFailedTestTheListingNeverNamedIsCountedInTheHeadlineAndItsSuiteIsInTheRerunHint() {
        let plan = PackageShardPlanner.plan(tests: Self.listed.map(Self.test), shards: 1) { _ in nil }
        let stream = (Self.ran("LibTests.AlphaTests/one()", fails: true) + Self.ran("LibTests.AlphaTests/two()") + Self.ran("LibTests.AlphaTests/three()")
            + Self.ran("LibTests.AlphaTests/four()") + Self.ran("LibTests.BetaTests/five()", fails: true)).joined(separator: "\n")
        var outcome = ShardOutcome(outcomes: RunTestOutcomes(), exitCode: 1, wallSeconds: 2, logPath: "log")
        outcome.eventStream = ShardEventStream.read(stream)

        let reconciliation = ShardMerge.reconcile(plan: plan, outcomes: [outcome])
        let rendered = ShardAnswerRenderer(swiftPackage: true).render(reconciliation, plan: plan)

        #expect(reconciliation.counts.failed == 2)
        #expect(reconciliation.failed.count == 2)
        #expect(rendered.contains("✘ sift test — 2 failed · 1 ran but not listed"), "\(rendered)")
        #expect(rendered.contains("re-run their suites alone:"), "\(rendered)")
        #expect(rendered.contains("AlphaTests") && rendered.contains("BetaTests"), "\(rendered)")
    }

    @Test func aShardWithNoStreamIsReadFromItsConsoleAndSaysSo() {
        let plan = PackageShardPlanner.plan(tests: [Self.test("LibTests.AlphaTests/one()"), Self.legacy], shards: 1) { _ in nil }
        let read = Self.console([
            "◇ Test one() started.",
            "✔ Test one() passed after 0.001 seconds.",
            "Test Case '-[LibTests.LegacyTests testOne]' started.",
            "Test Case '-[LibTests.LegacyTests testOne]' passed (0.001 seconds).",
        ])
        var outcome = ShardOutcome(outcomes: read, exitCode: 0, wallSeconds: 2, logPath: "log")
        outcome.eventStreamAbsence = "its event stream was missing or unreadable"
        var xctestOnly = ShardOutcome(outcomes: Self.console(["Test Case '-[LibTests.LegacyTests testOne]' passed (0.001 seconds)."]), exitCode: 0, wallSeconds: 1, logPath: "log")
        xctestOnly.eventStreamAbsence = "its event stream was missing or unreadable"

        let reconciliation = ShardMerge.reconcile(plan: plan, outcomes: [outcome])
        let quiet = ShardMerge.reconcile(plan: PackageShardPlanner.plan(tests: [Self.legacy], shards: 1) { _ in nil }, outcomes: [xctestOnly])

        #expect(reconciliation.counts.passed == 2)
        #expect(reconciliation.counts.missing == 0)
        #expect(reconciliation.notes == ["shard 1: its event stream was missing or unreadable, so Swift Testing was read from the console, which can drop lines under load"])
        #expect(quiet.notes.isEmpty)
    }

    /// A test the stream declared and started but never ended is missing, and keeps the run red even where the shard exited 0.
    @Test func aTestTheStreamDeclaredButNeverEndedIsMissingEvenAfterACleanExit() {
        let plan = PackageShardPlanner.plan(tests: Self.listed.map(Self.test), shards: 1) { _ in nil }
        let truncated = [Self.declared("LibTests.AlphaTests/four()"), Self.event("testStarted", "LibTests.AlphaTests/four()", at: 1)]
        let stream = (Self.listed.dropLast().flatMap { Self.ran($0) } + truncated).joined(separator: "\n")
        var outcome = ShardOutcome(outcomes: RunTestOutcomes(), exitCode: 0, wallSeconds: 2, logPath: "log")
        outcome.eventStream = ShardEventStream.read(stream)

        let reconciliation = ShardMerge.reconcile(plan: plan, outcomes: [outcome])

        #expect(reconciliation.counts.passed == 3)
        #expect(reconciliation.counts.missing == 1)
        #expect(!reconciliation.isGreen)
    }

    /// A test whose `.enabled(if:)` condition threw, or its suite's did, never starts, and the stream's failing issue is its one record: it fails red with its error rather than going undecided, which reads green.
    @Test func aTestWhoseConditionThrewFailsRedNamingTheError() {
        let gated = Self.test("LibTests.GatedTests/gated()")
        let plan = PackageShardPlanner.plan(tests: Self.listed.map(Self.test) + [gated], shards: 1, conditional: [gated]) { _ in nil }
        // As the testing library writes it: no iteration, no source location, the error in the message, and the suite's own issue beside its function's.
        let thrown = #""issue":{"isFailure":true,"isKnown":false,"severity":"error"},"kind":"issueRecorded","messages":[{"symbol":"fail","text":"Caught error: Boom()"}]"#
        let stream = (Self.listed.flatMap { Self.ran($0) } + [
            #"{"kind":"test","payload":{"id":"LibTests.GatedTests","kind":"suite","name":"GatedTests"},"version":0}"#,
            #"{"kind":"test","payload":{"id":"\#(Self.streamID("LibTests.GatedTests/gated()"))","isParameterized":false,"kind":"function","name":"gated()"},"version":0}"#,
            #"{"kind":"event","payload":{"instant":{"absolute":1,"since1970":0},\#(thrown),"testID":"LibTests.GatedTests"},"version":0}"#,
            #"{"kind":"event","payload":{"instant":{"absolute":1,"since1970":0},\#(thrown),"testID":"\#(Self.streamID("LibTests.GatedTests/gated()"))"},"version":0}"#,
        ]).joined(separator: "\n")
        var outcome = ShardOutcome(outcomes: RunTestOutcomes(), exitCode: 1, wallSeconds: 2, logPath: "log")
        outcome.eventStream = ShardEventStream.read(stream)

        let reconciliation = ShardMerge.reconcile(plan: plan, outcomes: [outcome])
        let rendered = ShardAnswerRenderer(swiftPackage: true).render(reconciliation, plan: plan)

        #expect(outcome.eventStream?.attempts[gated] == [RunTestOutcomes.Attempt(ending: .failed)])
        #expect(reconciliation.counts.failed == 1)
        #expect(reconciliation.counts.missing == 0)
        #expect(reconciliation.failed == [gated])
        #expect(reconciliation.undecided.isEmpty)
        #expect(reconciliation.unlisted.isEmpty)
        #expect(!reconciliation.isGreen)
        #expect(rendered.hasPrefix("✘ sift test — 1 failed"))
        #expect(rendered.contains(gated.enumerated))
        #expect(rendered.contains("Caught error: Boom()"))
    }

    /// Repeated, a parameterised test starts and ends once with no iteration while its cases and their issues are numbered: its ending is an attempt per iteration its cases reached, so a failure in a later iteration is kept, and a later pass settles it.
    @Test func aRepeatedParameterisedTestIsAnAttemptPerIterationItsCasesReached() {
        let repeated = Self.test("LibTests.AlphaTests/cases(x:)")
        let cut = Self.test("LibTests.AlphaTests/cut(x:)")
        let plan = PackageShardPlanner.plan(tests: Self.listed.map(Self.test) + [repeated, cut], shards: 1) { _ in nil }
        let failing = #""issue":{"isFailure":true,"isKnown":false,"severity":"error"},"#
        func declared(_ listed: String) -> String {
            #"{"kind":"test","payload":{"id":"\#(Self.streamID(listed))","isParameterized":true,"kind":"function","name":"x"},"version":0}"#
        }
        /// As the testing library writes it: the test's own start and end unnumbered, its cases' starts, ends and issues numbered.
        func event(_ kind: String, _ listed: String, at instant: Double, iteration: Int? = nil, issue: String = "") -> String {
            let iterationField = iteration.map { #""iteration":\#($0),"# } ?? ""
            return #"{"kind":"event","payload":{\#(issue)"instant":{"absolute":\#(instant),"since1970":0},\#(iterationField)"kind":"\#(kind)","messages":[],"testID":"\#(Self.streamID(listed))"},"version":0}"#
        }
        func iteration(_ number: Int, of listed: String, failing fails: Bool = false) -> [String] {
            [event("testCaseStarted", listed, at: Double(number), iteration: number)]
                + (fails ? [event("issueRecorded", listed, at: Double(number), iteration: number, issue: failing)] : [])
                + [event("testCaseEnded", listed, at: Double(number), iteration: number)]
        }
        let parameterised = [declared("LibTests.AlphaTests/cases(x:)"), event("testStarted", "LibTests.AlphaTests/cases(x:)", at: 1)]
            + iteration(1, of: "LibTests.AlphaTests/cases(x:)")
            + iteration(2, of: "LibTests.AlphaTests/cases(x:)", failing: true)
            + iteration(3, of: "LibTests.AlphaTests/cases(x:)")
            + [event("testEnded", "LibTests.AlphaTests/cases(x:)", at: 4.5)]
        // Cut short in its second iteration: it started, so its failing issue there is no condition that threw.
        let cutShort = [declared("LibTests.AlphaTests/cut(x:)"), event("testStarted", "LibTests.AlphaTests/cut(x:)", at: 1)]
            + iteration(1, of: "LibTests.AlphaTests/cut(x:)")
            + iteration(2, of: "LibTests.AlphaTests/cut(x:)", failing: true).dropLast()
        let stream = (Self.listed.flatMap { Self.ran($0) } + parameterised + cutShort).joined(separator: "\n")
        var outcome = ShardOutcome(outcomes: RunTestOutcomes(), exitCode: 1, wallSeconds: 5, logPath: "log")
        outcome.eventStream = ShardEventStream.read(stream)

        let reconciliation = ShardMerge.reconcile(plan: plan, outcomes: [outcome])
        let attempts = outcome.eventStream?.attempts[repeated] ?? []

        #expect(attempts == [
            RunTestOutcomes.Attempt(ending: .passed, seconds: 3.5, iteration: 1),
            RunTestOutcomes.Attempt(ending: .failed, iteration: 2),
            RunTestOutcomes.Attempt(ending: .passed, iteration: 3),
        ])
        #expect(RunTestOutcomes.repeatWithinAnIteration(of: attempts) == nil)
        #expect(outcome.eventStream?.attempts[cut] == nil)
        #expect(outcome.eventStream?.failedBeforeStarting.isEmpty == true)
        #expect(reconciliation.counts.passed == 5)
        #expect(reconciliation.counts.failed == 0)
        #expect(reconciliation.counts.missing == 1)
        #expect(reconciliation.duplicated.isEmpty)
    }
}
