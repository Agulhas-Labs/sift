//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a `swift test` that named several `--filter`s where one matched no test and the others did: SwiftPM runs the others' tests, prints their pass and exits 0, so the one that matched nothing drops out of a gate unseen.
///
/// `swift-test-filter-one-unmatched` is a real capture, console and event stream: `Fixtures/RunOutput/PROVENANCE.md` says how it was taken.
struct RunUnmatchedFilterTests {
    /// The capture's own invocation: a function's name, a pattern no test carries, and one only a test's source location matches.
    private static let arguments = ["swift", "test", "--filter", "aLogWithNoBannerIsNotAZero", "--filter", "NothingLikeThis", "--filter", #"RunTotalsLineTests\.swift:35:"#]

    @Test
    func aFilterOfSeveralThatMatchedNothingIsNamedAndIsNoPass() throws {
        let selector = try #require(RunTestSelector.named(in: Self.arguments))
        let report = try Self.report(invokedAs: Self.arguments, streamed: true)

        let answer = Self.answer(report, selector: selector)
        let lines = answer.split(separator: "\n").map(String.init)
        #expect(lines.first == "✘ swift test — no test matched --filter NothingLikeThis — 1 of 3 filters (the command exited 0; sift run exits 4)")
        let totals = try #require(lines.first { $0.hasPrefix("totals: ") })
        #expect(totals.hasPrefix("totals: ✘ no test matched --filter NothingLikeThis — 1 of 3 filters · "))
        #expect(!totals.contains("passed"))
        #expect(selector.ownExitCode(report, exitCode: 0) == RunTestSelector.exitCode)
        let outcome = RunOutcome(kind: .swiftTest, logKey: "swift test", exitCode: 0, report: report, log: nil, repositoryRoot: nil)
        #expect(!outcome.provedGreen(testBundles: .undetermined, selector: selector))
    }

    /// The same run with only the filters that matched keeps its pass: a pattern that matched only a test's `/File.swift:line:column` matched.
    @Test
    func filtersThatEachMatchedATestKeepThePass() throws {
        let arguments = ["swift", "test", "--filter", "aLogWithNoBannerIsNotAZero", "--filter", #"RunTotalsLineTests\.swift:35:"#]
        let selector = try #require(RunTestSelector.named(in: arguments))
        let report = try Self.report(invokedAs: arguments, streamed: true)

        #expect(Self.answer(report, selector: selector).hasPrefix("✔ swift test"))
        #expect(selector.ownExitCode(report, exitCode: 0) == nil)
    }

    /// Without the event stream nothing names the Swift Testing tests a pattern is matched against, so the run is not judged.
    @Test
    func aSwiftTestingRunWithNoStreamIsNotJudged() throws {
        let selector = try #require(RunTestSelector.named(in: Self.arguments))
        let report = try Self.report(invokedAs: Self.arguments, streamed: false)

        #expect(Self.answer(report, selector: selector).hasPrefix("✔ swift test"))
        #expect(selector.ownExitCode(report, exitCode: 0) == nil)
    }

    /// An XCTest is matched as SwiftPM matches it, `Module.Class/method`, and never by its class alone: a pattern anchored on the class runs nothing, so it is the one named.
    @Test
    func anXCTestFilterOfSeveralThatMatchedNothingIsNamed() throws {
        let arguments = ["swift", "test", "--filter", "ProbeTests.XCAlphaTests/testA$", "--filter", "XCAlphaTests$"]
        let selector = try #require(RunTestSelector.named(in: arguments))
        let report = Self.xctestReport(["-[ProbeTests.XCAlphaTests testA]"], invokedAs: arguments)
        let headline = Self.answer(report, selector: selector).split(separator: "\n").first.map(String.init)

        #expect(headline == "✘ swift test — no test matched --filter XCAlphaTests$ — 1 of 2 filters (the command exited 0; sift run exits 4)")
        #expect(selector.ownExitCode(report, exitCode: 0) == RunTestSelector.exitCode)
    }

    /// A Swift Testing pattern only a suite's id matches runs none of its tests, even beside a filter that ran one of them, so it is the one named.
    @Test
    func aFilterOnlyASuiteMatchedIsNamed() throws {
        let arguments = ["swift", "test", "--filter", "aLogWithNoBannerIsNotAZero", "--filter", "RunTestSelectorTests$"]
        let selector = try #require(RunTestSelector.named(in: arguments))
        let report = try Self.report(invokedAs: arguments, streamed: true)
        let headline = Self.answer(report, selector: selector).split(separator: "\n").first.map(String.init)

        #expect(headline == "✘ swift test — no test matched --filter RunTestSelectorTests$ — 1 of 2 filters (the command exited 0; sift run exits 4)")
        #expect(selector.ownExitCode(report, exitCode: 0) == RunTestSelector.exitCode)
    }

    /// One `--filter` is never judged here: a single pattern that matched nothing ran nothing, which ``RunTestSelector/matchedNothing(_:exitCode:)`` answers, so one the identifiers do not show matching is a reading this cannot trust.
    @Test
    func aSingleFilterIsNotJudged() throws {
        let arguments = ["swift", "test", "--filter", "NothingLikeThis"]
        let selector = try #require(RunTestSelector.named(in: arguments))
        let report = try Self.report(invokedAs: arguments, streamed: true)

        #expect(selector.unmatchedFilters(report, exitCode: 0).isEmpty)
        #expect(selector.ownExitCode(report, exitCode: 0) == nil)
        #expect(Self.answer(report, selector: selector).hasPrefix("✔ swift test"))
    }

    /// An `@objc`-renamed XCTest class logs under its Objective-C name with no module, while SwiftPM matches its Swift name, so a filter that ran it is never named, alone or beside one that matched.
    @Test(arguments: [
        ["SwiftNamedTests"],
        ["SwiftNamedTests", "ProbeTests.XCAlphaTests/testA$"],
    ])
    func anObjCRenamedXCTestIsNotJudged(patterns: [String]) throws {
        let arguments = ["swift", "test"] + patterns.flatMap { ["--filter", $0] }
        let selector = try #require(RunTestSelector.named(in: arguments))
        let report = Self.xctestReport(["-[ProbeTests.XCAlphaTests testA]", "-[RenamedObjCTests testRenamed]"], invokedAs: arguments)

        #expect(selector.unmatchedFilters(report, exitCode: 0).isEmpty)
        #expect(selector.ownExitCode(report, exitCode: 0) == nil)
        #expect(Self.answer(report, selector: selector).hasPrefix("✔ swift test"))
    }

    /// A run that did not exit 0, or that printed a failure, already answers ✘ on its own, so its filters are not judged.
    @Test
    func aRunThatFailedIsNotJudged() throws {
        let selector = try #require(RunTestSelector.named(in: Self.arguments))
        let report = try Self.report(invokedAs: Self.arguments, streamed: true)
        #expect(selector.unmatchedFilters(report, exitCode: 1).isEmpty)

        let arguments = ["swift", "test", "--filter", "ProbeTests.XCAlphaTests/testA$", "--filter", "NothingLikeThis"]
        let failing = Self.xctestReport(["-[ProbeTests.XCAlphaTests testA]"], failing: true, invokedAs: arguments)
        #expect(try #require(RunTestSelector.named(in: arguments)).unmatchedFilters(failing, exitCode: 0).isEmpty)
    }

    /// `--parallel` prints no line for an XCTest it ran, so what the run declared is not known and its filters are not judged.
    @Test
    func aParallelRunIsNotJudged() throws {
        let arguments = Self.arguments + ["--parallel"]
        let selector = try #require(RunTestSelector.named(in: arguments))
        let report = try Self.report(invokedAs: arguments, streamed: true)

        #expect(selector.unmatchedFilters(report, exitCode: 0).isEmpty)
        #expect(selector.ownExitCode(report, exitCode: 0) == nil)
    }

    /// An XCTest-only console that ran each of `names` in one bundle and passed, or failed the first where `failing`, read as the launcher reads it after an exit of 0.
    private static func xctestReport(_ names: [String], failing: Bool = false, invokedAs arguments: [String]) -> RunReport {
        var lines = [
            "Test Suite 'Selected tests' started at 2000-01-01 12:00:00.346.",
            "Test Suite 'ProbeTests.xctest' started at 2000-01-01 12:00:00.346.",
        ]
        for (index, name) in names.enumerated() {
            lines.append("Test Case '\(name)' started.")
            if failing, index == 0 {
                lines.append("/Users/dev/Probe/Tests/ProbeTests/T.swift:4: error: \(name) : XCTAssertTrue failed")
                lines.append("Test Case '\(name)' failed (0.001 seconds).")
            } else {
                lines.append("Test Case '\(name)' passed (0.000 seconds).")
            }
        }
        let verdict = failing ? "failed" : "passed"
        let tally = "\t Executed \(names.count) tests, with \(failing ? 1 : 0) failures (0 unexpected) in 0.001 (0.001) seconds"
        lines += [
            "Test Suite 'ProbeTests.xctest' \(verdict) at 2000-01-01 12:00:00.347.",
            tally,
            "Test Suite 'Selected tests' \(verdict) at 2000-01-01 12:00:00.347.",
            tally,
        ]
        var filter = RunOutputFilter(invokedAs: arguments)
        filter.consume(Data((lines.joined(separator: "\n") + "\n").utf8))
        return filter.finish(exitCode: 0)
    }

    /// The capture's console read as the launcher reads it, with its event stream beside it where `streamed`.
    private static func report(invokedAs arguments: [String], streamed: Bool, sourceLocation: SourceLocation = #_sourceLocation) throws -> RunReport {
        var filter = RunOutputFilter(invokedAs: arguments)
        try filter.consume(Data(TestSources.runOutput("swift-test-filter-one-unmatched").utf8))
        if streamed {
            let stream = try TestSources.runOutputData("swift-test-filter-one-unmatched", extension: "jsonl")
            try filter.read(eventStream: ShardEventStream.read(#require(String(bytes: stream, encoding: .utf8), sourceLocation: sourceLocation)))
        }
        return filter.finish(exitCode: 0)
    }

    private static func answer(_ report: RunReport, selector: RunTestSelector) -> String {
        RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Sift"), selector: selector)
            .render(report, exitCode: 0, logURL: nil)
    }
}
