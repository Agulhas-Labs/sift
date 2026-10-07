//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the two shapes the primer has to be delivered in, since one of them reaching a subagent as bare text would mean it arrives as nothing at all.
struct HookOutputTests {
    @Test
    func aSessionStartHookGetsThePrimerAsPlainText() {
        #expect(HookOutput.render("primer text", event: "SessionStart") == "primer text")
    }

    /// `SubagentStart` reads its context out of a JSON payload rather than from stdout, so the same text has to be wrapped — printing it bare would be silently discarded, which is exactly the failure mode that leaves subagents with no guidance.
    @Test
    func aSubagentStartHookGetsThePrimerAsAContextPayload() throws {
        let rendered = HookOutput.render("primer text", event: "SubagentStart")
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        )
        let specific = try #require(object["hookSpecificOutput"] as? [String: Any])

        #expect(specific["hookEventName"] as? String == "SubagentStart")
        #expect(specific["additionalContext"] as? String == "primer text")
    }

    /// Run by hand, or by a hook event this does not know, the readable form is the right answer.
    @Test
    func anAbsentOrUnknownEventFallsBackToPlainText() {
        #expect(HookOutput.render("primer text", event: nil) == "primer text")
        #expect(HookOutput.render("primer text", event: "Setup") == "primer text")
    }

    /// The primer is markdown with slashes in every path it names; escaping them would put `\/` in front of the model and make the roots it lists harder to copy.
    @Test
    func pathsInTheContextAreNotSlashEscaped() {
        let rendered = HookOutput.render("root: /Users/dev/Developer/App", event: "SubagentStart")

        #expect(rendered.contains("/Users/dev/Developer/App"))
        #expect(!rendered.contains("\\/"))
    }

    /// A `PreToolUse` refusal is a permission decision, not injected context: context arrives beside the command's own output, and a model already holding the answer has no reason to go back for a better one.
    @Test
    func aPreToolUseDenialIsAPermissionDecision() throws {
        let rendered = try #require(HookOutput.preToolUseDenial(reason: "use digest SummaryState"))
        let object = try #require(JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any])
        let specific = try #require(object["hookSpecificOutput"] as? [String: Any])

        #expect(specific["hookEventName"] as? String == "PreToolUse")
        #expect(specific["permissionDecision"] as? String == "deny")
        #expect(specific["permissionDecisionReason"] as? String == "use digest SummaryState")
        // Nothing else: `additionalContext` alongside a denial would be two channels saying one thing.
        #expect(specific["additionalContext"] == nil)
    }

    /// An amendment carries the whole input and **no permission decision**: it corrects one argument, and saying `"allow"` beside it would silently approve every call this hook is registered for.
    @Test
    func anAmendmentCarriesTheWholeInputAndDecidesNoPermission() throws {
        let rendered = try #require(HookOutput.preToolUseAmendment(
            input: ["target": "RootResolver", "root": "/w/repo"]
        ))
        let object = try #require(JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any])
        let specific = try #require(object["hookSpecificOutput"] as? [String: Any])
        let input = try #require(specific["updatedInput"] as? [String: Any])

        #expect(specific["hookEventName"] as? String == "PreToolUse")
        #expect(input["target"] as? String == "RootResolver")
        #expect(input["root"] as? String == "/w/repo")
        #expect(specific["permissionDecision"] == nil)
        #expect(specific["permissionDecisionReason"] == nil)
    }

    /// An input this cannot encode produces nothing rather than a half-written envelope: silence leaves the call as it was, which is the safe direction for a hook that decides whether a tool runs.
    @Test
    func anUnencodableAmendmentPrintsNothing() {
        #expect(HookOutput.preToolUseAmendment(input: ["target": Date()]) == nil)
    }

    /// The root of a repository is a path, and a `\/` inside it would reach the server as a directory that does not exist.
    @Test
    func anAmendedRootIsNotSlashEscaped() throws {
        let rendered = try #require(HookOutput.preToolUseAmendment(input: ["root": "/Users/dev/Developer/App"]))

        #expect(rendered.contains("/Users/dev/Developer/App"))
        #expect(!rendered.contains("\\/"))
    }

    /// The reason names paths and calls, and a `\/` in front of the model is noise in the one line it is meant to act on.
    @Test
    func aDenialReasonIsNotSlashEscaped() throws {
        let rendered = try #require(HookOutput.preToolUseDenial(reason: "digest Sources/App/View.swift"))

        #expect(rendered.contains("Sources/App/View.swift"))
        #expect(!rendered.contains("\\/"))
    }
}
