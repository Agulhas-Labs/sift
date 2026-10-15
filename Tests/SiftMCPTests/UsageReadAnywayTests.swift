//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// The hook takes back the saving of an answer it gave in place when the context reads anyway what the answer stood in for, and files each answer so a later call can be matched to it.
@Suite(.temporaryDirectories)
struct UsageReadAnywayTests {
    private static var cat: String {
        "cat Sources/App/Shell.swift"
    }

    /// A Bash call of `command` in session `s1`, agent `a1`, under the id `id`.
    private static func payload(_ command: String, id: String) -> [String: Any] {
        ["session_id": "s1", "agent_id": "a1", "tool_use_id": id, "tool_name": "Bash", "tool_input": ["command": command]]
    }

    /// The fixture's usage log.
    private static func usage(_ fixture: AlreadyDigestedReadTests.Fixture) -> URL {
        fixture.stores.appendingPathComponent("usage.jsonl")
    }

    /// The hook answering `cat` of the fixture's file in place under `toolu_cat`, with a digest standing in for the whole file.
    private static func answerTheRead(_ fixture: AlreadyDigestedReadTests.Fixture, sourceLocation: SourceLocation = #_sourceLocation) throws {
        try fixture.lengthen()
        let answered = InPlaceAnswerer.Answered(
            reason: "answered",
            calls: [InPlaceAnswerer.Call(
                tool: "digest", target: "Sources/App/Shell.swift", bytes: AnswerBytes(served: 1000, source: 40000), intercepted: .file, readBytes: 40000
            )],
            root: fixture.repo.path,
            milliseconds: 1
        )
        let verdict = try PreToolUseCommand.outcome(
            to: fixture.classified(command: cat, rerunIn: "s1"),
            session: "s1",
            context: fixture.context("s1"),
            payload: payload(cat, id: "toolu_cat"),
            cwd: fixture.repo.path,
            ledger: fixture.ledger,
            usage: UsageLog(fileURL: usage(fixture)),
            suppressions: fixture.suppressions,
            answerer: { _, _, _ in .answered(answered) }
        ).verdict
        #expect(verdict.token == "in-place", "\(verdict.line)", sourceLocation: sourceLocation)
    }

    /// The hook's decision on `command`, run in the fixture's repository in the session it answered in.
    private static func decide(_ command: String, id: String, in fixture: AlreadyDigestedReadTests.Fixture) throws -> PreToolUseCommand.Verdict {
        try PreToolUseCommand.decided(
            command: nil,
            payload: payload(command, id: id),
            cwd: fixture.repo.path,
            session: "s1",
            context: fixture.context("s1"),
            answerer: InPlaceAnswerTests.scratchAnswerer(), ledger: fixture.ledger,
            usage: UsageLog(fileURL: usage(fixture)),
            suppressions: fixture.stores.appendingPathComponent("suppressions.jsonl"),
            couldAnswer: { _, _ in true }
        ).verdict
    }

    /// The usage log's lines, each parsed.
    private static func lines(_ fixture: AlreadyDigestedReadTests.Fixture, sourceLocation: SourceLocation = #_sourceLocation) throws -> [[String: Any]] {
        try String(contentsOf: usage(fixture), encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any], sourceLocation: sourceLocation)
        }
    }

    /// The identical re-run of an answered read goes through, and the hook writes the line that takes the answer's saving back, so `usage` prices nothing.
    @Test
    func theReRunOfAnAnsweredReadTakesItsSavingBack() throws {
        let fixture = try AlreadyDigestedReadTests.Fixture()
        try Self.answerTheRead(fixture)

        let verdict = try Self.decide(Self.cat, id: "toolu_again", in: fixture)

        #expect(verdict.token == "allowed", "\(verdict.line)")
        let readAnyway = try Self.lines(fixture).filter { $0["readAnyway"] != nil }
        #expect(readAnyway.map { $0["readAnyway"] as? String } == ["toolu_cat"])
        #expect(readAnyway.map { $0["target"] as? String } == ["Sources/App/Shell.swift"])
        let scan = try UsageScan.load(fileURL: Self.usage(fixture)).get()
        #expect(scan.entries.map(\.readAnyway) == [true])
        #expect(scan.savings == nil)
    }

    /// An answer is taken back once: a second re-run names it again nowhere.
    @Test
    func anAnswerIsTakenBackOnce() throws {
        let fixture = try AlreadyDigestedReadTests.Fixture()
        try Self.answerTheRead(fixture)

        _ = try Self.decide(Self.cat, id: "toolu_again", in: fixture)
        _ = try Self.decide(Self.cat, id: "toolu_third", in: fixture)

        #expect(try Self.lines(fixture).count { $0["readAnyway"] != nil } == 1)
    }

    /// A window of the answered file is the loop working, not a read anyway: the answer keeps its saving.
    @Test
    func aWindowOfTheAnsweredFileTakesNothingBack() throws {
        let fixture = try AlreadyDigestedReadTests.Fixture()
        try Self.answerTheRead(fixture)

        let verdict = try Self.decide("sed -n '2,10p' Sources/App/Shell.swift", id: "toolu_window", in: fixture)

        #expect(verdict.token == "allowed", "\(verdict.line)")
        #expect(try Self.lines(fixture).allSatisfy { $0["readAnyway"] == nil })
        let savings = try #require(try UsageScan.load(fileURL: Self.usage(fixture)).get().savings)
        #expect(savings.total.calls == 1)
    }

    /// The hook's line for an answered read says what it intercepted, under the command's id, with the bytes one `Read` of the file returns.
    @Test
    func theHookWritesWhatItInterceptedUnderTheCommandsID() throws {
        let fixture = try AlreadyDigestedReadTests.Fixture()
        try Self.answerTheRead(fixture)

        let line = try #require(try Self.lines(fixture).first)

        #expect(line["via"] as? String == "hook")
        #expect(line["intercepted"] as? String == "file")
        #expect(line["call"] as? String == "toolu_cat")
        #expect(line["readBytes"] as? Int == 40000)
    }

    /// The ledger keeps only the newest answered reads, so a read of one dropped is no longer taken for a read anyway.
    @Test
    func theLedgerKeepsOnlyTheNewestAnsweredReads() throws {
        let ledger = try AdviceLedger(directory: TemporaryDirectory.make("answered-reads").appendingPathComponent("advice"))
        let input = { (index: Int) -> [String: Any] in ["file_path": "/repo/Sources/App/Part\(index).swift"] }
        for index in 0 ... AdviceLedger.answeredReadsKept {
            ledger.noteAnswered(session: "s1", call: "toolu_\(index)", targets: ["Sources/App/Part\(index).swift"], toolName: "Read", input: input(index), cwd: "/repo")
        }

        #expect(ledger.readAnyway(session: "s1", toolName: "Read", input: input(0), cwd: "/repo").isEmpty)
        #expect(ledger.readAnyway(session: "s1", toolName: "Read", input: input(1), cwd: "/repo").map(\.call) == ["toolu_1"])
    }

    /// A ledger written before answered reads were kept decodes with none, and keeps everything else.
    @Test
    func aLedgerWrittenBeforeAnsweredReadsDecodes() throws {
        let stored = Data(#"{"denied":["cat Sources/App/Shell.swift"],"written":["/repo/a.swift"]}"#.utf8)
        let state = try JSONDecoder().decode(AdviceLedger.State.self, from: stored)

        #expect(state.answeredReads.isEmpty)
        #expect(state.denied == ["cat Sources/App/Shell.swift"])
    }
}
