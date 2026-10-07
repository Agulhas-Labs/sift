//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A Swift read on a compound line the hook let run whole for its other statements is a miss the share counts, on a `batched` row of its own under `cold`, never a lookup excused as not worth.
@Suite(.temporaryDirectories)
struct BatchedReadIsMissTests {
    /// A cold lookup the log records letting run whole becomes a batched miss; one let run on worth is still withheld under its rule; a lookup that is not cold is left as it is.
    @Test func aColdLookupLetRunWholeIsScoredBatched() {
        let cold = SwiftLookup.cold(file: "Sources/App/Depot.swift", missed: nil)

        #expect(cold.scored(letThroughAs: .otherStatementsRun) == .batched(file: "Sources/App/Depot.swift"))
        #expect(cold.scored(letThroughAs: .notSmaller) == .withheldOnWorth(rule: .notSmaller))
        #expect(SwiftLookup.indexed.scored(letThroughAs: .otherStatementsRun) == .indexed)
    }

    /// A batched search keeps the call that would have answered it, and a retraction carries it too, so the audit can name it.
    @Test func aBatchedSearchKeepsItsMissedCall() {
        let cold = SwiftLookup.cold(file: nil, missed: .resolve)

        #expect(cold.scored(letThroughAs: .otherStatementsRun) == .batched(file: nil, missed: .resolve))
    }

    /// In the live audit a batched grep for a symbol is a cold search that names the `where` call.
    @Test func theLiveAuditNamesTheCallOfABatchedSearch() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let projects = try TemporaryDirectory.make("projects")
        let transcript = projects.appendingPathComponent("batched-search.jsonl")
        let lines = try [
            TranscriptAuditReplayTests.call("grep -rn Depot Sources; ls Sources", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "Sources/App/Depot.swift\nApp"),
        ]
        try (lines.joined(separator: [0x0A]) + Data([0x0A])).write(to: transcript)
        let log = projects.appendingPathComponent("suppressions.jsonl")
        SuppressionLog(fileURL: log).note(symbol: "otherStatementsRun", directory: root.path, rule: "answerWithheld", call: "c1")

        // No registered roots: the name is judged by this repository's index alone, never by whichever of the machine's repositories happens to declare it at this build's schema.
        let snapshot = TranscriptSnapshot.take(projectsDirectory: projects, since: nil, transcript: transcript.path, indexes: RunIndexState(registry: { [] }))
        let report = TranscriptAudit.render(projectsDirectory: projects, transcript: transcript.path, suppressionLog: log, snapshot: snapshot)

