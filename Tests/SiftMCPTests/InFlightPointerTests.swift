//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A lookup sent beside an index call that is made and not yet answered is held back with a pointer at that call.
@Suite(.temporaryDirectories)
struct InFlightPointerTests {
    /// A real Claude Code transcript line carrying a call's result: `tool_use_id` ahead of `type`, inside a user message.
    private static func result(of id: String) -> String {
        #"{"isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"\#(id)","type":"tool_result","content":"Shell — Sources/App/Shell.swift:2"}]}}"#
    }

    private static func use(of id: String) -> String {
        #"{"isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"mcp__sift__where","input":{"symbol":"Shell"},"caller":{"type":"direct"}}]}}"#
    }

    private static var whereShell: [String: Any] {
        ["symbol": "Shell"]
    }

    private static var whereTool: String {
        "\(IndexToolName.prefix)where"
    }

    // MARK: - The ledger records each call's id and time

    @Test
    func theLedgerRecordsEachCallsIdAndTime() throws {
        let fixture = try Fixture(lines: [])
        let noted = Date(timeIntervalSince1970: 1_000_000)
        AdviceLedger(directory: fixture.directory.appendingPathComponent("advice"), now: { noted })
            .noteIndexCall(session: "s", calls: ["where Shell", "digest Shell"], toolUseID: "toolu_abc")
        let data = try Data(contentsOf: fixture.directory.appendingPathComponent("advice/s.json"))
        let state = try JSONDecoder().decode(AdviceLedger.State.self, from: data)

        #expect(state.callNotes["where Shell"] == AdviceLedger.CallNote(id: "toolu_abc", noted: 1_000_000))
        #expect(state.callNotes["digest Shell"] == AdviceLedger.CallNote(id: "toolu_abc", noted: 1_000_000))
    }

