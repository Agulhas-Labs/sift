//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A pointer at a call the hook made itself, answering a lookup in place, says so, and one at a call the context made is worded as it was.
@Suite(.temporaryDirectories)
struct InFlightHookMadeTests {
    private static var heldFromHook: String {
        "sift held this lookup back — already answered beside this: `where Shell`, whose answer covers it. Re-run the identical command for the raw output."
    }

    private static var heldFromContext: String {
        "sift held this lookup back — already called in this context: `where Shell`, whose answer covers it. Re-run the identical command for the raw output."
    }

    private static func use(of id: String) -> String {
        #"{"isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"Grep","input":{"pattern":"Shell"},"caller":{"type":"direct"}}]}}"#
    }

    private static func whereUse(of id: String) -> String {
        #"{"isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"mcp__sift__where","input":{"symbol":"Shell"},"caller":{"type":"direct"}}]}}"#
    }

    /// The hook's decision on a Grep it answers in place with a `where` of `target`, as the one under `toolu_grep` in `fixture`'s transcript.
    private func answerGrepInPlace(_ fixture: InFlightPointerTests.Fixture, target: String = "Shell", sourceLocation: SourceLocation = #_sourceLocation) throws {
        let answered = InPlaceAnswerer.Answered(
            reason: "answered",
            calls: [InPlaceAnswerer.Call(tool: "where", target: target, bytes: WorthAnsweringFixture.answerBytes)],
            root: CallerRoot.root(forCallerIn: fixture.repo.path) ?? fixture.repo.path,
            milliseconds: 1
        )
        let verdict = try PreToolUseCommand.outcome(
            to: fixture.grep(sourceLocation: sourceLocation),
            session: "s1",
            context: AdviceContext.resolve(sessionID: "s1", transcriptPath: fixture.transcript),
            payload: ["session_id": "s1", "transcript_path": fixture.transcript, "tool_use_id": "toolu_grep"],
            cwd: fixture.repo.path,
            ledger: fixture.ledger,
            usage: UsageLog(fileURL: fixture.directory.appendingPathComponent("usage.jsonl")),
            suppressions: SuppressionLog(fileURL: fixture.suppressionsURL),
            answerer: { _, _, _ in .answered(answered) }
        ).verdict
        #expect(verdict.token == "in-place", "\(verdict.line)", sourceLocation: sourceLocation)
    }

    @Test
    func aLookupBesideAnInPlaceAnswerIsHeldBackAsAnsweredBesideThis() throws {
        let fixture = try InFlightPointerTests.Fixture(lines: [Self.use(of: "toolu_grep")])
        try answerGrepInPlace(fixture)
        let verdict = try fixture.judge(fixture.shellGrep("grep -rn Shell Sources/App"))

        #expect(verdict.token == "held", "\(verdict.line)")
        #expect(verdict.reason == Self.heldFromHook)
        #expect(verdict.reason?.contains("already called") == false)
    }

    @Test
    func aCallTheContextMadeIsStillHeldBackAsCalled() throws {
        let fixture = try InFlightPointerTests.Fixture(lines: [Self.use(of: "toolu_where")])
        fixture.take(tool: "\(IndexToolName.prefix)where", input: ["symbol": "Shell"])
        let verdict = try fixture.judge(fixture.shellGrep("grep -rn Shell Sources/App"))

        #expect(verdict.token == "held", "\(verdict.line)")
        #expect(verdict.reason == Self.heldFromContext)
    }

    @Test
    func aLedgerWrittenBeforeTheKindWasKeptReadsAsMadeByTheContext() throws {
        let stored = Data(#"{"calls":["where Shell"],"callNotes":{"where Shell":{"id":"toolu_old","noted":1000}}}"#.utf8)
        let state = try JSONDecoder().decode(AdviceLedger.State.self, from: stored)

        #expect(state.callNotes["where Shell"] == AdviceLedger.CallNote(id: "toolu_old", noted: 1000, hookMade: false))
        #expect(state.callNotes["where Shell"]?.hookMade == false)
    }

    @Test
    func theKindSurvivesTheLedgerBeingWrittenAndRead() throws {
        let note = AdviceLedger.CallNote(id: "toolu_a", noted: 5, hookMade: true)
        let again = try JSONDecoder().decode(AdviceLedger.CallNote.self, from: JSONEncoder().encode(note))

        #expect(again.hookMade)
    }

    @Test
    func aPointerNamingBothKindsCallsOnlyTheContextsOwn() {
        let reason = IndexSuggestion.heldBackReason(calls: ["where Shell", "digest Shell"], hookMade: ["digest Shell"])

        #expect(reason == "sift held this lookup back — already called in this context: `where Shell`, whose answer covers it. Also answered beside this: `digest Shell`. Re-run the identical command for the raw output.")
    }

    @Test
    func aLookupBesideBothKindsOfCallIsHeldBackNamingEachInItsOwnWords() throws {
        let fixture = try InFlightPointerTests.Fixture(lines: [Self.whereUse(of: "toolu_where"), Self.use(of: "toolu_grep")])
        try answerGrepInPlace(fixture, target: "Depot")
        fixture.take(tool: "\(IndexToolName.prefix)where", input: ["symbol": "Shell"])
        let verdict = try fixture.judge(fixture.shellGrep("grep -rnE 'Shell|Depot' Sources/App"))

        #expect(verdict.token == "held", "\(verdict.line)")
        #expect(verdict.reason == "sift held this lookup back — already called in this context: `where Shell`, whose answer covers it. Also answered beside this: `where Depot`. Re-run the identical command for the raw output.")
    }

    @Test
    func theScanRecognisesBothWordingsOfThePointer() {
        for reason in [Self.heldFromHook, Self.heldFromContext] {
            var events: [TranscriptEvent] = []
            var state = TranscriptScanState()
            let pending = PendingRead(lookup: .indexed, path: "", openedPath: false, counted: false, key: "grep -rn Shell Sources")

            #expect(RefusalMemory.heldBack(reason, pending: pending, events: &events, in: &state))
            #expect(state.hookDenied.contains("grep -rn Shell Sources"))
        }
    }
}
