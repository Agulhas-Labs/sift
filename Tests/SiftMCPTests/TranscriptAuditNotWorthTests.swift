//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A lookup no index answer is smaller than is not worth answering: out of the share, in the replay and in the live audit.
@Suite(.temporaryDirectories)
struct TranscriptAuditNotWorthTests {
    /// A cold window the hook lets run as `notSmaller` is not worth answering: it is counted on a row of its own, never still cold, and is out of the replayed share's denominator, which the old one beside it held it in.
    @Test func aWindowNoAnswerIsSmallerThanIsNotWorthAndOutOfTheReplayedDenominator() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()

        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let lines = try [
            TranscriptAuditReplayTests.call("sed -n 100,119p Sources/App/Depot.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "func stock2"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)

        let section = try await TranscriptAuditReplayTests.replaySection(of: transcript)

        #expect(section.contains("  cold            1  the lookups the audit calls cold"), "\(section)")
        #expect(section.contains { $0.hasPrefix("  still cold      0  ") }, "\(section)")
        #expect(section.contains { $0.hasPrefix("  not worth       1  ") }, "\(section)")
        #expect(section.contains("         1  notSmaller"), "\(section)")
        #expect(section.contains(
            "  replayed share n/a = (indexed 0 + recovered 0) / 0 — the audit's own 0% — on the old denominator 0% = … / 1 (text searches in one file +0, unreplayable +0, not worth +1)"
        ), "\(section)")
        #expect(section.contains { $0.contains("− located − unreplayable − not worth)") }, "\(section)")
    }

    /// In the live audit, a cold window the hook's suppression log records letting run as `notSmaller`, under that call's id, is not worth answering rather than a miss; an entry naming no call, or another call, moves nothing.
    @Test func aWindowTheHookLoggedAsNotSmallerIsNotWorthInTheLiveAudit() throws {
        let root = try TemporaryDirectory.make("repo")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        let members = (1 ... 40).map { "    func part\($0)() -> Int {\n        let count = \($0)\n        return count * 2\n    }" }
        try ("/// A gizmo.\nstruct Gizmo {\n" + members.joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent("Sources/App/Gizmo.swift"), atomically: true, encoding: .utf8)
        let projects = try TemporaryDirectory.make("projects")
        let transcript = projects.appendingPathComponent("replayed-session.jsonl")
        let lines = try [
            TranscriptAuditReplayTests.call("sed -n 100,119p Sources/App/Gizmo.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "func part25"),
            TranscriptAuditReplayTests.call("sed -n 1,20p Sources/App/Gizmo.swift", id: "c2", cwd: root.path, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "c2", isError: false, text: "struct Gizmo"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)
        let log = projects.appendingPathComponent("suppressions.jsonl")
        let logged = SuppressionLog(fileURL: log)
        logged.note(symbol: "notSmaller", directory: root.path, rule: "answerWithheld", call: "c1")
        logged.note(symbol: "notSmaller", directory: root.path, rule: "answerWithheld")
        logged.note(symbol: "overSize", directory: root.path, rule: "answerWithheld", call: "c2")

        let report = TranscriptAudit.render(projectsDirectory: projects, transcript: transcript.path, suppressionLog: log)

        #expect(report.contains("not worth      1  not worth the round trips it would have cost to answer these"), "\(report)")
        #expect(report.contains("larger       1  of those, a read the hook let run, its answer no smaller than what it prints"), "\(report)")
    }

    /// On one transcript and one suppression log, the replay's "the audit's own" share is the share the audit it is appended to prints.
    @Test func theReplaysOwnShareIsTheAuditsOnTheSameLog() async throws {
        let logged = try await Self.loggedWindow()

        let report = TranscriptAudit.render(projectsDirectory: logged.transcript.deletingLastPathComponent(), transcript: logged.transcript.path, suppressionLog: logged.log)
        let section = try await Self.replaySection(of: logged.transcript, suppressionLog: logged.log)

        let audits = try #require(Self.share(in: report, after: "served by sift — ", before: " of the lookups that had a choice"), "\(report)")
        let replays = try #require(Self.share(in: section.joined(separator: "\n"), after: "the audit's own ", before: " — on the old"), "\(section)")

        #expect(audits == "100%", "\(report)")
        #expect(replays == audits, "\(section)")
        // The replay puts the logged window back before its own verdict takes it out again, so it is out of the replayed share once.
        #expect(section.contains { $0.hasPrefix("  replayed share 100% = (indexed 1 + recovered 0) / 1 — the audit's own 100%") }, "\(section)")
        // The window the log names is still put to the hook and scored by its own verdict, not taken out before it.
        #expect(section.contains { $0.split(separator: " ").prefix(3) == ["not", "worth", "1"] }, "\(section)")
    }

    /// A window the log records letting run on worth is out of the replayed share once: the one indexed call is the whole of a denominator of one, and the old denominator holds the window as its one miss.
    @Test(arguments: [
        ("sed -n 100,119p Sources/App/Depot.swift", "notSmaller"),
    ])
    func aLoggedWindowIsOutOfTheReplayedDenominatorOnce(command: String, rule: String) async throws {
        let logged = try await Self.loggedWindow(command: command, rule: rule)

        let section = try await Self.replaySection(of: logged.transcript, suppressionLog: logged.log)

        #expect(section.contains { $0.hasPrefix("  not worth       1  ") }, "\(section)")
        #expect(section.contains("         1  \(rule)"), "\(section)")
        #expect(section.contains(
            "  replayed share 100% = (indexed 1 + recovered 0) / 1 — the audit's own 100% — on the old denominator 50% = … / 2 (text searches in one file +0, unreplayable +0, not worth +1)"
        ), "\(section)")
    }

    /// A window the log records letting run on worth, which the hook's own verdict would now answer in place, is counted once in the denominator rather than left out of it: before the fix the recovered call inflated the share past its numerator's own indexed call, past 100%; put back once, the denominator holds both calls and the share settles at 100%.
    @Test func aLoggedWindowTheHookWouldNowRecoverIsCountedOnceInTheDenominator() async throws {
        let logged = try await Self.loggedWindow(command: "grep -n 'func stock1()' Sources/App/Depot.swift", rule: "notSmaller")

        let section = try await Self.replaySection(of: logged.transcript, suppressionLog: logged.log)

        #expect(section.contains("  recovered       1  the hook would now answer these in place"), "\(section)")
        #expect(section.contains { $0.hasPrefix("  replayed share 100% = (indexed 1 + recovered 1) / 2 — the audit's own 100%") }, "\(section)")
    }

    /// The scan reads the same log, so its share leaves a logged `notSmaller` window out as the audit's does.
    @Test
    func theScansShareIsTheAuditsOnTheSameLog() async throws {
        let logged = try await Self.loggedWindow()

        let tally = TranscriptFixture.scored(transcript: logged.transcript, suppressionLog: logged.log)

        let audit = TranscriptAudit.render(projectsDirectory: logged.transcript.deletingLastPathComponent(), transcript: logged.transcript.path, suppressionLog: logged.log)
        let audits = try #require(Self.share(in: audit, after: "served by sift — ", before: " of the lookups that had a choice"), "\(audit)")

        #expect(tally.shareText == audits, "\(tally.shareText ?? "nil") against \(audits)")
        #expect(tally.total == 1)
    }

    /// A cold window on a line whose other statement prints what no answer reproduces is let run whole as `otherStatementsRun`, which the replay counts still cold rather than not worth: the call could have gone on the line.
    @Test func aLineLetRunWholeIsStillColdInTheReplay() async throws {
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

    /// In the live audit, a line the hook's suppression log records letting run whole as `otherStatementsRun`, under that call's id, is a miss: named on the `batched` row under `cold` and in the share's denominator.
    @Test func aLineTheHookLoggedAsRunningWholeIsABatchedMissInTheLiveAudit() async throws {
        let logged = try await Self.loggedWindow(command: "sed -n 100,119p Sources/App/Depot.swift; ls Sources", rule: "otherStatementsRun")

        let report = TranscriptAudit.render(projectsDirectory: logged.transcript.deletingLastPathComponent(), transcript: logged.transcript.path, suppressionLog: logged.log)

        #expect(report.contains("not worth      0  not worth the round trips it would have cost to answer these"), "\(report)")
        #expect(report.contains("batched      1  of those, a Swift read on a line the hook let run whole"), "\(report)")
        #expect(Self.share(in: report, after: "served by sift — ", before: " of the lookups that had a choice") == "50%", "\(report)")
    }
}