    @Test
    func aStoredStateWithoutTheFieldDecodesAsEmpty() throws {
        let stored = Data(#"{"denied":["grep -rn Shell Sources"],"nudges":2,"calls":["where Shell"],"quiets":0}"#.utf8)
        let state = try JSONDecoder().decode(AdviceLedger.State.self, from: stored)

        #expect(state.callNotes.isEmpty)
        #expect(state.denied == ["grep -rn Shell Sources"])
        #expect(state.calls == ["where Shell"])
    }

    @Test
    func aCallNotedWithNoIdHasNoNote() throws {
        let fixture = try Fixture(lines: [])
        fixture.ledger.noteIndexCall(session: "s", calls: ["where Shell"], toolUseID: "toolu_abc")
        fixture.ledger.noteIndexCall(session: "s", calls: ["where Shell"], toolUseID: nil)
        let data = try Data(contentsOf: fixture.directory.appendingPathComponent("advice/s.json"))

        #expect(try JSONDecoder().decode(AdviceLedger.State.self, from: data).callNotes.isEmpty)
    }

    // MARK: - The in-flight test

    private func decision(_ lines: [String], noted secondsAgo: TimeInterval = 5, transcript useTranscript: Bool = true, agent: String? = nil, tail: Int = ToolResultProbe.tailBytes) throws -> AdviceLedger.Decision {
        let fixture = try Fixture(lines: lines)
        fixture.ledger(after: -secondsAgo).noteIndexCall(session: "s", calls: ["where Shell"], toolUseID: "toolu_where")
        return fixture.ledger.decide(
            session: "s",
            command: "grep -rn Shell Sources",
            offering: ["where Shell"],
            transcript: useTranscript ? fixture.transcript : nil,
            agent: agent,
            tailBytes: tail
        )
    }

    @Test
    func anOfferedCallWithNoResultYetHoldsTheLookupBack() throws {
        #expect(try decision([Self.use(of: "toolu_where")]) == .pointAt(["where Shell"]))
    }

    @Test
    func aResultOfADifferentCallOrAMentionOfTheIdHoldsNothingBack() throws {
        let quoted = #"{"type":"user","message":{"content":[{"tool_use_id":"toolu_other","type":"tool_result","content":"{\"tool_use_id\":\"toolu_where\"}"}]}}"#

        #expect(try decision([Self.use(of: "toolu_where"), Self.result(of: "toolu_other"), quoted]) == .pointAt(["where Shell"]))
    }

    @Test
    func aResultAlreadyWrittenLetsTheLookupThrough() throws {
        #expect(try decision([Self.use(of: "toolu_where"), Self.result(of: "toolu_where")]) == .allow)
    }

    /// More lines than the small tail the tests read holds, none of them a result: 600 lines of 1 KB is over the 100 KB read.
    private static var filler: [String] {
        Array(repeating: #"{"type":"assistant","message":{"content":[{"type":"text","text":"\#(String(repeating: "x", count: 1000))"}]}}"#, count: 600)
    }

    private static let smallTail = 100_000

    @Test
    func aResultInsideTheTailOfALargeTranscriptLetsTheLookupThrough() throws {
        let lines = [Self.use(of: "toolu_where")] + Self.filler + [Self.result(of: "toolu_where")]

        #expect(try decision(lines, tail: Self.smallTail) == .allow)
    }

    @Test
    func aUseAndItsResultBothBeforeTheTailHoldsTheLookupBackBecauseTheResultIsNotInSight() throws {
        let lines = [Self.use(of: "toolu_where"), Self.result(of: "toolu_where")] + Self.filler

        #expect(try decision(lines, tail: Self.smallTail) == .pointAt(["where Shell"]))
    }

    @Test
    func aUseInsideTheTailOfALargeTranscriptWithNoResultHoldsTheLookupBack() throws {
        let lines = Self.filler + [Self.use(of: "toolu_where")]

        #expect(try decision(lines, tail: Self.smallTail) == .pointAt(["where Shell"]))
    }

    @Test
    func aTranscriptWithNeitherTheUseNorTheResultHoldsTheLookupBack() throws {
        #expect(try decision([Self.use(of: "toolu_other")]) == .pointAt(["where Shell"]))
    }

    @Test
    func aTranscriptThatDoesNotExistLetsTheLookupThrough() throws {
        let fixture = try Fixture(lines: [])
        fixture.ledger.noteIndexCall(session: "s", calls: ["where Shell"], toolUseID: "toolu_where")

        let missing = fixture.directory.appendingPathComponent("absent.jsonl").path

        #expect(fixture.ledger.decide(session: "s", command: "grep -rn Shell Sources", offering: ["where Shell"], transcript: missing) == .allow)
    }

    @Test
    func aCallNotedOverAMinuteAgoLetsTheLookupThrough() throws {
        #expect(try decision([Self.use(of: "toolu_where")], noted: 61) == .allow)
    }

    @Test
    func noTranscriptLetsTheLookupThrough() throws {
        #expect(try decision([Self.use(of: "toolu_where")], transcript: false) == .allow)
    }

    @Test
    func aSubagentWhoseOwnFileIsMissingIsNeverHeldOnItsParentsTranscript() throws {
        #expect(try decision([Self.use(of: "toolu_where")], agent: "a1") == .allow)
    }

    // MARK: - Through the hook

    @Test
    func aGrepAfterAnInFlightMCPWhereIsHeldBack() throws {
        let fixture = try Fixture(lines: [Self.use(of: "toolu_where")])
        fixture.take(tool: Self.whereTool, input: Self.whereShell)
        let verdict = try fixture.judge(fixture.grep())

        #expect(verdict.token == "held")
        #expect(verdict.rule == "inFlight")
        #expect(verdict.reason == IndexSuggestion.heldBackReason(calls: ["where Shell"]))
        #expect(verdict.call == "where Shell")
        let log = try String(contentsOf: fixture.suppressionsURL, encoding: .utf8)
        #expect(log.contains("inFlight"))
    }

    @Test
    func aGrepAfterAnInFlightBashWhereIsHeldBack() throws {
        let fixture = try Fixture(lines: [Self.use(of: "toolu_where")])
        fixture.take(tool: "Bash", input: ["command": "sift where Shell"])

        let verdict = try fixture.judge(fixture.shellGrep())

        #expect(verdict.token == "held")
        #expect(verdict.reason == IndexSuggestion.heldBackReason(calls: ["where Shell"]))
    }

    @Test(arguments: [
        "sift where Shell | head -5",
        "sift where Shell > out.txt",
        "sift where Shell 2>&1 | tail",
        "sift where Shell && ls",
        "sift where Shell; ls",
        "sift where Shell &",
        "sift where Shell\nls",
    ])
    func aPipedOrRedirectedOrChainedCliCallIsNotMade(command: String) {
        #expect(IndexSuggestion.callsMade(toolName: "Bash", input: [:], command: command, root: nil) == [])
    }

    @Test
    func aPlainCliCallIsMadeAndAQuotedPipeIsNotAPipe() {
        #expect(IndexSuggestion.callsMade(toolName: "Bash", input: [:], command: "sift where Shell", root: nil) == ["where Shell"])
        #expect(IndexSuggestion.callsMade(toolName: "Bash", input: [:], command: "sift digest Shell Depot", root: nil) == ["digest Shell", "digest Depot"])
    }

    @Test
    func aGrepBesideAPipedCliCallIsNotHeldBack() throws {
        let fixture = try Fixture(lines: [Self.use(of: "toolu_where")])
        fixture.take(tool: "Bash", input: ["command": "sift where Shell | head -5"])

        #expect(try fixture.judge(fixture.shellGrep()).token != "held")
    }

    @Test
    func theIdenticalRerunAfterAPointerPasses() throws {
        let fixture = try Fixture(lines: [Self.use(of: "toolu_where")])
        fixture.take(tool: Self.whereTool, input: Self.whereShell)
        let lookup = try fixture.grep()

        #expect(fixture.judge(lookup).token == "held")
        #expect(fixture.judge(lookup).line == "allowed\t\tledger")
    }

    @Test
    func aPointerWritesNoAnsweredEntry() throws {
        let fixture = try Fixture(lines: [Self.use(of: "toolu_where")])
        fixture.take(tool: Self.whereTool, input: Self.whereShell)
        let outcome = try fixture.outcome(fixture.grep())
        let answered = AnsweredLog(fileURL: fixture.directory.appendingPathComponent("answered.jsonl"), markers: fixture.directory.appendingPathComponent("answers"))
        let printed = PrintedAnswer.recorded(outcome, payload: ["tool_use_id": "toolu_next"], in: answered)

        #expect(printed != nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("answered.jsonl").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("answers").path))
    }

    @Test
    func aResultAlreadyWrittenLeavesTheGrepToTheLedgerAllow() throws {
        let fixture = try Fixture(lines: [Self.use(of: "toolu_where"), Self.result(of: "toolu_where")])
        fixture.take(tool: Self.whereTool, input: Self.whereShell)

        #expect(try fixture.judge(fixture.grep()).line == "allowed\t\tledger")
    }

    @Test
    func aLookupBesideOtherStatementsIsNeverHeldBack() throws {
        let fixture = try Fixture(lines: [Self.use(of: "toolu_where")])
        fixture.take(tool: Self.whereTool, input: Self.whereShell)

        #expect(try fixture.judge(fixture.shellGrep("grep -rn Shell Sources; ls")).token != "held")
    }

    @Test
    func aWholeReadAfterAnInFlightDigestIsHeldBackAndARangedReadIsLetThrough() async throws {
        let fixture = try Fixture(lines: [Self.use(of: "toolu_where")])
        fixture.take(tool: "\(IndexToolName.prefix)digest", input: ["target": "Shell"])
        let file = fixture.repo.appendingPathComponent("Sources/App/Shell.swift").path
        let members = (1 ... 40).map { "    func part\($0)() -> Int {\n        return \($0)\n    }" }.joined(separator: "\n")
        try ("struct Shell {\n" + members + "\n}\n").write(toFile: file, atomically: true, encoding: .utf8)
        try await SiftEngine(directory: fixture.repo, registry: nil).ensureFresh()
        let suppressions = SuppressionLog(fileURL: fixture.suppressionsURL)
        let whole = try #require(PreToolUseCommand.lookup(
            command: nil,
            payload: ["tool_name": "Read", "tool_input": ["file_path": file]],
            in: fixture.repo.path,
            noting: suppressions,
            couldAnswer: { _, _ in true }
        ))
        let ranged = PreToolUseCommand.lookup(
            command: nil,
            payload: ["tool_name": "Read", "tool_input": ["file_path": file, "offset": 1, "limit": 30]],
            in: fixture.repo.path,
            noting: suppressions,
            couldAnswer: { _, _ in true }
        )

        #expect(whole.suggestion.calls == ["digest Shell"])
        let heldVerdict = fixture.judge(whole)

        #expect(heldVerdict.token == "held", "\(heldVerdict.line)")
        #expect(heldVerdict.reason == IndexSuggestion.heldBackReason(calls: ["digest Shell"]))
        if let ranged {
            let verdict = fixture.judge(ranged)
            #expect(verdict.token == "allowed")
            #expect(verdict.rule == "noLookup")
        }
    }
}

