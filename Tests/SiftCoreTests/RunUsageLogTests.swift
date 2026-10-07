//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers what `sift run` files about itself: one line per wrapped command, the line counts and the failing tests each written as a pair or not at all, and a write that cannot happen costing nothing but a note.
@Suite(.temporaryDirectories)
struct RunUsageLogTests {
    /// `shown` is what the answer printed, not what the filter counted on its way to composing one.
    ///
    /// The two differ whenever the failures are served as a shape — over a thousand lines counted as shown against a couple of dozen printed — and filing the count puts a saving in `usage` and on the report page smaller than the one the tool actually made. Here the report says 800 lines arrived and the answer says it cost 12, and 12 is what is filed.
    @Test
    func aFilteredRunRecordsItsKindExitLineCountsAndRoot() throws {
        let file = try Self.scratchFile()
        let log = RunUsageLog(fileURL: file)

        log.record(
            logKey: "swift test",
            exitCode: 1,
            answer: RunUsageLog.Answer(report: Self.report(totalLines: 800), lines: 12, failedTests: ["theGridReflows()"]),
            repositoryRoot: URL(fileURLWithPath: "/tmp/repo"),
            milliseconds: 4300
        )

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        let entry = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(entry["kind"] as? String == "swift test")
        #expect(entry["exit"] as? Int == 1)
        #expect(entry["shown"] as? Int == 12)
        #expect(entry["total"] as? Int == 800)
        #expect(entry["root"] as? String == "/tmp/repo")
        #expect(entry["ms"] as? Int == 4300)
        let timestamp = try #require(entry["ts"] as? String)
        #expect(ISO8601DateFormatter().date(from: timestamp) != nil)
    }

