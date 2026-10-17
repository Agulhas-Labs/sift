//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A failure the console lost and the event stream recorded carries the `↳` expansion lines the stream's issue holds, so the line that counts how many failures read one value counts it as it would a failure the console relayed.
struct RunStreamExpansionTests {
    private static func streamID(_ index: Int) -> String {
        #"LibTests.AlphaTests\/check\#(index)()\/AlphaTests.swift:3:6"#
    }

    /// A test the stream declares, starts, fails with `messages` as the testing library records them, and ends.
    private static func failing(_ index: Int, expression: String) -> [String] {
        let id = streamID(index)
        let messages = #"[{"symbol":"fail","text":"Expectation failed: \#(expression)"},{"symbol":"details","text":"\#(expression) → nil"},{"_indentation":1,"symbol":"details","text":"\#(subject(index)) → \#(index)"}]"#
        let issue = #""issue":{"isFailure":true,"isKnown":false,"severity":"error"},"#
        return [
            #"{"kind":"test","payload":{"id":"\#(id)","isParameterized":false,"kind":"function","name":"check\#(index)()"},"version":"6.4.0"}"#,
            #"{"kind":"event","payload":{"instant":{"absolute":1,"since1970":0},"iteration":1,"kind":"testStarted","messages":[],"testID":"\#(id)"},"version":"6.4.0"}"#,
            #"{"kind":"event","payload":{\#(issue)"instant":{"absolute":1.5,"since1970":0},"iteration":1,"kind":"issueRecorded","messages":\#(messages),"testID":"\#(id)"},"version":"6.4.0"}"#,
            #"{"kind":"event","payload":{"instant":{"absolute":2,"since1970":0},"iteration":1,"kind":"testEnded","messages":[],"testID":"\#(id)"},"version":"6.4.0"}"#,
        ]
    }

    /// A different subject for each test, so each is a signature of its own.
    private static func subject(_ index: Int) -> String {
        ["row", "view", "band", "note", "bay", "tray", "slot", "deck"][index]
    }

    private static func expression(_ index: Int) -> String {
        "Gizmo.soleElement(of: \(subject(index)), width: 393)"
    }

    /// What the console prints for a failing test it relayed whole.
    private static func relayed(_ index: Int) -> [String] {
        [
            "◇ Test check\(index)() started.",
            "✘ Test check\(index)() recorded an issue at Sprocket\(index)Tests.swift:\(index + 1):9: Expectation failed: \(expression(index))",
            "↳ \(expression(index)) → nil",
            "↳   \(subject(index)) → \(index)",
            "✘ Test check\(index)() failed after 0.001 seconds with 1 issue.",
        ]
    }

    private static func report(console: [String], stream: ShardEventStream) -> (report: RunReport, text: String) {
        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        filter.consume(Data((console.joined(separator: "\n") + "\n").utf8))
        filter.read(eventStream: stream)
        let report = filter.finish(exitCode: 1)
        let text = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Lib")).render(report, exitCode: 1, logURL: nil)
        return (report, text)
    }

    @Test func aFailureFoldedFromTheStreamCarriesItsExpansionLines() {
        let stream = ShardEventStream.read(Self.failing(0, expression: Self.expression(0)).joined(separator: "\n"))

        let read = Self.report(console: ["◇ Test run started.", "✘ Test run with 1 test in 1 suite failed after 0.001 seconds with 1 issue."], stream: stream)

        #expect(read.report.testFailures.map(\.name) == ["check0()"])
        #expect(read.report.testFailures.first?.message == "Expectation failed: \(Self.expression(0))")
        #expect(read.report.testFailures.first?.markedLines == ["\(Self.expression(0)) → nil", "row → 0"])
    }

    @Test func failuresFromTheStreamAreCountedWithTheConsolesInTheDominantLine() {
        let relayed = Array(0 ..< 5)
        let lost = Array(5 ..< 8)
        let stream = ShardEventStream.read((relayed + lost).flatMap { Self.failing($0, expression: Self.expression($0)) }.joined(separator: "\n"))
        let console = ["◇ Test run started."] + relayed.flatMap(Self.relayed)
            + ["✘ Test run with 8 tests in 1 suite failed after 0.001 seconds with 8 issues."]

        let read = Self.report(console: console, stream: stream)

        #expect(read.report.testFailures.count == 8)
        let failures = read.report.testFailures.map {
            RunFailureShape.Failure(name: $0.name, location: $0.location, message: $0.message, arguments: $0.arguments, note: $0.note, markedLines: $0.markedLines)
        }
        let line = RunFailureShape.of(failures, changedFiles: .of([])).dominantClass?.line
        #expect(line?.hasPrefix("  ↳ 8 of 8 failures read one and the same value (") == true)
    }

