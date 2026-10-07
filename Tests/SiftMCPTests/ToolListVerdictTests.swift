//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// The unreachable verdict read off the tool list the harness recorded, and the causes a report names for it.
///
/// One constraint runs through every test here: a context's cold lookups leave the share only on the harness's own word that its tool list had no sift in it — never because a transcript said nothing. Moving lookups out raises the share, the one direction it may not round on a guess.
@Suite(.temporaryDirectories)
struct ToolListVerdictTests {
    /// A `prompt_snapshot` listing `names` as the tools sent in full with every request.
    static func snapshot(tools names: [String]) -> Data {
        line(["type": "attachment", "attachment": ["type": "prompt_snapshot", "tools": names.map { ["name": $0] }]])
    }

    /// A `prompt_snapshot` with no tool list at all, as the harness writes the first of them — it carries only the prompt.
    static var snapshotWithoutTools: Data {
        line(["type": "attachment", "attachment": ["type": "prompt_snapshot"]])
    }

    /// A `deferred_tools_delta`: the tools held back, any brought back, and the servers the harness reports as failed.
    static func delta(added: [String] = [], readded: [String] = [], failed: [String] = []) -> Data {
        line([
            "type": "attachment",
            "attachment": [
                "type": "deferred_tools_delta",
                "addedNames": added,
                "readdedNames": readded,
                "removedNames": [String](),
                "pendingMcpServers": [String](),
                "failedMcpServers": failed.map { ["name": $0] },
            ],
        ])
    }

    /// The harness's record of a hook failing, in the shape it wrote the session start of a session whose binary was missing.
    ///
    /// `source` is the suffix the harness writes on `hookName` (`"SessionStart:<source>"`) — `startup` and `resume` are genuine starts; `clear` and `compact` launch no server at all.
    static func hookFailure(
        event: String = "SessionStart",
        source: String = "startup",
        exitCode: Int = 127,
        command: String = "/Users/someone/.local/bin/sift session-start"
    ) -> Data {
        line([
            "type": "attachment",
            "attachment": [
                "type": "hook_non_blocking_error",
                "hookName": "\(event):\(source)",
                "hookEvent": event,
                "stderr": "Failed with non-blocking status code: /bin/sh: \(command.split(separator: " ")[0]): No such file or directory",
                "exitCode": exitCode,
                "command": command,
            ],
        ])
    }

    /// A tool list with nothing held back and no sift in it: what an agent definition whose `tools:` leaves the server out writes.
    static var fullListWithoutIndex: Data {
        snapshot(tools: ["Read", "Grep", "Bash"])
    }

    /// One refused lookup — far short of the floor that lets refusals alone decide.
    static var oneRefusal: [Data] {
        TranscriptFixture.refusedRead(0)
    }

    static var coldRead: Data {
        TranscriptFixture.toolUse("Read", id: "c1", input: ["file_path": "/repo/Sources/App/Units.swift"])
    }