        #expect(report.contains("batched      1"), "\(report)")
        #expect(report.contains("1 Swift-flavoured search — 1 where"), "\(report)")
    }

    /// A batched lookup is counted in `cold` and in `batched`, so it is in the share's denominator and the voluntary one, and a retraction takes both back.
    @Test func aBatchedLookupIsAColdMissAndIsRetractedWhole() {
        var tally = TranscriptTally(indexed: 1)
        tally.fold(.lookup(.batched(file: "Sources/App/Depot.swift")))

        #expect(tally.cold == 1)
        #expect(tally.batched == 1)
        #expect(tally.withheldOnWorth == 0)
        #expect(tally.total == 2)
        #expect(tally.voluntaryTotal == 2)
        #expect(tally.shareText == "50%")

        tally.fold(.lookupRetracted(.batched(file: "Sources/App/Depot.swift")))
        #expect(tally == TranscriptTally(indexed: 1))
    }

    /// A context that could not reach the index moves its batched misses out with the rest of its cold ones.
    @Test func anUnreachableContextsBatchedMissesLeaveWithItsCold() {
        let tally = TranscriptTally(cold: 1, batched: 1, recordedToolListWithoutIndex: true)

        #expect(tally.scored.cold == 0)
        #expect(tally.scored.batched == 0)
        #expect(tally.scored.unreachable == 1)
    }

    /// The suppression log's reader hands back a line let run whole beside the calls let run on worth, each under the withholding it logged.
    @Test func theLogReaderReturnsALineLetRunWhole() throws {
        let log = try TemporaryDirectory.make("suppressions").appendingPathComponent("suppressions.jsonl")
        SuppressionLog(fileURL: log).note(symbol: "otherStatementsRun", directory: "/tmp", rule: "answerWithheld", call: "c1")
        SuppressionLog(fileURL: log).note(symbol: "notSmaller", directory: "/tmp", rule: "answerWithheld", call: "c2")
        SuppressionLog(fileURL: log).note(symbol: "notExact", directory: "/tmp", rule: "answerWithheld", call: "c3")

        #expect(SuppressionLog.callsLetThrough(in: log) == ["c1": .otherStatementsRun, "c2": .notSmaller])
    }

    /// In the live audit a logged line run whole is a miss: on the `batched` row under `cold`, off the `not worth` rows, and in the share, which halves.
    @Test func theLiveAuditCountsALineLetRunWholeAsABatchedMiss() async throws {
        let logged = try await Self.loggedLine()

        let report = TranscriptAudit.render(projectsDirectory: logged.transcript.deletingLastPathComponent(), transcript: logged.transcript.path, suppressionLog: logged.log)

        #expect(report.contains("cold           1  went around the index"), "\(report)")
        #expect(report.contains("batched      1  of those, a Swift read on a line the hook let run whole for its other statements — put the sift call on the line instead"), "\(report)")
        #expect(report.contains("not worth      0  "), "\(report)")
        #expect(!report.contains("let run whole, a statement beside the lookup"), "\(report)")
        #expect(report.contains("served by sift — 50% of the lookups that had a choice"), "\(report)")
    }

    /// The scan reads the same log, so the share counts the batched read as the miss the audit counts.
    @Test func theScanCountsALineLetRunWholeAsAMiss() async throws {
        let logged = try await Self.loggedLine()

        let tally = TranscriptFixture.scored(transcript: logged.transcript, suppressionLog: logged.log)

        #expect(tally.cold == 1)
        #expect(tally.batched == 1)
        #expect(tally.withheldOnWorth == 0)
        #expect(tally.shareText == "50%")
    }

    /// The replay puts the same line to the hook, which still lets it run whole: still cold there, never not worth, and in the replayed denominator.
    @Test func theReplayCountsALineLetRunWholeAsStillCold() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository(padding: InPlaceAnswerTests.pastTheFloor)
        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let lines = try [
            TranscriptAuditReplayTests.call("sed -n 1,200p Sources/App/Depot.swift; ls Sources", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "func stock2\nApp"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)

        let section = try await TranscriptAuditReplayTests.replaySection(of: transcript)

        #expect(section.contains { $0.hasPrefix("  still cold      1  ") }, "\(section)")
        #expect(section.contains { $0.hasPrefix("  not worth       0  ") }, "\(section)")
        #expect(section.contains("         1  otherStatementsRun"), "\(section)")
    }
}

private extension BatchedReadIsMissTests {
    /// A transcript of one answered index call about another file and one window of an indexed repository batched with an `ls`, and a suppression log recording that line let run whole for its call.
    static func loggedLine() async throws -> (transcript: URL, log: URL) {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let projects = try TemporaryDirectory.make("projects")
        let transcript = projects.appendingPathComponent("batched-session.jsonl")
        let lines = try [
            TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Ledger"], cwd: root.path),
            TranscriptFixture.indexAnswer(id: "d1", text: "struct Ledger"),
            TranscriptAuditReplayTests.call("sed -n 1,200p Sources/App/Depot.swift; ls Sources", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "func stock2\nApp"),
        ]
        try (lines.joined(separator: [0x0A]) + Data([0x0A])).write(to: transcript)
        let log = projects.appendingPathComponent("suppressions.jsonl")
        SuppressionLog(fileURL: log).note(symbol: "otherStatementsRun", directory: root.path, rule: "answerWithheld", call: "c1")
        return (transcript, log)
    }
}