extension InFlightPointerTests {
    struct Fixture {
        let directory: URL
        let repo: URL
        let transcript: String
        /// The instant the fixture's ledgers read as now, so a loaded machine's slow steps never age a call past the in-flight window.
        let made = Date()

        init(lines: [String]) throws {
            directory = try TemporaryDirectory.make("in-flight")
            repo = try MCPTestRepo.make(declaring: "Shell")
            let file = directory.appendingPathComponent("session.jsonl")
            try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            transcript = file.path
        }

        var ledger: AdviceLedger {
            ledger(after: 0)
        }

        /// The ledger as it reads `seconds` after the fixture was made.
        func ledger(after seconds: TimeInterval) -> AdviceLedger {
            AdviceLedger(
                directory: directory.appendingPathComponent("advice"),
                now: { [made] in made.addingTimeInterval(seconds) }
            )
        }

        var suppressionsURL: URL {
            directory.appendingPathComponent("suppressions.jsonl")
        }

        func take(tool: String, input: [String: Any], id: String? = "toolu_where") {
            var payload: [String: Any] = ["tool_name": tool, "tool_input": input]
            payload["tool_use_id"] = id
            _ = PreToolUseCommand.adviceTaken(
                session: "s1",
                context: AdviceContext.resolve(sessionID: "s1", transcriptPath: transcript),
                payload: payload,
                cwd: repo.path,
                ledger: ledger,
                callers: CallAttribution(directory: directory.appendingPathComponent("callers"))
            )
        }