private extension TranscriptAuditNotWorthTests {
    /// A transcript of one answered index call about another file and one cold window of an indexed repository, run as `command`, with a suppression log recording that window let run under `rule` for its call.
    static func loggedWindow(
        command: String = "sed -n 100,119p Sources/App/Depot.swift",
        rule: String = "notSmaller"
    ) async throws -> LoggedWindow {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let projects = try TemporaryDirectory.make("projects")
        let transcript = projects.appendingPathComponent("replayed-session.jsonl")
        var lines = [TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Ledger"], cwd: root.path)]
        lines.append(TranscriptFixture.indexAnswer(id: "d1", text: "struct Ledger"))
        try lines.append(TranscriptAuditReplayTests.call(command, id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"))
        lines.append(TranscriptFixture.toolResult(id: "c1", isError: false, text: "func stock2"))
        try (lines.joined(separator: [0x0A]) + Data([0x0A])).write(to: transcript)
        let log = projects.appendingPathComponent("suppressions.jsonl")
        SuppressionLog(fileURL: log).note(symbol: rule, directory: root.path, rule: "answerWithheld", call: "c1")
        return LoggedWindow(transcript: transcript, log: log, root: root.path)
    }

    /// `AuditCommand.replaySection` over `transcript` with `suppressionLog`, as `audit --replay` runs it.
    static func replaySection(of transcript: URL, suppressionLog: URL) async throws -> [String] {
        let scratch = try TemporaryDirectory.make("replay")
        return try await InPlaceAnswerTests.onItsOwnThread {
            Result {
                try AuditCommand.replaySection(
                    projectsDirectory: transcript.deletingLastPathComponent(),
                    since: nil,
                    transcript: transcript.path,
                    scratch: scratch,
                    timeBudget: InPlaceAnswerTests.roomy,
                    suppressionLog: suppressionLog
                )
            }
        }.get()
    }

    /// The text between `after` and `before` on the first line of `text` holding both.
    static func share(in text: String, after: String, before: String) -> String? {
        for line in text.split(separator: "\n") {
            guard let start = line.range(of: after), let end = line.range(of: before, range: start.upperBound ..< line.endIndex) else { continue }
            return String(line[start.upperBound ..< end.lowerBound])
        }
        return nil
    }
}

private extension TranscriptAuditNotWorthTests {
    /// A transcript holding one cold window, the suppression log beside it, and the repository the window read.
    struct LoggedWindow {
        let transcript: URL
        let log: URL
        let root: String
    }
}
