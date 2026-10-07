//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// An in-place answer the same context follows with a whole read of the same file, within a few calls, is a miss and not a saving; every other follow-up leaves its saving standing.
///
/// Every line here is shaped as the harness writes it (``TranscriptTurns``).
@Suite(.temporaryDirectories)
struct AnswerThenReadTests {
    private static var file: String {
        "/repo/Sources/App/Depot.swift"
    }

    /// The refusal the hook writes when it answers a read of `relative` with its digest.
    private static func answer(_ relative: String = "Sources/App/Depot.swift", note: String? = nil) -> String {
        InPlaceAnswer.reason(
            calls: ["digest \(relative)"],
            answer: TranscriptFixture.fileDigest(relative, servedSource: false),
            source: 12000,
            standsIn: "",
            note: note
        ).text
    }

    /// A whole `Read` of `file` answered in place, as the two lines a transcript holds it in.
    private static var answeredRead: [Data] {
        [
            TranscriptTurns.call("Read", id: "r1", input: ["file_path": file], turn: "m1", cwd: "/repo"),
            TranscriptTurns.result(id: "r1", text: answer(), isError: true),
        ]
    }

    /// `count` calls that read nothing, one turn each.
    private static func unrelated(_ count: Int) -> [Data] {
        (0 ..< count).map { index in
            TranscriptTurns.call("Bash", id: "g\(index)", input: ["command": "git status"], turn: "t\(index)", cwd: "/repo")
        }
    }

    private static func whole(_ path: String = file, id: String = "r2") -> Data {
        TranscriptTurns.call("Read", id: id, input: ["file_path": path], turn: "m9", cwd: "/repo")
    }

    /// A whole read of the answered file on the fifth call after the answer — the identical re-run the answer offers — withdraws the answer's saving and counts a miss.
    @Test
    func aWholeReadOfTheSameFileWithinTheWindowIsAMiss() {
        let tally = TranscriptFixture.tally(Self.answeredRead + Self.unrelated(AnswerThenRead.window - 1) + [Self.whole()]).answerMisses

        #expect(tally.answers == [.digest: 1])
        #expect(tally.misses == [.digest: 1])
        #expect(tally.claimed > 0)
        #expect(tally.withdrawn == tally.claimed)
        #expect(tally.saved == 0)
    }

    /// A `cat` of the answered file, spelled relative to where it runs, is a whole read like any other.
    @Test
    func aCatOfTheSameFileIsAMiss() {
        let cat = TranscriptTurns.call("Bash", id: "c2", input: ["command": "cat Sources/App/Depot.swift"], turn: "m2", cwd: "/repo")

        let tally = TranscriptFixture.tally(Self.answeredRead + [cat]).answerMisses

        #expect(tally.misses == [.digest: 1])
        #expect(tally.saved == 0)
    }

    /// A whole read of another file inside the window leaves the answer's saving standing.
    @Test
    func aWholeReadOfAnotherFileIsNoMiss() {
        let tally = TranscriptFixture.tally(Self.answeredRead + [Self.whole("/repo/Sources/App/Alpha.swift")]).answerMisses

        #expect(tally.answers == [.digest: 1])
        #expect(tally.missCount == 0)
        #expect(tally.saved == tally.claimed && tally.claimed > 0)
    }

    /// A whole read of the answered file on the sixth call after it is past the window, so the saving stands.
    @Test
    func aWholeReadPastTheWindowIsNoMiss() {
        let tally = TranscriptFixture.tally(Self.answeredRead + Self.unrelated(AnswerThenRead.window) + [Self.whole()]).answerMisses

        #expect(tally.missCount == 0)
        #expect(tally.saved == tally.claimed && tally.claimed > 0)
    }

    /// A ranged read of the answered file is the loop working, never a miss.
    @Test
    func aRangedReadOfTheSameFileIsNoMiss() {
        let ranged = TranscriptTurns.call("Read", id: "r2", input: ["file_path": Self.file, "offset": 10, "limit": 20], turn: "m2", cwd: "/repo")

        let tally = TranscriptFixture.tally(Self.answeredRead + [ranged]).answerMisses

        #expect(tally.missCount == 0)
        #expect(tally.saved == tally.claimed && tally.claimed > 0)
    }

    /// An answer to a window is counted under its own shape, and a whole read after it is that shape's miss.
    @Test
    func aWindowAnswerReadWholeIsAWindowMiss() {
        let window = [
            TranscriptTurns.call("Read", id: "w1", input: ["file_path": Self.file, "offset": 10, "limit": 20], turn: "m1", cwd: "/repo"),
            TranscriptTurns.result(id: "w1", text: Self.answer(note: "only members of lines 10-30 are shown"), isError: true),
        ]

        let tally = TranscriptFixture.tally(window + [Self.whole()]).answerMisses

        #expect(tally.answers == [.window: 1])
        #expect(tally.misses == [.window: 1])
    }

