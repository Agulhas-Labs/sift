//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Inside the crashed test's stretch of the log, a trap whose location lies in the source of a test the event stream started and never ended leads; every other trap there follows, unranked.
struct RunTestCrashTrapRankTests {
    private static var capture: String {
        "swift-test-crash-st-trap-in-test"
    }

    private static var trap: String {
        "PalletTests/Stacking.swift:9: Fatal error: real"
    }

    private static var lookalike: String {
        "Shelf/Rack.swift:9: Fatal error: look-alike"
    }

    /// The captured parallel run: `topples()` traps at its own line 9 while `stacks()`, `zlifts()` and `loads()` print look-alikes, two of them relayed after the trap, and `loads()` is still running when the process dies.
    @Test
    func theTrapInTheUnfinishedTestsOwnSourceLeads() throws {
        let report = try Self.report(Self.log(), stream: true)

        #expect(report.testCrash?.unfinished == ["loads()", "topples()"])
        #expect(report.testCrash?.traps.first == Self.trap)
        #expect(report.testCrash?.traps.count == 6)
        let lines = Self.answer(report).split(separator: "\n").map(String.init)
        #expect(lines.dropFirst().first == "  \(Self.trap)")
    }

    /// Without the stream nothing says where a test is declared, so the same log keeps its unranked order, each process's last trap first.
    @Test
    func withoutTheStreamTheTrapsStayUnranked() throws {
        let report = try Self.report(Self.log(), stream: false)

        #expect(report.testCrash?.traps.first == Self.lookalike)
        #expect(report.testCrash?.traps.count == 6)
    }

    /// The runtime can spell the file by its full path, which the stream records beside the `Module/File.swift` spelling.
    @Test
    func aTrapSpelledByItsFullPathLeadsToo() throws {
        let full = "/Users/dev/Pallet/Tests/PalletTests/Stacking.swift:9: Fatal error: real"
        let report = try Self.report(Self.log().replacingOccurrences(of: Self.trap, with: full), stream: true)

        #expect(report.testCrash?.traps.first == full)
    }

    /// `topples()` is declared at line 7 and `stacks()`, which ended, at 12: a trap from line 7 to 11 is the unfinished test's, one before it or from 12 on is not, and the order falls back to the unranked one.
    @Test(arguments: [(7, true), (11, true), (6, false), (12, false), (13, false)])
    func onlyTheLinesUpToTheNextDeclarationAreTheUnfinishedTests(line: Int, leads: Bool) throws {
        let moved = "PalletTests/Stacking.swift:\(line): Fatal error: real"
        let report = try Self.report(Self.log().replacingOccurrences(of: Self.trap, with: moved), stream: true)

        #expect(report.testCrash?.traps.first == (leads ? moved : Self.lookalike))
    }

    /// The stream's record of the run: the two tests it started and never ended, each from its declaration to the next one in its file or the file's end.
    @Test
    func theStreamRecordsWhereEachUnfinishedTestIsDeclared() throws {
        let stream = try ShardEventStream.read(#require(String(bytes: TestSources.runOutputData(Self.capture, extension: "jsonl"), encoding: .utf8)))
        let path = "/Users/dev/Pallet/Tests/PalletTests/Stacking.swift"

        #expect(stream.unfinishedSources == [
            DeclaredTestSource(fileID: "PalletTests/Stacking.swift", filePath: path, lines: 7 ..< 12),
            DeclaredTestSource(fileID: "PalletTests/Stacking.swift", filePath: path, lines: 21 ..< Int.max),
        ])
    }

    private static func log() throws -> String {
        try TestSources.runOutput(capture)
    }

    private static func report(_ log: String, stream: Bool, sourceLocation: SourceLocation = #_sourceLocation) throws -> RunReport {
        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        filter.consume(Data(log.utf8))
        if stream {
            let data = try TestSources.runOutputData(capture, extension: "jsonl")
            try filter.read(eventStream: ShardEventStream.read(#require(String(bytes: data, encoding: .utf8), sourceLocation: sourceLocation)))
        }
        return filter.finish(exitCode: 1)
    }

    private static func answer(_ report: RunReport) -> String {
        RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Pallet")).render(report, exitCode: 1, logURL: nil)
    }
}