    private static func line(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    // MARK: The verdict

    /// A context whose transcript records its whole tool list with no sift in it could not reach the index, however few refusals it took.
    ///
    /// Both ways the list is written whole: a full list offering no tool search, where nothing is held back; and one offering it, with the delta listing what was held back.
    @Test
    func aWholeToolListWithoutTheIndexIsUnreachableWhateverItsRefusals() {
        let wholeInOne = TranscriptFixture.tally([Self.fullListWithoutIndex] + Self.oneRefusal + [Self.coldRead])
        #expect(wholeInOne.couldNotReachTheIndex)
        #expect(wholeInOne.scored.unreachable == 1)
        #expect(wholeInOne.scored.cold == 0)

        let wholeInTwo = TranscriptFixture.tally([
            Self.snapshot(tools: ["Read", "Bash", "ToolSearch"]),
            Self.delta(added: ["WebFetch", "mcp__docs__search"]),
            Self.coldRead,
        ])
        #expect(wholeInTwo.refusals == 0)
        #expect(wholeInTwo.couldNotReachTheIndex)
        #expect(wholeInTwo.scored.unreachable == 1)
    }

    /// Where the transcript does not record the tool list whole, it has not said, and only the refusal floor can excuse the context.
    ///
    /// Each case is one the scan must not read as absence: nothing recorded; a snapshot with no tool list, as the first one a harness writes is; a full list offering a tool search whose held-back half was never written; the held-back half alone, which is what an older harness writes; and the server reported as failed with no list beside it — a failed server can be brought back, so the failure says why and never whether.
    @Test
    func aToolListNotRecordedWholeIsNeverReadAsAbsence() {
        let unrecorded: [[Data]] = [
            [],
            [Self.snapshotWithoutTools],
            [Self.snapshot(tools: ["Read", "Bash", "ToolSearch"])],
            [Self.delta(added: ["WebFetch"])],
            [Self.delta(failed: ["sift"])],
        ]
        for lines in unrecorded {
            let tally = TranscriptFixture.tally(lines + Self.oneRefusal + [Self.coldRead])
            #expect(!tally.couldNotReachTheIndex, "\(lines.map { String(bytes: $0, encoding: .utf8) ?? "" })")
            #expect(tally.scored.cold == 1)
        }
    }

    /// A list that gains one of this server's tools later takes the verdict back for the whole context — added, or brought back after a removal.
    @Test
    func aToolListThatGainsTheIndexTakesTheVerdictBack() {
        let without = [Self.snapshot(tools: ["Read", "Bash", "ToolSearch"]), Self.delta(added: ["WebFetch"]), Self.coldRead]
        #expect(TranscriptFixture.tally(without).couldNotReachTheIndex)

        for gained in [Self.delta(added: ["mcp__sift__digest"]), Self.delta(readded: ["mcp__sift__where"])] {
            let tally = TranscriptFixture.tally(without + [gained])
            #expect(!tally.couldNotReachTheIndex)
            #expect(tally.scored.cold == 1)
        }
    }

    /// A full list that names one of this server's tools was held, whatever else it lists.
    @Test
    func aWholeToolListNamingTheIndexWasHeld() {
        let tally = TranscriptFixture.tally([Self.snapshot(tools: ["Read", "mcp__sift__where"])] + Self.oneRefusal + [Self.coldRead])

        #expect(!tally.couldNotReachTheIndex)
        #expect(tally.scored.cold == 1)
    }

    /// A context whose tool list has no sift in it and that reached the index on the CLI reached it — the rule the refusal floor already keeps, kept for the tool list too.
    @Test
    func aContextWithoutTheToolsThatReachedTheIndexOnTheCLIIsNotUnreachable() {
        let tally = TranscriptFixture.tally([
            Self.fullListWithoutIndex,
            TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "sift where SummaryState"]),
            Self.coldRead,
        ])

        #expect(tally.recordedToolListWithoutIndex)
        #expect(tally.cliCalls == 1)
        #expect(tally.cliServed == 1)
        #expect(!tally.couldNotReachTheIndex)
        #expect(tally.scored.cold == 1)
    }

    /// The session-start hook unable to run the binary is recorded from the harness's own line, and nothing else is taken for it.
    ///
    /// Another hook's 127, the same hook at a subagent's start — when a server launched long before may be running — and the hook failing for any other reason all say nothing about the binary at the session's start.
    @Test
    func aSessionStartHookUnableToRunTheBinaryIsRecorded() {
        func recorded(_ line: Data) -> Bool {
            var state = TranscriptScanState()
            _ = TranscriptScan.events(line: line, state: &state, belowFloor: { _ in false }, couldAnswer: { _, _ in true })
            return state.binaryMissingAtStart
        }

        #expect(recorded(Self.hookFailure()))
        #expect(!recorded(Self.hookFailure(event: "SubagentStart")))
        #expect(!recorded(Self.hookFailure(exitCode: 1)))
        #expect(!recorded(Self.hookFailure(command: "/opt/hooks/warn-when-closed.sh")))
    }

    /// `SessionStart` also fires for `clear` and `compact`, where no server is ever launched — a 127 there says nothing about whether the binary is missing, unlike a genuine `startup` or `resume`.
    @Test
    func onlyAGenuineSessionStartNamesTheMissingBinary() {
        func recorded(_ line: Data) -> Bool {
            var state = TranscriptScanState()
            _ = TranscriptScan.events(line: line, state: &state, belowFloor: { _ in false }, couldAnswer: { _, _ in true })
            return state.binaryMissingAtStart
        }

        #expect(!recorded(Self.hookFailure(source: "clear")))
        #expect(!recorded(Self.hookFailure(source: "compact")))
        #expect(recorded(Self.hookFailure(source: "startup")))
        #expect(recorded(Self.hookFailure(source: "resume")))
    }
}

// MARK: - The audit's causes

extension ToolListVerdictTests {
    /// A session transcript, with a subagent transcript beside it for each entry of `subagents`.
    private static func projects(session: [Data], subagents: [[Data]]) throws -> URL {
        let root = try TemporaryDirectory.make("tool-list").appendingPathComponent("projects")
        let directory = root.appendingPathComponent("-Users-someone-Developer-App")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(session.flatMap { $0 + [0x0A] }).write(to: directory.appendingPathComponent("11112222-3333.jsonl"))
        let agents = directory.appendingPathComponent("11112222-3333/subagents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        for (index, lines) in subagents.enumerated() {
            try Data(lines.flatMap { $0 + [0x0A] }).write(to: agents.appendingPathComponent("agent-\(index).jsonl"))
        }
        return root
    }

