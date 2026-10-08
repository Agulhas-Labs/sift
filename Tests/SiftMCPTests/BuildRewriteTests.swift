//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// Covers the hook rewriting a build to `sift run -- …` in place, and where it keeps refusing with the wrapping instead because the rewrite could reach the user as a prompt.
@Suite(.temporaryDirectories)
struct BuildRewriteTests {
    /// What the hook makes of `shell` run from Bash in permission mode `mode`, judged against `permission`.
    private static func judged(
        _ shell: String,
        mode: String?,
        permission: WrappedRunPermission = WrappedRunPermission(allowed: [], vetoed: []),
        ledger: AdviceLedger? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> (json: String?, verdict: PreToolUseCommand.Verdict) {
        let scratch = try TemporaryDirectory.make("rewrite")
        var payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": shell, "description": "Run the tests"], "session_id": "s1"]
        if let mode {
            payload["permission_mode"] = mode
        }
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
            ledger: ledger ?? AdviceLedger(directory: scratch.appendingPathComponent("advice")),
            usage: UsageLog(fileURL: scratch.appendingPathComponent("usage.jsonl")),
            suppressions: SuppressionLog(fileURL: scratch.appendingPathComponent("suppressions.jsonl")),
            answerer: { _, _, _ in .withheld(.notExact) },
            serverPresence: { _, _ in false },
            runPermission: { _ in permission }
        )
    }

