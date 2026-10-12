//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// Covers the line the hook rewrites a build to, which carries no mark of its own, and that the permission verdicts it had are unchanged.
@Suite(.temporaryDirectories)
struct VisibleBuildRewriteTests {
    /// What the hook makes of `shell` run from Bash in permission mode `mode`, judged against `permission`.
    private static func judged(
        _ shell: String,
        mode: String,
        permission: WrappedRunPermission,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> (json: String?, verdict: PreToolUseCommand.Verdict) {
        let scratch = try TemporaryDirectory.make("visible-rewrite")
        let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": shell], "session_id": "s1", "permission_mode": mode]
        let lookup = try #require(PreToolUseCommand.lookup(
            command: nil,
            payload: payload,
            in: "/repo",
            noting: SuppressionLog(fileURL: scratch.appendingPathComponent("suppressions.jsonl")),
            couldAnswer: { _, _ in true }
        ), sourceLocation: sourceLocation)
        return PreToolUseCommand.outcome(
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
            runPermission: { _ in permission }
        )
    }

    /// The command the hook's output replaces the call's with, or `nil` where it amends nothing.
    private static func amendedCommand(_ json: String?) throws -> String? {
        guard let json else { return nil }
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let specific = object?["hookSpecificOutput"] as? [String: Any]
        return (specific?["updatedInput"] as? [String: Any])?["command"] as? String
    }

    /// The permission the hook reads where the rules `install-hook` offers are the only ones.
    private static let installed = WrappedRunPermission(allowed: WrappedRunPermission.patterns(in: RunAllowRules.rules), vetoed: [])

    /// A build rewritten where nobody is asked is wrapped at each statement, ahead of a comment or a group's closer, with the rest of the line as written and no word added.
    @Test(arguments: [
        ("xcodebuild test -scheme Gizmo -only-testing:GizmoTests/Probe", "sift run -- xcodebuild test -scheme Gizmo -only-testing:GizmoTests/Probe"),
        ("swift build && swift test", "sift run -- swift build && sift run -- swift test"),
        ("(cd Kit && swift test)", "(cd Kit && sift run -- swift test)"),
        ("swift build # the app", "sift run -- swift build # the app"),
        ("swift test --filter ')'  ", "sift run -- swift test --filter ')'  "),
    ])
    func aRewrittenBuildIsWrappedAtEachStatementWithNothingAdded(shell: String, line: String) throws {
        let outcome = try Self.judged(shell, mode: "auto", permission: WrappedRunPermission(allowed: [], vetoed: []))

        #expect(outcome.verdict.token == "amended")
        #expect(try Self.amendedCommand(outcome.json) == line)
    }

    /// The call the verdict names is the wrapping as anyone would type it, and the command the hook hands Claude Code is the same wrapping.
    @Test
    func theVerdictAndTheRefusalNameTheUnmarkedWrapping() throws {
        let amended = try Self.judged("swift test", mode: "auto", permission: WrappedRunPermission(allowed: [], vetoed: []))
        let denied = try Self.judged("swift test", mode: "default", permission: WrappedRunPermission(allowed: [], vetoed: []))

        #expect(amended.verdict.line == "amended\tsift run -- swift test\tRunAdvice")
        #expect(denied.verdict.token == "deny")
        #expect(denied.verdict.reason?.contains(RunRewrite.marker) == false)
        #expect(denied.verdict.reason?.contains("sift run -- swift test") == true)
    }

    /// The installed prefix rules and a broad run rule cover every leg, so a session that asks has its build rewritten.
    @Test(arguments: ["swift build", "swift test --filter 'Foo|Bar'", "cd Kit && swift test", "(cd Kit && swift test)", "xcodebuild test -scheme Gizmo -quiet", "swiftlint"])
    func everyLegOfARewriteMatchesTheInstalledAllowRules(shell: String) throws {
        let rewrite = try #require(RunAdvice.inPlaceRewrite(of: shell))
        let broad = WrappedRunPermission(allowed: WrappedRunPermission.patterns(in: ["Bash(sift run:*)"]), vetoed: [])

        #expect(rewrite.legs == RunAdvice.wrappedLegs(of: shell))
        #expect(Self.installed.addsNoPrompt(legs: rewrite.legs, mode: "default"))
        #expect(broad.addsNoPrompt(legs: rewrite.legs, mode: "default"))
        #expect(try Self.judged(shell, mode: "default", permission: Self.installed).verdict.token == "amended")
    }

    /// The line names an escape the hook really lets through as written, and stays short enough to read past.
    @Test
    func theNoticeNamesAnEscapeTheHookLetsThrough() {
        for build in ["swift build", "swift test --filter Foo", "xcodebuild test -scheme Gizmo"] {
            let notice = RunRewrite.notice(for: build.split(separator: " ").map(String.init))
            #expect(notice.count <= 150)
            #expect(notice.contains("`\(build) 2>&1 | cat`"))
            #expect(notice.contains("raw:"))
            #expect(RunAdvice.suggestion(for: build + " 2>&1 | cat") == nil)
        }
    }

    /// An argument the shell would split or expand is quoted, so the command in the notice is the one that was written.
    @Test
    func theNoticeQuotesWhatTheShellWouldReadApart() {
        let notice = RunRewrite.notice(for: ["swift", "test", "--filter", "Foo|Bar", "it's"])

        #expect(notice.contains("`swift test --filter 'Foo|Bar' 'it'\\''s' 2>&1 | cat`"))
    }
}