    /// A session's own context that held sift's tools and used them.
    private static var sessionHoldingTheIndex: [Data] {
        [snapshot(tools: ["Read", "Bash", "ToolSearch"]), delta(added: ["mcp__sift__digest"])]
            + TranscriptFixture.answeredCall("mcp__sift__digest", id: "a", input: ["target": "DepotStore"])
    }

    /// Twelve refusals and a cold read, in a transcript that records nothing about its tools — excused by the floor alone.
    private static var refusedWithNoToolList: [Data] {
        (0 ..< TranscriptTally.refusalsWithoutAnIndexCall).flatMap(TranscriptFixture.refusedRead) + [coldRead]
    }

    /// The case the refusal floor alone left in the share: a subagent that took one refusal and read on, with no sift in its recorded tool list.
    @Test
    func aSubagentWithOneRefusalAndNoSiftInItsToolListIsUnreachable() throws {
        let root = try Self.projects(
            session: Self.sessionHoldingTheIndex,
            subagents: [[Self.fullListWithoutIndex] + Self.oneRefusal + [Self.coldRead]]
        )

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("unreachable    1  lookups from contexts holding no sift tools"))
        #expect(report.contains("   reach it, and nor could one that never reached it whose transcript lists its tools with no sift among"))
        // The session held the tools, so the gap is the agent's own tool list.
        #expect(report.contains("1 from contexts with no server failure recorded, whose tool list has no sift in it"))
    }

    /// A subagent whose session's own context never held sift's tools lacked them because the session had no server — not because of its agent definition, which could not have added a tool the session did not have.
    ///
    /// The subagent's own transcript records nothing about its tools here, as a reviewer's with an explicit allowlist does when none of the listed MCP tools exist: the session's transcript is the evidence. The same subagent under a session that held the tools is the contrast.
    @Test
    func aSubagentOfASessionThatNeverHeldTheToolsIsExplainedByTheSession() throws {
        let sessionWithout = [Self.snapshot(tools: ["Read", "Bash", "ToolSearch"]), Self.delta(added: ["WebFetch"])]
        let lacking = try TranscriptAudit.render(projectsDirectory: Self.projects(session: sessionWithout, subagents: [Self.refusedWithNoToolList]))

        #expect(lacking.contains("1 from contexts in a session whose own context never held sift's tools: the session had no"))
        #expect(!lacking.contains("the durable fix is the agent definition"))

        let holding = try TranscriptAudit.render(projectsDirectory: Self.projects(session: Self.sessionHoldingTheIndex, subagents: [Self.refusedWithNoToolList]))
        #expect(!holding.contains("in a session whose own context never held sift's tools"))
        #expect(holding.contains("the durable fix is the agent definition that spawned it"))
    }

    /// Where the session's own transcript records its start hook unable to run the binary, the report says that is why the server was missing.
    @Test
    func aSessionWhoseStartHookCouldNotRunTheBinarySaysSo() throws {
        let session = [
            Self.hookFailure(),
            Self.delta(added: ["WebFetch"], failed: ["sift"]),
            Self.snapshot(tools: ["Read", "Bash", "ToolSearch"]),
        ]
        let root = try Self.projects(session: session, subagents: [Self.refusedWithNoToolList, [Self.fullListWithoutIndex, Self.coldRead]])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("unreachable    2"))
        #expect(report.contains("All 2 were in a session whose SessionStart hook could not run the sift binary (exit 127):"))
        #expect(!report.contains("the durable fix is the agent definition"))

        // Without the hook's line the same session is still explained by its server, and nothing is said about the binary.
        let unexplained = try TranscriptAudit.render(projectsDirectory: Self.projects(session: Array(session.dropFirst()), subagents: [Self.refusedWithNoToolList]))
        #expect(unexplained.contains("in a session whose own context never held sift's tools"))
        #expect(!unexplained.contains("could not run the sift binary"))
    }

    /// A context with no sift MCP tools that reached the index on the CLI is named apart from the bucket, since the bucket is where a reader looks for toolless contexts and it is not in it.
    @Test
    func contextsThatReachedTheIndexOnTheCLIAreNotedApartFromTheBucket() throws {
        let cli = TranscriptFixture.toolUse("Bash", id: "b1", input: ["command": "sift where SummaryState"])
        let root = try Self.projects(session: Self.sessionHoldingTheIndex, subagents: [[Self.fullListWithoutIndex, cli, Self.coldRead]])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("unreachable    0"))
        #expect(report.contains("(1 context held no sift MCP tools but ran the `sift` CLI, so the index was"))
        #expect(report.contains("   within its reach: it is not unreachable, and its lookups stay in the share.)"))
    }
}