    /// The hook's output decoded, for what it amends and whether it decides anything.
    private static func specific(_ json: String?, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(#require(json, sourceLocation: sourceLocation).utf8)) as? [String: Any]
        return try #require(object?["hookSpecificOutput"] as? [String: Any], sourceLocation: sourceLocation)
    }

    /// In a mode that asks nobody, the build runs wrapped in the same turn: the command is replaced, the rest of the input kept, and no permission decision is made.
    @Test(arguments: ["auto", "bypassPermissions"])
    func aBuildIsRewrittenInPlaceWhereNoPromptCanFollow(mode: String) throws {
        let outcome = try Self.judged("swift test --filter Foo", mode: mode)

        #expect(outcome.verdict.line == "amended\tsift run -- swift test --filter Foo\tRunAdvice")
        let output = try Self.specific(outcome.json)
        let input = try #require(output["updatedInput"] as? [String: Any])
        #expect(input["command"] as? String == "sift run -- swift test --filter Foo")
        #expect(input["description"] as? String == "Run the tests")
        #expect(output["permissionDecision"] == nil)
    }

    /// A rewrite interrupts nothing, so it spends no ledger: the loop's next identical run is rewritten again, never let through raw.
    @Test
    func everyRunOfTheBuildIsRewritten() throws {
        let ledger = try AdviceLedger(directory: TemporaryDirectory.make("rewrite-ledger").appendingPathComponent("advice"))
        let first = try Self.judged("swift test", mode: "auto", ledger: ledger)
        let second = try Self.judged("swift test", mode: "auto", ledger: ledger)

        #expect(first.verdict.token == "amended")
        #expect(second.verdict.token == "amended")
    }

    /// Where the user is asked about what no rule allows, the rewrite could turn an allowed build into a prompt, so the build is refused with its wrapping as before.
    @Test(arguments: [("default", [String]()), ("acceptEdits", ["swift test", "swift test *"]), ("default", ["sift build *"])])
    func aBuildTheRewriteCouldPromptForIsStillDenied(mode: String, allowed: [String]) throws {
        let outcome = try Self.judged("swift test", mode: mode, permission: WrappedRunPermission(allowed: allowed, vetoed: []))

        #expect(outcome.verdict.line == "deny\tsift run -- swift test\tRunAdvice")
        #expect(try Self.specific(outcome.json)["permissionDecision"] as? String == "deny")
    }

    /// An allow rule covering the rewritten command is what lets a session that asks have its build rewritten.
    @Test
    func anAllowRuleForTheWrappedCommandRewritesInAnAskingMode() throws {
        let outcome = try Self.judged("swift build", mode: "default", permission: WrappedRunPermission(allowed: ["sift run *"], vetoed: []))

        #expect(outcome.verdict.token == "amended")
    }

    /// An ask or deny rule applies whatever a mode or a hook says, so one matching the wrapped command keeps the refusal even where nobody would otherwise be asked.
    @Test
    func anAskRuleOnTheWrappedCommandKeepsTheRefusal() throws {
        let outcome = try Self.judged("swift test", mode: "bypassPermissions", permission: WrappedRunPermission(allowed: ["*"], vetoed: ["sift *"]))

        #expect(outcome.verdict.token == "deny")
    }

    /// A compound line is rewritten where the wrapping stands in front of its build leg alone, the rest of the line as written, and it is that leg the rules are matched against.
    @Test
    func aCompoundLineIsRewrittenAtItsBuildLeg() throws {
        let line = "cd App && xcodebuild -scheme Gizmo test"
        let outcome = try Self.judged(line, mode: "default", permission: WrappedRunPermission(allowed: ["sift run -- xcodebuild *"], vetoed: []))

        #expect(RunAdvice.wrappedLegs(of: line) == ["sift run -- xcodebuild -scheme Gizmo test"])
        #expect(outcome.verdict.token == "amended")
        let input = try #require(try Self.specific(outcome.json)["updatedInput"] as? [String: Any])
        #expect(input["command"] as? String == "cd App && sift run -- xcodebuild -scheme Gizmo test")
    }

    /// The shapes the wrapping already leaves alone draw no rewrite either.
    @Test(arguments: ["xcodebuild build-for-testing -scheme Gizmo", "swiftlint lint --quiet", "swift test > test.log", "swift test 2>&1 | tail -40"])
    func anExemptBuildIsNotRewritten(shell: String) {
        #expect(RunAdvice.suggestion(for: shell) == nil)
        #expect(RunAdvice.wrappedLegs(of: shell).isEmpty)
    }

    /// The rules are read from the user's, the project's shared and local, and the managed settings; a legacy prefix rule covers the prefix alone or followed by arguments.
    @Test
    func theRulesAreReadFromEverySettingsFile() throws {
        let root = try TemporaryDirectory.make("rewrite-settings")
        let home = root.appendingPathComponent("home")
        let project = root.appendingPathComponent("project")
        let managed = root.appendingPathComponent("managed-settings.json")
        func write(_ json: String, to file: URL) throws {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(json.utf8).write(to: file)
        }
        try write(#"{"permissions":{"allow":["Bash(sift run:*)","Read"]}}"#, to: home.appendingPathComponent(".claude/settings.json"))
        try write(#"{"permissions":{"ask":["Bash(sift run -- xcodebuild *)"]}}"#, to: project.appendingPathComponent(".claude/settings.json"))
        try write(#"{"permissions":{"deny":["Bash(sift run -- swift package *)"]}}"#, to: project.appendingPathComponent(".claude/settings.local.json"))
        try write(#"{"permissions":{"allow":["Bash"]}}"#, to: managed)

        let permission = WrappedRunPermission.load(project: project.path, environment: ["HOME": home.path], managed: managed.path)

        #expect(permission.allowed == ["sift run", "sift run *", "*"])
        #expect(permission.vetoed == ["sift run -- xcodebuild *", "sift run -- swift package *"])
        #expect(permission.addsNoPrompt(legs: ["sift run -- swift test"], mode: "default"))
        #expect(!permission.addsNoPrompt(legs: ["sift run -- xcodebuild test"], mode: "auto"))
        #expect(!WrappedRunPermission.load(project: nil, environment: ["HOME": project.path], managed: managed.path + ".missing")
            .addsNoPrompt(legs: ["sift run -- swift test"], mode: "default"))
    }

    /// A rule's `*` stands for any run of characters, none included, and the rest of the rule must match the command whole.
    @Test
    func aPatternMatchesTheWholeCommand() {
        #expect(WrappedRunPermission.matches("sift run -- swift test", pattern: "sift run *"))
        #expect(WrappedRunPermission.matches("sift run -- swift test", pattern: "*swift test"))
        #expect(WrappedRunPermission.matches("sift run -- swift test", pattern: "sift*--*test"))
        #expect(!WrappedRunPermission.matches("sift run -- swift test", pattern: "sift run"))
        #expect(!WrappedRunPermission.matches("sift run -- swift test", pattern: "swift test*"))
        #expect(!WrappedRunPermission.matches("sift run -- swift test", pattern: "sift*build"))
    }

    /// A replay hands each call the permission mode the transcript last recorded, as the live hook's payload carries it.
    @Test
    func aReplayedCallCarriesThePermissionMode() {
        let block: [String: Any] = ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "swift test"]]
        let identity = ReplayIdentity(sessionTranscript: "/transcripts/s1.jsonl", fallbackSession: "s1", fallbackAgent: nil)
        let call = ReplayCall(block: block, line: ["sessionId": "s1"], identity: identity, origins: WorktreeOrigins(), permissionMode: "auto")

        #expect(call.payload["permission_mode"] as? String == "auto")
    }

    /// Writes `json` to `file`, making its directory first.
    private static func write(_ json: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: file)
    }

    /// A trailing ` *` that is a rule's only wildcard also matches the command bare, so an ask rule written that way for the wrapped build keeps the rewrite from being made.
    @Test
    func aTrailingWildcardAlsoMatchesTheBareCommand() throws {
        #expect(WrappedRunPermission.matches("sift run -- swift test", pattern: "sift run -- swift test *"))
        #expect(!WrappedRunPermission.matches("sift run -- swift test", pattern: "* swift test *"))
        #expect(!WrappedRunPermission.matches("sift run -- swift testing", pattern: "sift run -- swift test *"))

        let outcome = try Self.judged("swift test", mode: "auto", permission: WrappedRunPermission(allowed: ["sift*"], vetoed: ["sift run -- swift test *"]))

        #expect(outcome.verdict.token == "deny")
    }

    /// The user's settings are read where Claude Code reads them: under the configuration directory where one is named, and under the home directory the environment names otherwise.
    @Test
    func theUserSettingsFollowTheConfigurationDirectory() throws {
        let root = try TemporaryDirectory.make("rewrite-config")
        let home = root.appendingPathComponent("home")
        let configuration = root.appendingPathComponent("configuration")
        let project = root.appendingPathComponent("project")
        let missing = root.appendingPathComponent("managed-settings.json").path
        try Self.write(#"{"permissions":{"allow":["Bash(sift run *)"]}}"#, to: home.appendingPathComponent(".claude/settings.json"))
        try Self.write(#"{"permissions":{"allow":["Bash(sift build *)"]}}"#, to: configuration.appendingPathComponent("settings.json"))
        try Self.write(#"{"permissions":{"allow":["Bash(sift test *)"]}}"#, to: project.appendingPathComponent(".claude/settings.json"))
        try Self.write(#"{"projects":{"\#(project.path)":{"hasTrustDialogAccepted":true}}}"#, to: configuration.appendingPathComponent(".claude.json"))

        let byHome = WrappedRunPermission.load(project: project.path, environment: ["HOME": home.path], managed: missing)
        let byConfiguration = WrappedRunPermission.load(project: project.path, environment: ["HOME": home.path, "CLAUDE_CONFIG_DIR": configuration.path], managed: missing)

        #expect(byHome.allowed == ["sift run *"])
        #expect(byConfiguration.allowed == ["sift build *", "sift test *"])
    }

    /// An ask or deny rule on the command as written is the user's say over it: the build is neither rewritten nor refused with a wrapping that rule would not match, but let through for Claude Code to apply the rule.
    @Test(arguments: ["auto", "default"])
    func aRuleOnTheOriginalCommandLetsItThroughUntouched(mode: String) throws {
        let outcome = try Self.judged("xcodebuild -scheme Gizmo test", mode: mode, permission: WrappedRunPermission(allowed: ["*"], vetoed: ["xcodebuild *"]))

        #expect(outcome.json == nil)
        #expect(outcome.verdict.line == "allowed\t\tvetoed")
    }

    /// An ask rule on another statement of the line would prompt for the rewritten line too, so it keeps the rewrite from being made.
    @Test
    func aRuleOnAnotherStatementLetsTheLineThroughUntouched() throws {
        let outcome = try Self.judged("swift build && git push origin main", mode: "auto", permission: WrappedRunPermission(allowed: [], vetoed: ["git push *"]))

        #expect(outcome.json == nil)
        #expect(outcome.verdict.token == "allowed")
    }

    /// A rule is matched as Claude Code matches it: past leading variable assignments and the wrappers it strips, and with redirections set aside.
    @Test
    func aRuleMatchesPastAssignmentsWrappersAndRedirections() {
        let forms = WrappedRunPermission.forms(of: "FOO=1 timeout -s KILL 60 nice -n 5 swift test 2>&1 > test.log")

        #expect(forms.contains("swift test"))
        #expect(forms.contains("swift test 2>&1 > test.log"))
        #expect(WrappedRunPermission(allowed: [], vetoed: ["swift test"]).vetoes(line: "swift test 2>&1"))
        #expect(WrappedRunPermission(allowed: [], vetoed: ["git push *"]).vetoes(line: "echo $(git push) && swift build"))
        #expect(!WrappedRunPermission(allowed: [], vetoed: ["git push *"]).vetoes(line: "swift build && git status"))
    }

    /// A rule matched only inside a subshell, a brace group or a loop body is still the user's say over the line, so the hook stands aside for it.
    @Test(arguments: [
        "(rm -rf x) && swift build",
        "swift build && for f in a; do rm $f; done",
        "swift build && { rm x; }",
        "swift build && if true; then rm x; fi",
    ])
    func aRuleInsideAGroupOrLoopLetsTheLineThrough(shell: String) throws {
        let permission = WrappedRunPermission(allowed: [], vetoed: ["rm *"])
        let outcome = try Self.judged(shell, mode: "auto", permission: permission)

        #expect(permission.vetoes(line: shell))
        #expect(outcome.json == nil)
        #expect(outcome.verdict.line == "allowed\t\tvetoed")
        #expect(!permission.vetoes(line: "(git status) && swift build"))
    }

    /// A settings file with a trailing comma is a syntax error to Claude Code, which skips it, so no allow rule of it counts, while its ask rule still withholds a rewrite; a comma inside a string is only text.
    @Test
    func aSettingsFileWithATrailingCommaAllowsNothing() throws {
        let root = try TemporaryDirectory.make("rewrite-comma")
        let home = root.appendingPathComponent("home")
        let missing = root.appendingPathComponent("managed-settings.json").path
        try Self.write(#"{"permissions":{"allow":["Bash(sift run *)",],"ask":["Bash(rm *)"]}}"#, to: home.appendingPathComponent(".claude/settings.json"))
        #expect(WrappedRunPermission.load(project: nil, environment: ["HOME": home.path], managed: missing).allowed.isEmpty)
        #expect(WrappedRunPermission.load(project: nil, environment: ["HOME": home.path], managed: missing).vetoed == ["rm *"])

        try Self.write(#"{"permissions":{"allow":["Bash(echo a,] *)" ],"ask":["Bash(rm *)"]}}"#, to: home.appendingPathComponent(".claude/settings.json"))
        let valid = WrappedRunPermission.load(project: nil, environment: ["HOME": home.path], managed: missing)
        #expect(valid.allowed == ["echo a,] *"])
        #expect(valid.vetoed == ["rm *"])
    }

    /// A project's allow rules count only once its workspace trust dialog was accepted, as Claude Code applies them; its ask and deny rules count either way.
    @Test
    func aProjectsAllowRulesCountOnlyOnceItIsTrusted() throws {
        let root = try TemporaryDirectory.make("rewrite-trust")
        let home = root.appendingPathComponent("home")
        let project = root.appendingPathComponent("project")
        let missing = root.appendingPathComponent("managed-settings.json").path
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Self.write(#"{"permissions":{"allow":["Bash(sift run *)"],"ask":["Bash(sift run -- xcodebuild *)"]}}"#, to: project.appendingPathComponent(".claude/settings.json"))
        try Self.write(#"{"permissions":{"allow":["Bash(sift build *)"]}}"#, to: project.appendingPathComponent(".claude/settings.local.json"))

        let untrusted = WrappedRunPermission.load(project: project.path, environment: ["HOME": home.path], managed: missing)
        try Self.write(#"{"projects":{"\#(project.path)":{"hasTrustDialogAccepted":true}}}"#, to: home.appendingPathComponent(".claude.json"))
        let trusted = WrappedRunPermission.load(project: project.path, environment: ["HOME": home.path], managed: missing)

        #expect(untrusted.allowed.isEmpty)
        #expect(untrusted.vetoed == ["sift run -- xcodebuild *"])
        #expect(!untrusted.addsNoPrompt(legs: ["sift run -- swift test"], mode: "default"))
        #expect(trusted.allowed == ["sift run *", "sift build *"])
        #expect(trusted.addsNoPrompt(legs: ["sift run -- swift test"], mode: "default"))
    }

    /// The managed drop-in directory's rules are read beside the managed file's, a tool-name glob in an ask or deny rule covers every command, and managed settings that keep permission rules to themselves leave only their own allow rules counted.
    @Test
    func managedDropInsAndToolGlobsAreRead() throws {
        let root = try TemporaryDirectory.make("rewrite-managed")
        let home = root.appendingPathComponent("home")
        let managed = root.appendingPathComponent("managed/managed-settings.json")
        try Self.write(#"{"permissions":{"allow":["Bash(sift build *)","*"],"ask":["B*"]}}"#, to: home.appendingPathComponent(".claude/settings.json"))
        try Self.write(#"{"permissions":{"ask":["Bash(sift run -- swift test *)"]}}"#, to: root.appendingPathComponent("managed/managed-settings.d/10-policy.json"))

        let permission = WrappedRunPermission.load(project: nil, environment: ["HOME": home.path], managed: managed.path)
        #expect(permission.allowed == ["sift build *"])
        #expect(permission.vetoed == ["*", "sift run -- swift test *"])
        #expect(permission.vetoes(line: "swift build"))

        try Self.write(#"{"allowManagedPermissionRulesOnly":true,"permissions":{"allow":["Bash(sift run *)"]}}"#, to: managed)
        #expect(WrappedRunPermission.load(project: nil, environment: ["HOME": home.path], managed: managed.path).allowed == ["sift run *"])
    }

    /// A line the shell would not run as written is never rewritten, nor refused with a wrapping of it named, but let through as written.
    @Test
    func anIncompleteLineIsNotRewritten() throws {
        let outcome = try Self.judged("swift test &&", mode: "auto")

        #expect(ShellSyntax.isIncomplete("swift test &&"))
        #expect(!ShellSyntax.isIncomplete("swift test && git status"))
        #expect(outcome.json == nil)
        #expect(outcome.verdict.line == "allowed\t\tincomplete")
    }

    /// A line with a quote, a substitution or a parenthesis left open, or a `)` nothing opens, is one Claude Code cannot parse either, so it is neither rewritten nor refused but let through; a balanced one is complete.
    @Test(arguments: ["swift test --filter \"Foo", "swift test --filter $(echo", "swift test )", "swift test --filter 'Foo", "swift test `echo"])
    func anUnclosedLineIsNotRewritten(shell: String) throws {
        let outcome = try Self.judged(shell, mode: "auto")

        #expect(ShellSyntax.isIncomplete(shell))
        #expect(outcome.json == nil)
        #expect(outcome.verdict.line == "allowed\t\tincomplete")
    }

    /// A group nothing closes is incomplete too, though the hook never sees a build in it.
    @Test
    func anUnclosedGroupIsIncomplete() {
        #expect(ShellSyntax.isIncomplete("(swift test"))
    }

    /// Quoted, escaped and balanced parentheses and quotes leave a line complete.
    @Test(arguments: ["swift test --filter \"Foo(bar)\"", "(cd Kit && swift test)", "swift test --filter $(echo Foo)", "swift test --filter 'a)b'", "swift test --filter it\\'s"])
    func aClosedLineIsComplete(shell: String) {
        #expect(!ShellSyntax.isIncomplete(shell))
    }

    /// Runs `git` with `arguments` in `directory`, for a fixture repository, failing the test where it fails.
    private static func git(_ arguments: [String], in directory: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Sift", "-c", "user.email=sift@example.com", "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessEnvironment.withoutGit()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed", sourceLocation: sourceLocation)
    }

    /// A deny rule in the repository root's local file holds for a session started in a subdirectory, since Claude Code reads the local file at the root.
    @Test
    func aDenyInTheRepositoryRootsLocalFileHoldsBelowIt() throws {
        let root = try TemporaryDirectory.make("rewrite-subdirectory")
        let repository = root.appendingPathComponent("repo")
        let project = repository.appendingPathComponent("sub")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Self.git(["init", "-q"], in: repository)
        try Self.write(#"{"permissions":{"deny":["Bash(swift test *)"]}}"#, to: repository.appendingPathComponent(".claude/settings.local.json"))

        let permission = WrappedRunPermission.load(project: project.path, environment: ["HOME": home.path], managed: root.appendingPathComponent("managed-settings.json").path)
        let outcome = try Self.judged("swift test", mode: "auto", permission: permission)

        #expect(outcome.json == nil)
        #expect(outcome.verdict.line == "allowed\t\tvetoed")
    }

    /// A deny rule in the main checkout's local file holds for a session in a linked worktree, since Claude Code reads the local file there.
    @Test
    func aDenyInTheMainCheckoutsLocalFileHoldsInAWorktree() throws {
        let root = try TemporaryDirectory.make("rewrite-worktree")
        let repository = root.appendingPathComponent("repo")
        let worktree = root.appendingPathComponent("linked")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Self.git(["init", "-q"], in: repository)
        try Self.git(["commit", "-q", "--allow-empty", "-m", "start"], in: repository)
        try Self.git(["worktree", "add", "-q", worktree.path], in: repository)
        try Self.write(#"{"permissions":{"deny":["Bash(swift test *)"]}}"#, to: repository.appendingPathComponent(".claude/settings.local.json"))

        let permission = WrappedRunPermission.load(project: worktree.path, environment: ["HOME": home.path], managed: root.appendingPathComponent("managed-settings.json").path)
        let outcome = try Self.judged("swift test", mode: "auto", permission: permission)

        #expect(outcome.json == nil)
        #expect(outcome.verdict.line == "allowed\t\tvetoed")
    }
}
