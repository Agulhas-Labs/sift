//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A refusal offering a build's `sift run --` wrapping names the identical re-run as its way through and never calls it free: the re-run costs a round trip and returns the command's whole output.
///
/// The in-place answer's closing line is held to the same by `InPlaceClosingLineClaimsTests`.
@Suite(.temporaryDirectories)
struct RefusalRerunCostWordingTests {
    /// The deny the hook writes for `shell`, run from Bash in permission mode `default` with no rule allowing the wrapping, decoded from its output.
    private static func denial(_ shell: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any] {
        let scratch = try TemporaryDirectory.make("rerun-wording")
        let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": shell], "session_id": "s1", "permission_mode": "default"]
        let lookup = try #require(PreToolUseCommand.lookup(
            command: nil,
            payload: payload,
            in: "/repo",
            noting: SuppressionLog(fileURL: scratch.appendingPathComponent("suppressions.jsonl")),
            couldAnswer: { _, _ in true }
        ), sourceLocation: sourceLocation)
        let outcome = PreToolUseCommand.outcome(
            to: lookup,
            session: "s1",
            context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: nil),
            payload: payload,
            cwd: "/repo",
            ledger: AdviceLedger(directory: scratch.appendingPathComponent("advice")),
            usage: UsageLog(fileURL: scratch.appendingPathComponent("usage.jsonl")),
            suppressions: SuppressionLog(fileURL: scratch.appendingPathComponent("suppressions.jsonl")),
            answerer: { _, _, _ in .withheld(.notExact) },
            serverPresence: { _, _ in false },
            runPermission: { _ in WrappedRunPermission(allowed: [], vetoed: []) }
        )
        let object = try JSONSerialization.jsonObject(with: Data(#require(outcome.json, sourceLocation: sourceLocation).utf8)) as? [String: Any]
        return try #require(object?["hookSpecificOutput"] as? [String: Any], sourceLocation: sourceLocation)
    }

    /// The deny the hook serves for a raw build still offers the identical re-run, and says what it returns rather than that it costs nothing.
    @Test(arguments: ["swift test", "swift build && swift test", "cd Kit && swift test"])
    func theServedRefusalNeverCallsTheRerunFree(shell: String) throws {
        let output = try Self.denial(shell)
        let reason = try #require(output["permissionDecisionReason"] as? String)

        #expect(output["permissionDecision"] as? String == "deny")
        #expect(reason.contains("re-run this exact command and it will be allowed"))
        #expect(reason.contains("That re-run returns the command's whole output."))
        #expect(!reason.contains("costs nothing"))
    }

    /// The refusal text itself, built from each shape of the wrapping's offer, says the same.
    @Test(arguments: ["swift test", "swift build\nswift test", "swift test; git add -A && git commit -q -m 'msg'"])
    func theRefusalTextNeverCallsTheRerunFree(command: String) throws {
        let suggestion = try #require(RunAdvice.suggestion(for: command))

        let reason = PreToolUseCommand.reason(for: suggestion)

        #expect(reason.hasSuffix("That re-run returns the command's whole output. This asks once per command."))
        #expect(!reason.contains("costs nothing"))
    }
}
