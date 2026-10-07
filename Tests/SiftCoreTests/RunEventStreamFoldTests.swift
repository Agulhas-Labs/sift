//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A `sift run -- swift test` answer read with the Swift Testing event stream the run wrote beside its console, where SwiftPM's relay of the console loses lines.
@Suite(.temporaryDirectories)
struct RunEventStreamFoldTests {
    /// The stream's identifier for the test `swift test list` spells `listed`, as the testing library writes it.
    private static func streamID(_ listed: String) -> String {
        "\(listed)/AlphaTests.swift:3:6".replacingOccurrences(of: "/", with: #"\/"#)
    }

    private static func declared(_ listed: String, name: String, displayName: String? = nil) -> String {
        let display = displayName.map { #""displayName":"\#($0)","# } ?? ""
        return #"{"kind":"test","payload":{\#(display)"id":"\#(streamID(listed))","isParameterized":false,"kind":"function","name":"\#(name)"},"version":"6.4.0"}"#
    }

    private static func event(_ kind: String, _ listed: String, at instant: Double, issue: String? = nil, iteration: Int = 1) -> String {
        let issueField = issue.map { #""issue":\#($0),"# } ?? ""
        return #"{"kind":"event","payload":{\#(issueField)"instant":{"absolute":\#(instant),"since1970":0},"iteration":\#(iteration),"kind":"\#(kind)","messages":[],"testID":"\#(streamID(listed))"},"version":"6.4.0"}"#
    }

    /// Declares, starts and ends the test `listed` as the testing library would, recording a failing issue first where `fails`.
    private static func ran(_ listed: String, name: String, displayName: String? = nil, fails: Bool = false) -> [String] {
        [declared(listed, name: name, displayName: displayName), event("testStarted", listed, at: 1)]
            + (fails ? [event("issueRecorded", listed, at: 1.5, issue: #"{"isFailure":true,"isKnown":false,"severity":"error"}"#)] : [])
            + [event("testEnded", listed, at: 2)]
    }

    /// Four tests in one suite, the last failing, one of them display-named.
    private static let stream = ShardEventStream.read((
        ran("LibTests.AlphaTests/one()", name: "one()")
            + ran("LibTests.AlphaTests/two()", name: "two()", displayName: "Two things")
            + ran("LibTests.AlphaTests/three()", name: "three()")
            + ran("LibTests.AlphaTests/four()", name: "four()", fails: true)
    ).joined(separator: "\n"))

    /// The whole console of that run, as the testing library printed it before SwiftPM relayed it.
    private static let console = [
        "◇ Test run started.",
        "◇ Suite AlphaTests started.",
        "◇ Test one() started.",
        "◇ Test \"Two things\" started.",
        "◇ Test three() started.",
        "◇ Test four() started.",
        "✔ Test one() passed after 0.001 seconds.",
        "✔ Test \"Two things\" passed after 0.001 seconds.",
        "✔ Test three() passed after 0.001 seconds.",
        "✘ Test four() recorded an issue at AlphaTests.swift:9:5: Expectation failed: 1 == 2",
        "✘ Test four() failed after 0.001 seconds with 1 issue.",
        "✘ Suite AlphaTests failed after 0.001 seconds with 1 issue.",
        "✘ Test run with 4 tests in 1 suite failed after 0.001 seconds with 1 issue.",
    ]

    /// The report and the rendered answer `lines` read as a failing `swift test`'s console, with `stream` read beside it where there is one.
    private static func answer(_ lines: [String], stream: ShardEventStream?) -> (report: RunReport, text: String) {
        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        filter.consume(Data((lines.joined(separator: "\n") + "\n").utf8))
        if let stream {
            filter.read(eventStream: stream)
        }
        let report = filter.finish(exitCode: 1)
        let text = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Lib")).render(report, exitCode: 1, logURL: nil)
        return (report, text)
    }

    @Test func aConsoleThatLostEndingsAndAFailingTestsEveryLineIsCountedAndNamedFromTheStream() {
        // The relay dropped two passes and every line the failing test printed.
        let lossy = Self.console.filter { !$0.hasPrefix("✔ Test \"Two things\"") && !$0.hasPrefix("✔ Test three()") && !$0.contains("Test four()") }

        let read = Self.answer(lossy, stream: Self.stream)

        #expect(read.report.testFailures.map(\.name) == ["four()"])
        #expect(read.report.testOutcomes.lastEndings == ["one()": .passed, "\"Two things\"": .passed, "three()": .passed, "four()": .failed])
        #expect(read.report.testOutcomes.swiftTestingRuns.allSatisfy { $0.unfinishedStarts.values.allSatisfy { $0 == 0 } })
        let note = "  event stream: 4 Swift Testing endings, the console relayed 1 — the other 3 read from the stream"
        #expect(read.text.components(separatedBy: "\n").filter { $0 == note }.count == 1)
        #expect(read.text.contains("four()"))
        #expect(read.text.contains("recorded in the event stream"))
    }

    @Test func aConsoleThatLostOnlyTheFailingTestsIssueLineKeepsItsOwnFailureAndGainsNoStreamFailure() {
        let lossy = Self.console.filter { !$0.contains("recorded an issue") && !$0.hasPrefix("✔ Test one()") }

        let read = Self.answer(lossy, stream: Self.stream)

        #expect(read.report.testFailures.map(\.name) == ["four()"])
        #expect(read.report.testFailures.map(\.message) == ["failed with no message of its own — see the raw log"])
        #expect(read.report.eventStreamNote == "event stream: 4 Swift Testing endings, the console relayed 3 — the other 1 read from the stream")
    }

    @Test func aConsoleThatAgreesWithItsStreamReadsExactlyAsItDoesWithoutOne() {
        let without = Self.answer(Self.console, stream: nil)
        let with = Self.answer(Self.console, stream: Self.stream)

        #expect(with.text == without.text)
        #expect(with.report.eventStreamNote == nil)
        #expect(with.report.testOutcomes == without.report.testOutcomes)
    }

    /// A test whose condition threw never starts, and its console line is not one the filter reads: the stream's failing issue is its one record, and the answer names its error rather than saying the console relayed nothing.
    @Test func aTestWhoseConditionThrewIsListedWithTheStreamsMessage() {
        let thrown = #""issue":{"isFailure":true,"isKnown":false,"severity":"error"},"kind":"issueRecorded","messages":[{"symbol":"fail","text":"Caught error: Boom()"}]"#
        let stream = ShardEventStream.read((
            Self.ran("LibTests.AlphaTests/one()", name: "one()") + [
                Self.declared("LibTests.AlphaTests/gated()", name: "gated()"),
                #"{"kind":"event","payload":{"instant":{"absolute":1,"since1970":0},\#(thrown),"testID":"\#(Self.streamID("LibTests.AlphaTests/gated()"))"},"version":0}"#,
            ]
        ).joined(separator: "\n"))
        let console = [
            "◇ Test run started.",
            "◇ Test one() started.",
            "✔ Test one() passed after 0.001 seconds.",
            "✘ Test run with 2 tests in 1 suite failed after 0.001 seconds with 1 issue.",
        ]

        let read = Self.answer(console, stream: stream)

        #expect(read.report.testFailures.map(\.name) == ["gated()"])
        #expect(read.report.testFailures.map(\.message) == ["Caught error: Boom()"])
        #expect(read.text.contains("Caught error: Boom()"))
    }

    /// `swift test --maximum-repetitions 3` on two passing tests: each started three times and ended once on the console, as the toolchain prints it, and ended three times in the stream.
    @Test func aRepeatedRunsStreamAddsNoEndingAndNoNoteToAConsoleThatPrintsOneEndingPerTest() {
        let console = [
            "◇ Test run started.",
            "◇ Suite AlphaTests started.",
            "◇ Test one() started.",
            "◇ Test two() started.",
            "◇ Test one() started (repetition 2).",
            "◇ Test two() started (repetition 2).",
            "◇ Test one() started (repetition 3).",
            "◇ Test two() started (repetition 3).",
            "✔ Test one() passed after 0.001 seconds.",
            "✔ Test two() passed after 0.001 seconds.",
            "✔ Suite AlphaTests passed after 0.001 seconds.",
            "✔ Test run with 2 tests in 1 suite passed after 0.001 seconds.",
        ]
        let tests = ["one()", "two()"]
        let iterations = (1 ... 3).flatMap { iteration in
            tests.flatMap { test in
                ["testStarted", "testEnded"].map { Self.event($0, "LibTests.AlphaTests/\(test)", at: Double(iteration), iteration: iteration) }
            }
        }
        let repeated = ShardEventStream.read((tests.map { Self.declared("LibTests.AlphaTests/\($0)", name: $0) } + iterations).joined(separator: "\n"))
        #expect(repeated.attempts.values.map(\.count) == [3, 3])

        let without = Self.answer(console, stream: nil)
        let with = Self.answer(console, stream: repeated)

        #expect(with.report.eventStreamNote == nil)
        #expect(with.report.testOutcomes == without.report.testOutcomes)
        #expect(with.text == without.text)
    }

    @Test func anXCTestOnlyRunsStreamDeclaresNothingAndLeavesTheConsolesAnswerAlone() {
        let lossy = Array(Self.console.dropLast(4))
        let without = Self.answer(lossy, stream: nil)
        let with = Self.answer(lossy, stream: ShardEventStream.read(#"{"kind":"metadata","payload":{"glitch":"x"},"version":"6.4.0"}"#))

        #expect(with.text == without.text)
        #expect(with.report.eventStreamNote == nil)
    }

    @Test func aStreamShorterThanItsConsoleIsNamedAndTheConsolesCountsKept() {
        let short = ShardEventStream.read(Self.ran("LibTests.AlphaTests/one()", name: "one()").joined(separator: "\n"))

        let read = Self.answer(Self.console, stream: short)

        #expect(read.report.eventStreamNote == "event stream: 1 Swift Testing ending, the console relayed 4 — the tests and failures here are the console's")
        #expect(read.report.testFailures.map(\.name) == ["four()"])
    }

    @Test func onlyATestExecutingSwiftTestWithNoStreamOfItsCallersOwnIsGivenOne() {
        #expect(RunLauncher.asksForEventStream(["swift", "test", "--filter", "AlphaTests"], kind: .swiftTest))
        #expect(!RunLauncher.asksForEventStream(["swift", "test", "list"], kind: .swiftTest))
        #expect(!RunLauncher.asksForEventStream(["swift", "test", "--skip-build", "list"], kind: .swiftTest))
        #expect(RunLauncher.asksForEventStream(["swift", "test", "--filter", "list"], kind: .swiftTest))
        #expect(!RunLauncher.asksForEventStream(["swift", "build"], kind: .swiftBuild))
        for option in SuiteSpans.outputOptions {
            #expect(!RunLauncher.asksForEventStream(["swift", "test", option, ".sift/events.jsonl"], kind: .swiftTest))
            #expect(!RunLauncher.asksForEventStream(["swift", "test", "\(option)=.sift/events.jsonl"], kind: .swiftTest))
        }
    }

    @Test func theStreamsOptionGoesStraightAfterTestAndItsDirectoryIsRemovedOnceRead() throws {
        let root = try TemporaryDirectory.make("run-event-stream")
        let streams = EventStreamDirectory(option: "--event-stream-output-path", directory: root.appendingPathComponent("run-events/one", isDirectory: true))
        try FileManager.default.createDirectory(at: streams.directory, withIntermediateDirectories: true)
        let started = RunLauncher.arguments(["swift", "test", "--filter", "AlphaTests", "--", "extra"], writingTo: streams)
        let path = streams.directory.appendingPathComponent(RunLauncher.eventStreamFile).path
        #expect(started == ["swift", "test", "--event-stream-output-path", path, "--filter", "AlphaTests", "--", "extra"])
        try "{}\n".write(toFile: path, atomically: true, encoding: .utf8)

        #expect(streams.read(RunLauncher.eventStreamFile) == "{}\n")
        streams.remove()

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("run-events").path))
    }

    /// A run killed before it removed its streams leaves them for the next run to sweep once they are past any real run's length, while a directory a concurrent run is still writing stays.
    ///
    /// Asked of a `swift test` offering no option, so nothing is made: the sweep is owed whether or not this run gets a stream of its own.
    @Test func aDirectoryAKilledRunLeftIsSweptByTheNextWhileAFreshOneStays() throws {
        let root = try TemporaryDirectory.make("run-event-sweep")
        let parent = SiftPaths.cache(in: root).appendingPathComponent("run-events", isDirectory: true)
        let abandoned = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let live = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        for directory in [abandoned, live] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "{}\n".write(to: directory.appendingPathComponent(RunLauncher.eventStreamFile), atomically: true, encoding: .utf8)
        }
        let longAgo = Date().addingTimeInterval(-EventStreamDirectory.abandonedAge - 60)
        try FileManager.default.setAttributes([.creationDate: longAgo], ofItemAtPath: abandoned.path)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-60)], ofItemAtPath: live.path)

        #expect(EventStreamDirectory.make(in: root, for: "run-events", asking: ["/usr/bin/true", "test"]) == nil)

        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: live.appendingPathComponent(RunLauncher.eventStreamFile).path))
    }