        func grep(sourceLocation: SourceLocation = #_sourceLocation) throws -> PreToolUseCommand.Lookup {
            try #require(PreToolUseCommand.lookup(
                command: nil,
                payload: ["tool_name": "Grep", "tool_input": ["output_mode": "content", "pattern": "Shell", "path": repo.appendingPathComponent("Sources").path]],
                in: repo.path,
                noting: SuppressionLog(fileURL: suppressionsURL),
                couldAnswer: { _, _ in true }
            ), sourceLocation: sourceLocation)
        }

        func shellGrep(_ command: String = "grep -rn Shell Sources", sourceLocation: SourceLocation = #_sourceLocation) throws -> PreToolUseCommand.Lookup {
            try #require(PreToolUseCommand.lookup(
                command: command,
                payload: [:],
                in: repo.path,
                noting: SuppressionLog(fileURL: suppressionsURL),
                couldAnswer: { _, _ in true }
            ), sourceLocation: sourceLocation)
        }

        func outcome(_ lookup: PreToolUseCommand.Lookup, after seconds: TimeInterval = 0) -> (json: String?, verdict: PreToolUseCommand.Verdict) {
            PreToolUseCommand.outcome(
                to: lookup,
                session: "s1",
                context: AdviceContext.resolve(sessionID: "s1", transcriptPath: transcript),
                payload: ["session_id": "s1", "transcript_path": transcript, "tool_use_id": "toolu_next"],
                cwd: repo.path,
                ledger: ledger(after: seconds),
                usage: UsageLog(fileURL: directory.appendingPathComponent("usage.jsonl")),
                suppressions: SuppressionLog(fileURL: suppressionsURL),
                answerer: { _, _, _ in .withheld(.overSize) }
            )
        }

        func judge(_ lookup: PreToolUseCommand.Lookup, after seconds: TimeInterval = 0) -> PreToolUseCommand.Verdict {
            outcome(lookup, after: seconds).verdict
        }
    }
}