    /// The identical re-run of an answered window fetches the very lines the answer stood in for, so it is a miss though it is no whole read.
    @Test
    func theIdenticalRerunOfAWindowAnswerIsAMiss() {
        let input: [String: Any] = ["file_path": Self.file, "offset": 800, "limit": 76]
        let lines = [
            TranscriptTurns.call("Read", id: "w1", input: input, turn: "m1", cwd: "/repo"),
            TranscriptTurns.result(id: "w1", text: Self.answer(note: "only members of lines 800-876 are shown"), isError: true),
            TranscriptTurns.call("Read", id: "w2", input: input, turn: "m2", cwd: "/repo"),
        ]

        let tally = TranscriptFixture.tally(lines).answerMisses

        #expect(tally.answers == [.window: 1])
        #expect(tally.misses == [.window: 1])
        #expect(tally.saved == 0)
    }

    /// The identical re-run of an answered shell window is a miss, and a different window of the same file after it is not.
    @Test
    func theIdenticalRerunOfAShellWindowIsAMissAndAnotherWindowIsNot() {
        let window = "sed -n '800,876p' Sources/App/Depot.swift"
        let answered = [
            TranscriptTurns.call("Bash", id: "s1", input: ["command": window], turn: "m1", cwd: "/repo"),
            TranscriptTurns.result(id: "s1", text: Self.answer(note: "only members of lines 800-876 are shown"), isError: true),
        ]
        let rerun = TranscriptTurns.call("Bash", id: "s2", input: ["command": window], turn: "m2", cwd: "/repo")
        let other = TranscriptTurns.call("Bash", id: "s3", input: ["command": "sed -n '810,830p' Sources/App/Depot.swift"], turn: "m2", cwd: "/repo")

        #expect(TranscriptFixture.tally(answered + [rerun]).answerMisses.misses == [.window: 1])
        #expect(TranscriptFixture.tally(answered + [other]).answerMisses.missCount == 0)
    }

    /// The window opens on the first call of the turn after the answer's own, so the calls that went out beside it in one turn use none of it.
    @Test
    func theWindowOpensOnTheTurnAfterTheAnswer() {
        let files = ["Depot", "Alpha", "Beta", "Gizmo"].map { "Sources/App/\($0).swift" }
        var lines: [Data] = []
        for (index, relative) in files.enumerated() {
            lines.append(TranscriptTurns.call("Read", id: "p\(index)", input: ["file_path": "/repo/" + relative], turn: "m1", cwd: "/repo"))
            lines.append(TranscriptTurns.result(id: "p\(index)", text: Self.answer(relative), isError: true))
        }
        lines += (0 ..< 5).map { TranscriptTurns.call("Bash", id: "u\($0)", input: ["command": "git status"], turn: "m1", cwd: "/repo") }
        lines += files.enumerated().map { index, relative in
            TranscriptTurns.call("Read", id: "q\(index)", input: ["file_path": "/repo/" + relative], turn: "m2", cwd: "/repo")
        }

        let tally = TranscriptFixture.tally(lines).answerMisses

        #expect(tally.answers == [.digest: 4])
        #expect(tally.misses == [.digest: 4])
    }

    /// A document's outline answer read whole afterwards is an outline miss.
    @Test
    func anOutlineAnswerReadWholeIsAnOutlineMiss() {
        let outline = InPlaceAnswer.reason(calls: ["digest Docs/Design.md"], answer: "# Design\n## Scope", source: 12000, standsIn: "").text
        let lines = [
            TranscriptTurns.call("Read", id: "d1", input: ["file_path": "/repo/Docs/Design.md"], turn: "m1", cwd: "/repo"),
            TranscriptTurns.result(id: "d1", text: outline, isError: true),
            TranscriptTurns.call("Read", id: "d2", input: ["file_path": "/repo/Docs/Design.md"], turn: "m2", cwd: "/repo"),
        ]

        let tally = TranscriptFixture.tally(lines).answerMisses

        #expect(tally.answers == [.outline: 1])
        #expect(tally.misses == [.outline: 1])
    }

