//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers which conversation a piece of advice is keyed to — the fix for subagents inheriting their parent's spent budget.
struct AdviceContextTests {
    @Test
    func aSessionTranscriptIsKeyedOnTheSessionItself() {
        let context = AdviceContext.resolve(
            sessionID: "bbbd4b58",
            transcriptPath: "/Users/dev/.claude/projects/-repo/bbbd4b58.jsonl"
        )

        #expect(context.key == "bbbd4b58")
        #expect(context.isSubagent == false)
    }

    /// The shape verified against a real sidechain transcript: the parent's session id, the agent's own file.
    @Test
    func aSubagentGetsItsOwnKeyDespiteCarryingTheParentSessionID() {
        let context = AdviceContext.resolve(
            sessionID: "bbbd4b58",
            transcriptPath: "/Users/dev/.claude/projects/-repo/bbbd4b58/subagents/agent-a4a2b25.jsonl"
        )

        #expect(context.isSubagent)
        #expect(context.key != "bbbd4b58")
    }

    /// The defect itself: two subagents of one parent must not share a budget with it or with each other.
    @Test
    func twoSubagentsOfOneParentAreThreeDistinctContexts() {
        let parent = AdviceContext.resolve(sessionID: "s", transcriptPath: "/p/s.jsonl")
        let first = AdviceContext.resolve(sessionID: "s", transcriptPath: "/p/s/subagents/agent-aaa.jsonl")
        let second = AdviceContext.resolve(sessionID: "s", transcriptPath: "/p/s/subagents/agent-bbb.jsonl")

        #expect(Set([parent.key, first.key, second.key]).count == 3)
    }

    /// Degrading to the session-wide shared key beats degrading to a key that changes per call, which would refuse everything.
    @Test
    func aMissingOrUnrecognisedTranscriptFallsBackToTheSession() {
        for path in [nil, "", "/p/notes.txt", "/p/agent-.jsonl"] {
            let context = AdviceContext.resolve(sessionID: "s", transcriptPath: path)
            #expect(context.key == "s")
            #expect(context.isSubagent == false)
        }
    }

    /// A subagent id is only unique within its run, so the key carries the session too.
    @Test
    func theSameAgentIDUnderTwoSessionsIsTwoContexts() {
        let first = AdviceContext.resolve(sessionID: "one", transcriptPath: "/p/one/subagents/agent-aaa.jsonl")
        let second = AdviceContext.resolve(sessionID: "two", transcriptPath: "/p/two/subagents/agent-aaa.jsonl")

        #expect(first.key != second.key)
    }

    /// The payload shape Claude Code sends: a subagent's call carries the *parent's* transcript path, and `agent_id` is the only field that tells the contexts apart.
    ///
    /// Keying on the path alone shares the parent's budget with every subagent, so a subagent's whole sweep can draw not one nudge.
    @Test
    func theAgentIDScopesTheKeyWhenTheTranscriptPathNamesTheParent() {
        let parent = AdviceContext.resolve(sessionID: "s", transcriptPath: "/p/s.jsonl")
        let agent = AdviceContext.resolve(sessionID: "s", transcriptPath: "/p/s.jsonl", agentID: "a5a49dac1f865b0ff")

        #expect(agent.isSubagent)
        #expect(agent.key != parent.key)
    }

    /// Two subagents whose payloads differ only in `agent_id` spend two budgets.
    @Test
    func twoAgentIDsUnderOneParentAreTwoContexts() {
        let first = AdviceContext.resolve(sessionID: "s", transcriptPath: "/p/s.jsonl", agentID: "aaa")
        let second = AdviceContext.resolve(sessionID: "s", transcriptPath: "/p/s.jsonl", agentID: "bbb")

        #expect(first.key != second.key)
    }

    /// An empty `agent_id` is the parent's own call, not a nameless subagent.
    @Test
    func anEmptyAgentIDFallsBackToTheOtherDiscriminators() {
        let context = AdviceContext.resolve(sessionID: "s", transcriptPath: "/p/s.jsonl", agentID: "")

        #expect(context.key == "s")
        #expect(context.isSubagent == false)
    }

    /// Whichever discriminator fires, one subagent is one context — the ledger file must not fork when a future version fixes the transcript path.
    @Test
    func theAgentIDAndTheTranscriptPathAgreeOnTheKey() {
        let byID = AdviceContext.resolve(sessionID: "s", transcriptPath: "/p/s.jsonl", agentID: "aaa")
        let byPath = AdviceContext.resolve(sessionID: "s", transcriptPath: "/p/s/subagents/agent-aaa.jsonl")

        #expect(byID.key == byPath.key)
    }
}