    /// The expectation as the source wrote it over several lines, which the stream keeps with its line breaks and indentation.
    private static var spread: String {
        "Gizmo.soleElement(\n                of: row,\n                width: 320\n            )?.label == \"x\""
    }

    private static var joined: String {
        #"Gizmo.soleElement(of: row, width: 320)?.label == "x""#
    }

    private static func json(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
    }

    /// A test that failed on `spread`, as the stream records it: the headline and each expansion line keep the breaks.
    private static func failingSpread(_ index: Int) -> [String] {
        let id = streamID(index)
        let messages = #"[{"symbol":"fail","text":"Expectation failed: \#(json(spread))"},{"symbol":"details","text":"\#(json(spread)) → nil"},{"_indentation":1,"symbol":"details","text":"row → 0"}]"#
        let issue = #""issue":{"isFailure":true,"isKnown":false,"severity":"error"},"#
        return [
            #"{"kind":"test","payload":{"id":"\#(id)","isParameterized":false,"kind":"function","name":"check\#(index)()"},"version":"6.4.0"}"#,
            #"{"kind":"event","payload":{"instant":{"absolute":1,"since1970":0},"iteration":1,"kind":"testStarted","messages":[],"testID":"\#(id)"},"version":"6.4.0"}"#,
            #"{"kind":"event","payload":{\#(issue)"instant":{"absolute":1.5,"since1970":0},"iteration":1,"kind":"issueRecorded","messages":\#(messages),"testID":"\#(id)"},"version":"6.4.0"}"#,
            #"{"kind":"event","payload":{"instant":{"absolute":2,"since1970":0},"iteration":1,"kind":"testEnded","messages":[],"testID":"\#(id)"},"version":"6.4.0"}"#,
        ]
    }

    /// What the console prints for a failing test it relayed whole, the headline over the same several lines.
    private static func relayedSpread(_ index: Int) -> [String] {
        [
            "◇ Test check\(index)() started.",
            "✘ Test check\(index)() recorded an issue at Sprocket\(index)Tests.swift:\(index + 1):9: Expectation failed: Gizmo.soleElement(",
            "                of: row,",
            "                width: 320",
            "            )?.label == \"x\"",
            "↳ \(joined) → nil",
            "↳   row → 0",
            "✘ Test check\(index)() failed after 0.001 seconds with 1 issue.",
        ]
    }

    @Test func aMultiLineHeadlineAndItsLinesFoldToOneLine() {
        let stream = ShardEventStream.read(Self.failingSpread(0).joined(separator: "\n"))
        let read = Self.report(console: ["◇ Test run started.", "✘ Test run with 1 test in 1 suite failed after 0.001 seconds with 1 issue."], stream: stream)

        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        filter.consume(Data((Self.relayedSpread(0) + ["✘ Test run with 1 test in 1 suite failed after 0.001 seconds with 1 issue."]).joined(separator: "\n").appending("\n").utf8))
        let console = filter.finish(exitCode: 1).testFailures.first

        #expect(read.report.testFailures.first?.message == "Expectation failed: \(Self.joined)")
        #expect(read.report.testFailures.first?.message == console?.message)
        #expect(read.report.testFailures.first?.markedLines == ["\(Self.joined) → nil", "row → 0"])
    }

    @Test func relayedAndFoldedFailuresOfAMultiLineExpectationReadAlike() throws {
        let relayed = Array(0 ..< 5)
        let lost = Array(5 ..< 8)
        let stream = ShardEventStream.read((relayed + lost).flatMap(Self.failingSpread).joined(separator: "\n"))
        let console = ["◇ Test run started."] + relayed.flatMap(Self.relayedSpread)
            + ["✘ Test run with 8 tests in 1 suite failed after 0.001 seconds with 8 issues."]
        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        filter.consume(Data((console.joined(separator: "\n") + "\n").utf8))
        filter.read(eventStream: stream)
        let report = filter.finish(exitCode: 1)
        let logURL = URL(fileURLWithPath: "/Users/dev/Lib/.sift/runs/run.log")
        let text = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Lib")).render(report, exitCode: 1, logURL: logURL)

        #expect(report.testFailures.count == 8)
        #expect(report.testFailures.allSatisfy { $0.message == "Expectation failed: \(Self.joined)" })
        #expect(!text.contains("                "))
        let receipt = try #require(text.split(separator: "\n").first { $0.contains(" lines in, ") })
        let out = try #require(receipt.components(separatedBy: " lines in, ").last?.split(separator: " ").first.flatMap { Int($0) })
        #expect(out == text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0))
        let failures = report.testFailures.map {
            RunFailureShape.Failure(name: $0.name, location: $0.location, message: $0.message, arguments: $0.arguments, note: $0.note, markedLines: $0.markedLines)
        }
        #expect(RunFailureShape.of(failures, changedFiles: .of([])).signatureCount == 1)
    }
}