    /// A directory that cannot be made is no directory to hand out: a file where the parent would be leaves `make` nothing to return, even for a `swift test` that offers the option.
    @Test func aStreamDirectoryThatCannotBeMadeIsNotOffered() throws {
        let root = try TemporaryDirectory.make("run-event-blocked")
        try FileManager.default.createDirectory(at: SiftPaths.cache(in: root), withIntermediateDirectories: true)
        try "in the way".write(to: SiftPaths.cache(in: root).appendingPathComponent("run-events"), atomically: true, encoding: .utf8)
        let swift = root.appendingPathComponent("swift")
        try "#!/bin/sh\necho '  --event-stream-output-path <path>'\n".write(to: swift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)

        #expect(EventStreamDirectory.make(in: root, for: "run-events", asking: [swift.path, "test"]) == nil)
    }

    /// A help that outlasts the probe's deadline is ended and read as no option: the run goes on unasked rather than waiting on it.
    @Test func aHelpThatOutlastsTheProbesDeadlineIsEndedAndTheOptionTakenAsUnavailable() throws {
        let root = try TemporaryDirectory.make("run-event-slow-help")
        let swift = root.appendingPathComponent("swift")
        try "#!/bin/sh\nsleep 30\necho '  --event-stream-output-path <path>'\n".write(to: swift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)

        let started = Date()
        let made = EventStreamDirectory.make(in: root, for: "run-events", asking: [swift.path, "test"], probeDeadline: 0.5)

        #expect(made == nil)
        #expect(Date().timeIntervalSince(started) < 10)
    }
}