    /// A shell line that prints the answered file whole among others, numbered, or through a window from its first line to its last is a whole read of it.
    @Test(arguments: [
        "cat Sources/App/Alpha.swift Sources/App/Depot.swift",
        "sed -n '1,$p' Sources/App/Depot.swift",
        "nl -ba Sources/App/Depot.swift",
    ])
    func aShellLinePrintingTheFileWholeIsAMiss(command: String) {
        let read = TranscriptTurns.call("Bash", id: "c2", input: ["command": command], turn: "m2", cwd: "/repo")

        let tally = TranscriptFixture.tally(Self.answeredRead + [read]).answerMisses

        #expect(tally.misses == [.digest: 1])
    }

    /// The bytes a closing line weighs as spared are read back from its own figures.
    @Test
    func theClaimedSavingIsReadOffTheClosingLine() {
        let text = "sift answered this\n\nanswer\n\n6.9 kB of source → 1.9 kB served (72% smaller)."

        #expect(AnswerThenRead.claimedSaving(inReason: text) == 5000)
        #expect(AnswerThenRead.claimedSaving(inReason: "No saving: 2.0 kB served for 1.9 kB of source.") == 0)
    }

    /// `audit` prints the miss beside the answers by shape, and the saving that stands without it.
    @Test
    func theAuditPrintsTheMissRateBesideTheSaving() throws {
        let root = try TemporaryDirectory.make("answer-read").appendingPathComponent("audit")
        let directory = root.appendingPathComponent("-Users-someone-Developer-App")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lines = Self.answeredRead + [Self.whole()]
        try Data(lines.flatMap { $0 + [0x0A] }).write(to: directory.appendingPathComponent("11112222-3333.jsonl"))

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("read anyway   1  of 1 answers to a read, the file then read whole or the call re-run within 5 calls — a miss, not a saving: digest 1 of 1 (100%)"))
        #expect(report.contains("saving      ~0 tokens saved (est. vs whole-file reads), as those answers' closing lines priced it"))
    }

    /// The scan withdraws an answer's claimed saving on its miss: an answer whose file was then read whole saved nothing, and one left alone keeps its saving.
    @Test(arguments: [true, false])
    func aMissWithdrawsItsClaimedSaving(readAnyway: Bool) throws {
        let directory = try TemporaryDirectory.make("answer-read").appendingPathComponent("status")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transcript = directory.appendingPathComponent("session.jsonl")
        let lines = Self.answeredRead + (readAnyway ? [Self.whole()] : [])
        try Data(lines.flatMap { $0 + [0x0A] }).write(to: transcript)
        let claimed = AnswerThenRead.claimedSaving(inReason: Self.answer())
        let usageLog = directory.appendingPathComponent("usage.jsonl")
        UsageLog(fileURL: usageLog).record(
            tool: "digest", target: "Sources/App/Depot.swift", root: "/repo", milliseconds: 80, succeeded: true,
            answer: AnswerBytes(served: 12000 - claimed, source: 12000), session: "session", via: "hook"
        )

        let withdrawn = TranscriptFixture.scored(transcript: transcript).answerMisses.withdrawn

        #expect(claimed > 0)
        #expect(withdrawn == (readAnyway ? claimed : 0))
    }

    /// One answer covering several files splits its claimed saving by each file's size, so a miss on the small file withdraws only the small file's part.
    @Test
    func aMissOnTheSmallerOfTwoAnsweredFilesWithdrawsItsShareBySize() throws {
        let directory = try TemporaryDirectory.make("answer-read").appendingPathComponent("split")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = directory.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data(repeating: 0x20, count: 9000).write(to: sources.appendingPathComponent("Large.swift"))
        try Data(repeating: 0x20, count: 1000).write(to: sources.appendingPathComponent("Small.swift"))
        let text = InPlaceAnswer.reason(
            calls: ["digest Sources/App/Large.swift", "digest Sources/App/Small.swift"],
            answer: TranscriptFixture.fileDigest("Sources/App/Large.swift", servedSource: false),
            source: 12000,
            standsIn: ""
        ).text
        let small = sources.appendingPathComponent("Small.swift").path
        let lines = [
            TranscriptTurns.call("Bash", id: "c1", input: ["command": "cat Sources/App/Large.swift Sources/App/Small.swift"], turn: "m1", cwd: directory.path),
            TranscriptTurns.result(id: "c1", text: text, isError: true),
            TranscriptTurns.call("Read", id: "r2", input: ["file_path": small], turn: "m9", cwd: directory.path),
        ]

        let tally = TranscriptFixture.tally(lines).answerMisses

        #expect(tally.answers == [.digest: 2])
        #expect(tally.misses == [.digest: 1])
        #expect(tally.withdrawn == Int(Double(AnswerThenRead.claimedSaving(inReason: text)) * 1000 / 10000))
    }
}