    /// A passthrough records no line counts, and the key it was handed lands in the `kind` field as written.
    ///
    /// Line counts are absent rather than zero: nothing was filtered, and a zero there would read as a run that suppressed nothing — which is a different and flattering claim. *Which* key a passthrough gets is `RunCommandKindTests`' subject — the key is spelled once, upstream, where the action can still be read off argv — and what this pins is that nothing here rewrites it on the way to disk.
    @Test
    func aPassthroughRecordsNoLineCountsAndFilesTheKeyItWasGiven() throws {
        let file = try Self.scratchFile()
        let log = RunUsageLog(fileURL: file)

        log.record(logKey: "unfiltered", exitCode: 0, answer: RunUsageLog.Answer(), repositoryRoot: nil, milliseconds: 7)

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        let entry = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])

        #expect(entry["kind"] as? String == "unfiltered")
        #expect(entry["shown"] == nil)
        #expect(entry["total"] == nil)
        // A run outside any repository has no root to claim, and inventing the working directory as one would
        // put runs under a `--root` scope they never belonged to.
        #expect(entry["root"] == nil)
    }

    @Test
    func linesAccumulateAcrossRuns() throws {
        let file = try Self.scratchFile()
        let log = RunUsageLog(fileURL: file)

        log.record(logKey: "swift build", exitCode: 0, answer: RunUsageLog.Answer(report: Self.report(totalLines: 40), lines: 4, failedTests: []), repositoryRoot: nil, milliseconds: 10)
        log.record(logKey: "xcodebuild test", exitCode: 65, answer: RunUsageLog.Answer(report: Self.report(totalLines: 900), lines: 8, failedTests: ["-[WidgetTests testNaming]"]), repositoryRoot: nil, milliseconds: 20)

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")

        #expect(lines.count == 2)
    }

    /// The contract the usage log already holds to: a ledger is a record of work, never a precondition for it.
    @Test
    func aFailedWriteIsSwallowedWithANoteNotACrash() throws {
        // The parent path is a *file*, so directory creation must fail beneath it.
        let blocker = try TemporaryDirectory.make("run-blocker")
            .appendingPathComponent("run-blocker")
        try Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let notes = NoteBox()
        let log = RunUsageLog(fileURL: blocker.appendingPathComponent("nested/run.jsonl"), note: { notes.add($0) })

        log.record(logKey: "swift test", exitCode: 0, answer: RunUsageLog.Answer(), repositoryRoot: nil, milliseconds: 1)

        #expect(notes.all.count == 1)
        #expect(notes.all.first?.contains("run log write failed") == true)
    }

    /// A run whose answer never went out records neither half of the pair.
    ///
    /// The fail-open branch and the two that cannot reach the raw log at all leave nothing measured: one half of the pair is not a measurement, and a `total` with no `shown` beside it would be read by ``RunScan`` as a run that printed nothing.
    @Test
    func aRunThatServedNoAnswerRecordsNeitherLineCount() throws {
        let file = try Self.scratchFile()
        let log = RunUsageLog(fileURL: file)

        log.record(logKey: "xcodebuild test", exitCode: 65, answer: RunUsageLog.Answer(report: Self.report(totalLines: 900)), repositoryRoot: nil, milliseconds: 20)

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        let entry = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])

        #expect(entry["shown"] == nil)
        #expect(entry["total"] == nil)
        #expect(entry["exit"] as? Int == 65)
    }

    /// The names are what makes the log answerable: distinct, sorted, and counted beside themselves.
    ///
    /// Distinct because a parameterized function failing once per case is one test and not twenty, and sorted because every other key on this line is stable to read and to diff. The count beside them is what a reader compares against to know the list is whole.
    @Test
    func theFailingTestsAreRecordedDistinctSortedAndCounted() throws {
        let file = try Self.scratchFile()
        let log = RunUsageLog(fileURL: file)

        log.record(
            logKey: "swift test",
            exitCode: 1,
            answer: RunUsageLog.Answer(
                report: Self.report(totalLines: 800),
                lines: 12,
                failedTests: ["theWellIsATarget()", "aGridReflows()", "theWellIsATarget()"]
            ),
            repositoryRoot: nil,
            milliseconds: 4300
        )

        let entry = try Self.onlyEntry(in: file)

        #expect(entry["failed"] as? [String] == ["aGridReflows()", "theWellIsATarget()"])
        #expect(entry["failed_total"] as? Int == 2)
    }

    /// A run that read its own output and found nothing failing says so, and that is a different line from a run that cannot say.
    ///
    /// This is the whole reason the field is written at all on a green run: without it there is no population to measure a failure against, and "failed 3 times" with no denominator is a number nobody can act on.
    @Test
    func aRunWithNoFailingTestsRecordsAnEmptyListRatherThanNothing() throws {
        let file = try Self.scratchFile()
        let log = RunUsageLog(fileURL: file)

        log.record(logKey: "swift test", exitCode: 0, answer: RunUsageLog.Answer(report: Self.report(totalLines: 40), lines: 4, failedTests: []), repositoryRoot: nil, milliseconds: 10)

        let entry = try Self.onlyEntry(in: file)

        #expect(entry["failed"] as? [String] == [])
        #expect(entry["failed_total"] as? Int == 0)
    }

    /// A run in no position to say records neither field, so a reader sees unknown where a zero would have read as "nothing failed".
    ///
    /// Absent rather than an empty list, and the difference is the whole contract: lines written before this field existed are on disk, and every one of them has to parse as unknown rather than as a run everything passed in.
    @Test
    func aRunThatCannotNameItsFailuresRecordsNeitherField() throws {
        let file = try Self.scratchFile()
        let log = RunUsageLog(fileURL: file)

        log.record(logKey: "xcodebuild test", exitCode: 65, answer: RunUsageLog.Answer(report: Self.report(totalLines: 900)), repositoryRoot: nil, milliseconds: 20)

        let entry = try Self.onlyEntry(in: file)

        #expect(entry["failed"] == nil)
        #expect(entry["failed_total"] == nil)
    }

    /// The tree a run started on and its command line are filed as `tree` and `invocation`, and a run with none files no field rather than an empty one.
    @Test
    func theTreeIsFiledWhenThereIsOneAndLeftOutWhenThereIsNot() throws {
        let hashed = try Self.scratchFile()
        RunUsageLog(fileURL: hashed).record(logKey: "swift test", exitCode: 0, answer: RunUsageLog.Answer(failedTests: []), repositoryRoot: nil, milliseconds: 20, startedOn: TreeContentHash.RunKey(tree: "aaaa", invocation: "bbbb"))
        let unhashed = try Self.scratchFile()
        RunUsageLog(fileURL: unhashed).record(logKey: "swift test", exitCode: 0, answer: RunUsageLog.Answer(failedTests: []), repositoryRoot: nil, milliseconds: 20)

        #expect(try Self.onlyEntry(in: hashed)["tree"] as? String == "aaaa")
        #expect(try Self.onlyEntry(in: hashed)["invocation"] as? String == "bbbb")
        #expect(try Self.onlyEntry(in: unhashed)["tree"] == nil)
        #expect(try Self.onlyEntry(in: unhashed)["invocation"] == nil)
    }

    /// A gate that fails wholesale is bounded, and the line says how many names it did not write.
    ///
    /// The capture behind ``RunFailureShape`` reported 666 failures; naming every one would put tens of kilobytes into a file that is appended to forever. The count is what keeps the truncation honest — a run that withheld names cannot be read as one that named them all.
    @Test
    func aRunWithMoreFailuresThanTheCapIsBoundedAndSaysHowMany() throws {
        let file = try Self.scratchFile()
        let log = RunUsageLog(fileURL: file)

        log.record(
            logKey: "xcodebuild test",
            exitCode: 65,
            answer: RunUsageLog.Answer(
                report: Self.report(totalLines: 70000),
                lines: 23,
                failedTests: (1 ... 666).map { "aTestThatFailed\($0)()" }
            ),
            repositoryRoot: nil,
            milliseconds: 900
        )

        let raw = try String(contentsOf: file, encoding: .utf8)
        let entry = try Self.onlyEntry(in: file)

        #expect((entry["failed"] as? [String])?.count == RunUsageLog.failedTestCap)
        #expect(entry["failed_total"] as? Int == 666)
        // The point of the cap, stated as the thing it is there to prevent.
        #expect(raw.utf8.count < 4096)
    }

    /// A name wider than the cap is cut and says so, because a truncated identifier that looks whole is one a reader goes and searches for.
    @Test
    func aTestNameLongerThanTheCapIsClipped() throws {
        let file = try Self.scratchFile()
        let log = RunUsageLog(fileURL: file)
        let name = String(repeating: "a", count: RunUsageLog.testNameCap + 40) + "()"

        log.record(logKey: "swift test", exitCode: 1, answer: RunUsageLog.Answer(report: Self.report(totalLines: 40), lines: 4, failedTests: [name]), repositoryRoot: nil, milliseconds: 10)

        let recorded = try #require((Self.onlyEntry(in: file)["failed"] as? [String])?.first)

        #expect(recorded.count == RunUsageLog.testNameCap + 1)
        #expect(recorded.hasSuffix("…"))
    }

    private static func onlyEntry(in file: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any] {
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1, sourceLocation: sourceLocation)
        return try #require(
            try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any],
            sourceLocation: sourceLocation
        )
    }

    private static func report(totalLines: Int) -> RunReport {
        RunReport(
            errors: [],
            warnings: [],
            testFailures: [],
            summaryLines: [],
            contract: .runTally,
            verdict: nil,
            tally: nil,
            totalLines: totalLines
        )
    }

    private static func scratchFile() throws -> URL {
        try TemporaryDirectory.make("run-log")
            .appendingPathComponent("run-log", isDirectory: true)
            .appendingPathComponent("run.jsonl")
    }
}

extension RunUsageLogTests {
    /// Collects stderr notes across the log's @Sendable boundary.
    private final class NoteBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }

        func add(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
    }
}
