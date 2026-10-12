//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// Covers how a rewritten build is marked: the line the hook hands Claude Code is the plain wrapping, which any `sift` accepts and every allow rule matches, and the hook says it ran the build in the context note of the same output.
@Suite(.temporaryDirectories)
struct RewriteMarkTests {
    /// What the hook amends `shell` to in permission mode `mode`, or `nil` where it amends nothing.
    private static func amended(
        _ shell: String,
        mode: String = "auto",
        permission: WrappedRunPermission = WrappedRunPermission(allowed: [], vetoed: []),
        scratch: URL,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Amendment? {
        let ledger = AdviceLedger(directory: scratch.appendingPathComponent("advice"))
        let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": shell], "session_id": "s1", "permission_mode": mode]
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
            ledger: ledger,
            usage: UsageLog(fileURL: scratch.appendingPathComponent("usage.jsonl")),
            suppressions: SuppressionLog(fileURL: scratch.appendingPathComponent("suppressions.jsonl")),
            answerer: { _, _, _ in .withheld(.notExact) },
            serverPresence: { _, _ in false },
            runPermission: { _ in permission }
        )
        guard let json = outcome.json else { return nil }
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let specific = object?["hookSpecificOutput"] as? [String: Any]
        guard let command = (specific?["updatedInput"] as? [String: Any])?["command"] as? String else { return nil }
        return Amendment(command: command, context: specific?["additionalContext"] as? String, decision: specific?["permissionDecision"])
    }

    /// One in-process run of a stand-in build handed `arguments`: what it printed.
    private static func printed(running arguments: [String], in directory: URL) throws -> String {
        let script = directory.appendingPathComponent("swift")
        try "#!/bin/sh\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let recorded = RecordedOutput()
        var command = try RunCommand.parse(["--", script.path] + arguments)
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory
        command.output = recorded.output
        do {
            try command.run()
        } catch is ExitCode {}
        return recorded.printed
    }

    /// The rewritten line adds no word (no mark that an older `sift` could reject, nothing before the wrapper that would keep a prefix allow rule from matching), and the same output carries the notice as context, with no permission decision of its own.
    @Test
    func theRewriteAddsNoWordToTheLineAndCarriesTheNoticeAsContext() throws {
        let scratch = try TemporaryDirectory.make("rewrite-mark")

        let amendment = try #require(try Self.amended("swift test --filter Foo", scratch: scratch))

        #expect(amendment.command == "sift run -- swift test --filter Foo")
        #expect(!amendment.command.contains(RunRewrite.marker))
        #expect(amendment.context == RunRewrite.notice(forCommand: "swift test --filter Foo"))
        #expect(amendment.context?.contains("swift test --filter Foo 2>&1 | cat") == true)
        #expect(amendment.decision == nil)
    }

    /// Whichever `sift` the shell resolves, the line is the one the installed allow rules were written for, so a session that asks runs it without a prompt.
    @Test(arguments: ["swift build", "swift test --filter Foo", "cd Kit && xcodebuild -scheme Gizmo test", "swiftlint"])
    func theRewriteMatchesTheInstalledAllowRulesWhicheverSiftRunsIt(shell: String) throws {
        let scratch = try TemporaryDirectory.make("rewrite-mark")
        let installed = WrappedRunPermission(allowed: WrappedRunPermission.patterns(in: RunAllowRules.rules), vetoed: [])

        let amendment = try #require(try Self.amended(shell, mode: "default", permission: installed, scratch: scratch))
        let legs = try #require(RunAdvice.inPlaceRewrite(of: shell)).legs

        #expect(amendment.command.contains("sift run -- "))
        #expect(installed.addsNoPrompt(legs: legs, mode: "default"))
        #expect(legs.allSatisfy { !$0.contains(RunRewrite.marker) })
    }

    /// An exact allow rule written for the plain wrapping speaks for the rewrite, since nothing is added to it.
    @Test
    func anExactAllowRuleForTheWrappingStillAllowsTheRewrite() throws {
        let scratch = try TemporaryDirectory.make("rewrite-mark")
        let allowing = WrappedRunPermission(allowed: ["sift run -- swift test"], vetoed: [])

        #expect(try Self.amended("swift test", mode: "default", permission: allowing, scratch: scratch)?.command == "sift run -- swift test")
    }

    /// An exact deny rule written for the plain wrapping still vetoes: nothing is added to the line, so the rule keeps speaking for the rewrite, and the build is neither rewritten nor noted.
    @Test
    func anExactDenyRuleForTheUnmarkedFormStillSpeaksForTheRewrite() throws {
        let scratch = try TemporaryDirectory.make("rewrite-mark")
        let denying = WrappedRunPermission(allowed: [], vetoed: ["sift run -- swift test"])

        #expect(try Self.amended("swift test", permission: denying, scratch: scratch) == nil)
    }

    /// A line of several builds carries one note, for the first statement, so it is said once.
    @Test
    func aCompoundLineIsNotedForItsFirstWrappedStatementOnly() throws {
        let scratch = try TemporaryDirectory.make("rewrite-mark")

        let amendment = try #require(try Self.amended("swift build && xcodebuild -scheme Gizmo test", scratch: scratch))

        #expect(amendment.command == "sift run -- swift build && sift run -- xcodebuild -scheme Gizmo test")
        #expect(amendment.context == RunRewrite.notice(forCommand: "swift build"))
    }

    /// A build the hook refuses or lets through unwrapped carries no note, because nothing was rewritten.
    @Test
    func aBuildThatIsNotRewrittenCarriesNoNote() throws {
        let scratch = try TemporaryDirectory.make("rewrite-mark")
        let denying = WrappedRunPermission(allowed: [], vetoed: ["sift run *"])

        #expect(try Self.amended("swift test", mode: "default", scratch: scratch) == nil)
        #expect(try Self.amended("swift test", permission: denying, scratch: scratch) == nil)
    }

    /// A build rewritten by an older hook still ends in the old mark, and `sift run` still reads it as one.
    @Test
    func theOldMarkOnTheCommandStillPrintsTheNotice() throws {
        let directory = try TemporaryDirectory.make("rewrite-old-mark")

        let printed = try Self.printed(running: ["test", RunRewrite.marker], in: directory)

        #expect(printed.hasPrefix("sift: the hook rewrote this to"))
    }

    /// A `sift run` typed by hand carries no mark and prints no notice.
    @Test
    func aRunTypedByHandPrintsNoNotice() throws {
        let directory = try TemporaryDirectory.make("rewrite-typed")

        let printed = try Self.printed(running: ["test"], in: directory)

        #expect(!printed.contains("the hook ran this"))
    }
}

private extension RewriteMarkTests {
    /// What the hook hands Claude Code for a build it amends: the command to run instead, the context note beside it, and any permission decision.
    struct Amendment {
        let command: String
        let context: String?
        let decision: Any?
    }
}
