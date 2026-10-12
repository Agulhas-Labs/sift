//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A lookup after an index call its offer names is let through as the offered-call rule lets it, whether or not the transcript holds that call's result yet.
@Suite(.temporaryDirectories)
struct CallMadeBesideALookupTests {
    /// A Claude Code transcript line carrying the call `id` with no result after it.
    private static func use(of id: String, tool: String, input: String) -> String {
        #"{"isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"\#(tool)","input":\#(input),"caller":{"type":"direct"}}]}}"#
    }

    private static var whereUse: String {
        use(of: "toolu_where", tool: "\(IndexToolName.prefix)where", input: #"{"symbol":"Shell"}"#)
    }

    private static var digestUse: String {
        use(of: "toolu_digest", tool: "\(IndexToolName.prefix)digest", input: #"{"target":"Shell"}"#)
    }

    /// A `git` that never answers in time, as one on a loaded machine does not.
    private static let gitFailing = RootDiscovery(discover: { _ in nil })

    @Test
    func aGrepAfterAWhereWhoseResultIsNotWrittenIsLetThroughByTheLedger() throws {
        let fixture = try Fixture(lines: [Self.whereUse])
        fixture.take(tool: "\(IndexToolName.prefix)where", input: ["symbol": "Shell"], id: "toolu_where")
        let grep = try #require(PreToolUseCommand.lookup(
            command: nil,
            payload: ["tool_name": "Grep", "tool_input": ["output_mode": "content", "pattern": "Shell", "path": fixture.repo.appendingPathComponent("Sources").path]],
            in: fixture.repo.path,
            noting: SuppressionLog(fileURL: fixture.suppressionsURL),
            couldAnswer: { _, _ in true }
        ))
        let outcome = fixture.outcome(grep)

        #expect(outcome.json == nil)
        #expect(outcome.verdict.line == "allowed\t\tledger")
    }

    @Test(arguments: [true, false])
    func aWholeReadAfterADigestWhoseResultIsNotWrittenIsLetThroughAsAlreadyDigested(gitAnswers: Bool) async throws {
        let fixture = try Fixture(lines: [Self.digestUse])
        fixture.take(tool: "\(IndexToolName.prefix)digest", input: ["target": "Shell"], id: "toolu_digest")
        let file = fixture.repo.appendingPathComponent("Sources/App/Shell.swift").path
        let members = (1 ... 40).map { "    func part\($0)() -> Int {\n        return \($0)\n    }" }.joined(separator: "\n")
        try ("struct Shell {\n" + members + "\n}\n").write(toFile: file, atomically: true, encoding: .utf8)
        try await SiftEngine(directory: fixture.repo, registry: nil).ensureFresh()
        let read = try #require(PreToolUseCommand.lookup(
            command: nil,
            payload: ["tool_name": "Read", "tool_input": ["file_path": file]],
            in: fixture.repo.path,
            noting: SuppressionLog(fileURL: fixture.suppressionsURL),
            couldAnswer: { _, _ in true }
        ))
        let verdict = gitAnswers ? fixture.outcome(read).verdict : RootDiscovery.$current.withValue(Self.gitFailing) { fixture.outcome(read).verdict }

        #expect(verdict.line == "allowed\t\talreadyDigested")
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

    /// A ledger written while calls were noted with their ids carries `callNotes`; it loads with everything else it holds.
    @Test
    func aLedgerCarryingCallNotesLoadsWithWhatItHas() throws {
        let fixture = try Fixture(lines: [])
        let advice = fixture.directory.appendingPathComponent("advice")
        try FileManager.default.createDirectory(at: advice, withIntermediateDirectories: true)
        let stored = #"{"denied":["grep -rn Shell Sources"],"calls":["where Shell"],"callNotes":{"where Shell":{"id":"toolu_old","noted":1000}}}"#
        try Data(stored.utf8).write(to: advice.appendingPathComponent("s.json"))

        #expect(fixture.ledger.decide(session: "s", command: "grep -rn Shell Sources") == .allow)
        #expect(fixture.ledger.decide(session: "s", command: "grep -rn Shell Tests", offering: ["where Shell"]) == .allow)
        #expect(fixture.ledger.decide(session: "s", command: "grep -rn Shell Tests", offering: ["digest Shell"]) == .advise)
    }
}

extension CallMadeBesideALookupTests {
    struct Fixture {
        let directory: URL
        let repo: URL
        let transcript: String

        init(lines: [String]) throws {
            directory = try TemporaryDirectory.make("call-beside")
            repo = try MCPTestRepo.make(declaring: "Shell")
            let file = directory.appendingPathComponent("session.jsonl")
            try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            transcript = file.path
        }

        var ledger: AdviceLedger {
            AdviceLedger(directory: directory.appendingPathComponent("advice"))
        }

        var suppressionsURL: URL {
            directory.appendingPathComponent("suppressions.jsonl")
        }

        func take(tool: String, input: [String: Any], id: String) {
            _ = PreToolUseCommand.adviceTaken(
                session: "s1",
                context: AdviceContext.resolve(sessionID: "s1", transcriptPath: transcript),
                payload: ["tool_name": tool, "tool_input": input, "tool_use_id": id],
                cwd: repo.path,
                ledger: ledger,
                callers: CallAttribution(directory: directory.appendingPathComponent("callers"))
            )
        }

        func outcome(_ lookup: PreToolUseCommand.Lookup) -> (json: String?, verdict: PreToolUseCommand.Verdict) {
            PreToolUseCommand.outcome(
                to: lookup,
                session: "s1",
                context: AdviceContext.resolve(sessionID: "s1", transcriptPath: transcript),
                payload: ["session_id": "s1", "transcript_path": transcript, "tool_use_id": "toolu_next"],
                cwd: repo.path,
                ledger: ledger,
                usage: UsageLog(fileURL: directory.appendingPathComponent("usage.jsonl")),
                suppressions: SuppressionLog(fileURL: suppressionsURL),
                answerer: { _, _, _ in .withheld(.overSize) }
            )
        }
    }
}
