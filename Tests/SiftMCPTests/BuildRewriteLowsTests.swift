//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// Covers the edges of the in-place build rewrite: a line the shell would not run as written, a settings file Claude Code skips as malformed, and an ask or deny rule on a `case` arm's command.
@Suite(.temporaryDirectories)
struct BuildRewriteLowsTests {
    /// What the hook makes of `shell` run from Bash in permission mode `mode`, judged against `permission`.
    private static func judged(
        _ shell: String,
        mode: String?,
        permission: WrappedRunPermission = WrappedRunPermission(allowed: [], vetoed: []),
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> (json: String?, verdict: PreToolUseCommand.Verdict) {
        let scratch = try TemporaryDirectory.make("rewrite-lows")
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
            ledger: AdviceLedger(directory: scratch.appendingPathComponent("advice")),
            usage: UsageLog(fileURL: scratch.appendingPathComponent("usage.jsonl")),
            suppressions: SuppressionLog(fileURL: scratch.appendingPathComponent("suppressions.jsonl")),
            answerer: { _, _, _ in .withheld(.notExact) },
            serverPresence: { _, _ in false },
            runPermission: { _ in permission }
        )
    }

    /// The rules read from a user settings file holding `json`, in a configuration directory of the test's own, with no project, and a managed file holding `managed` where it is given.
    private static func loaded(userSettings json: String, managed: String? = nil) throws -> WrappedRunPermission {
        try loaded(userData: Data(json.utf8), managed: managed)
    }

    /// The rules read from a user settings file holding `data` byte for byte, as ``loaded(userSettings:managed:)`` reads them.
    private static func loaded(userData data: Data, managed: String? = nil) throws -> WrappedRunPermission {
        let root = try TemporaryDirectory.make("rewrite-lows-settings")
        let configuration = root.appendingPathComponent("config")
        let managedFile = root.appendingPathComponent("managed/managed-settings.json")
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: configuration.appendingPathComponent("settings.json"))
        if let managed {
            try Data(managed.utf8).write(to: managedFile)
        }
        return WrappedRunPermission.load(
            project: nil,
            environment: ["HOME": root.appendingPathComponent("home").path, "CLAUDE_CONFIG_DIR": configuration.path],
            managed: managedFile.path
        )
    }

    /// A line the shell would not run as written is let through as written, in every mode, with no wrapping of it named: the hook cannot know what the finished line will be.
    @Test(arguments: ["swift test &&", "&& swift test", "swift test |", "swift test --filter \"Foo", "swift test --filter $(echo", "swift test )"])
    func anIncompleteLineIsLetThroughWithNoWrappingNamed(shell: String) throws {
        for mode in ["default", "auto"] {
            let outcome = try Self.judged(shell, mode: mode)

            #expect(outcome.json == nil)
            #expect(outcome.verdict.line == "allowed\t\tincomplete")
        }
    }

    /// A settings file with a trailing comma, which Claude Code skips, allows nothing, yet its deny rule still makes the hook stand aside from a line that rule speaks for; the same file without the comma allows what it lists.
    @Test
    func aTrailingCommaFileAllowsNothingButStillVetoes() throws {
        let strict = try Self.loaded(userSettings: #"{"permissions":{"allow":["Bash(sift run:*)"],"deny":["Bash(rm *)"]}}"#)
        #expect(strict.allowed == ["sift run", "sift run *"])
        #expect(try Self.judged("swift test", mode: "default", permission: strict).verdict.token == "amended")

        let permission = try Self.loaded(userSettings: #"{"permissions":{"allow":["Bash(sift run:*)"],"deny":["Bash(rm *)"],}}"#)

        #expect(permission.allowed.isEmpty)
        #expect(permission.vetoed == ["rm *"])
        #expect(try Self.judged("swift build && rm x", mode: "auto", permission: permission).verdict.line == "allowed\t\tvetoed")
        #expect(try Self.judged("swift test", mode: "default", permission: permission).verdict.token == "deny")
    }

    /// A settings file opening on a byte order mark is not strict JSON, so it allows nothing either, while its deny rule still counts.
    @Test
    func aByteOrderMarkFileAllowsNothingButStillVetoes() throws {
        let permission = try Self.loaded(userSettings: "\u{FEFF}" + #"{"permissions":{"allow":["Bash(sift run:*)"],"deny":["Bash(rm *)"]}}"#)

        #expect(permission.allowed.isEmpty)
        #expect(permission.vetoed == ["rm *"])
    }

    /// Managed settings that keep permission rules to themselves are honoured from a file Claude Code may skip as malformed, since that only withholds rewrites: the user's allow rule no longer counts.
    @Test
    func aMalformedManagedFileKeepingRulesToItselfStillWithholds() throws {
        let user = #"{"permissions":{"allow":["Bash(sift run:*)"]}}"#

        #expect(try Self.loaded(userSettings: user).allowed == ["sift run", "sift run *"])
        #expect(try Self.loaded(userSettings: user, managed: #"{"allowManagedPermissionRulesOnly":true,}"#).allowed.isEmpty)
    }

    /// An ask or deny rule on a `case` arm's command makes the hook stand aside, whichever spelling the arm's pattern takes; an arm running nothing the rule speaks for leaves the rewrite in place.
    @Test
    func aRuleOnACaseArmsCommandLetsTheLineThroughUntouched() throws {
        let permission = WrappedRunPermission(allowed: [], vetoed: ["rm *"])

        #expect(permission.vetoes(line: "swift build && case a in (a) rm x;; esac"))
        #expect(permission.vetoes(line: "swift build && case a in (a) echo;; (b) rm x;; esac"))
        #expect(permission.vetoes(line: "swift build && case a in a) echo;; b) rm x;; esac"))
        #expect(!permission.vetoes(line: "swift build && case a in (a) echo;; esac"))
        #expect(!permission.vetoes(line: "swift build && echo \"(a) rm x\""))
        #expect(try Self.judged("swift build && case a in (a) rm x;; esac", mode: "auto", permission: permission).verdict.line == "allowed\t\tvetoed")
        #expect(try Self.judged("swift build && case a in (a) echo;; esac", mode: "auto", permission: permission).verdict.token == "amended")
    }

    /// A user settings file holding a Latin-1 byte, which Claude Code reads and Foundation does not, keeps its deny rule from the hook's sight, so the hook stands aside from every build rather than rewrite one that rule may speak for.
    @Test
    func aLatin1SettingsFileWithholdsEveryRewrite() throws {
        let latin1 = Data(#"{"note":"caf"#.utf8) + Data([0xE9]) + Data(#"","permissions":{"deny":["Bash(swift build:*)"]}}"#.utf8)
        let permission = try Self.loaded(userData: latin1)

        #expect(permission.hasUnreadableSettings)
        let outcome = try Self.judged("swift build", mode: "auto", permission: permission)
        #expect(outcome.json == nil)
        #expect(outcome.verdict.line == "allowed\t\tunreadable-settings")
        #expect(try Self.judged("swift test", mode: "auto", permission: permission).verdict.line == "allowed\t\tunreadable-settings")
    }

    /// A lone surrogate escape is JSON Claude Code reads and Foundation does not, so it withholds every rewrite the same way.
    @Test
    func aLoneSurrogateSettingsFileWithholdsEveryRewrite() throws {
        let permission = try Self.loaded(userSettings: #"{"note":"\ud83d","permissions":{"deny":["Bash(swift build:*)"]}}"#)

        #expect(permission.hasUnreadableSettings)
        let outcome = try Self.judged("swift build", mode: "auto", permission: permission)
        #expect(outcome.json == nil)
        #expect(outcome.verdict.line == "allowed\t\tunreadable-settings")
    }

    /// A clean UTF-8 settings file, an empty one and one holding only whitespace withhold nothing: a deny rule the line does not run leaves the rewrite in place.
    @Test(arguments: [#"{"permissions":{"deny":["Bash(rm *)"]}}"#, "", " \n\t"])
    func aCleanOrEmptySettingsFileLeavesTheRewriteInPlace(json: String) throws {
        let permission = try Self.loaded(userSettings: json)

        #expect(!permission.hasUnreadableSettings)
        #expect(try Self.judged("swift build", mode: "auto", permission: permission).verdict.token == "amended")
    }

    /// A UTF-16 settings file allows nothing, since Claude Code reads settings as UTF-8, while its deny rule still vetoes and the file withholds nothing else.
    @Test
    func aUTF16SettingsFileAllowsNothingButStillVetoes() throws {
        let allowOnly = try #require(#"{"permissions":{"allow":["Bash(sift run:*)"]}}"#.data(using: .utf16LittleEndian))
        let permission = try Self.loaded(userData: allowOnly)

        #expect(permission.allowed.isEmpty)
        #expect(!permission.hasUnreadableSettings)
        #expect(try Self.judged("swift test", mode: "default", permission: permission).verdict.token == "deny")

        let denying = try #require(#"{"permissions":{"deny":["Bash(rm *)"]}}"#.data(using: .utf16LittleEndian))
        let vetoing = try Self.loaded(userData: denying)

        #expect(vetoing.vetoed == ["rm *"])
        #expect(try Self.judged("swift build && rm x", mode: "auto", permission: vetoing).verdict.line == "allowed\t\tvetoed")
        #expect(try Self.judged("swift build", mode: "auto", permission: vetoing).verdict.token == "amended")
    }

    /// A settings file naming a key twice in one object — where Foundation keeps the first and Claude Code may keep the last, so a deny rule can be the one the hook never sees — withholds every rewrite, an escaped spelling of the key and a nested object's included.
    @Test(arguments: [
        #"{"permissions":{},"permissions":{"deny":["Bash(swift build:*)"]}}"#,
        #"{"permissions":{"deny":[],"deny":["Bash(swift build:*)"]}}"#,
        // The second key spells its `i` as a JSON escape, written apart so no editor folds it back into the letter.
        #"{"permissions":{},"perm"# + "\\" + #"u0069ssions":{"deny":["Bash(swift build:*)"]}}"#,
    ])
    func aSettingsFileNamingAKeyTwiceWithholdsEveryRewrite(json: String) throws {
        let permission = try Self.loaded(userSettings: json)

        #expect(permission.hasUnreadableSettings)
        #expect(try Self.judged("swift build", mode: "auto", permission: permission).verdict.line == "allowed\t\tunreadable-settings")
    }

    /// A key spelled once per object, a colon inside a string, and a file in UTF-16 or UTF-32 of either byte order withhold nothing: only a key named twice does.
    @Test(arguments: [String.Encoding.utf8, .utf16, .utf16BigEndian, .utf16LittleEndian, .utf32LittleEndian, .utf32BigEndian])
    func aKeyNamedOncePerObjectWithholdsNothing(encoding: String.Encoding) throws {
        let json = #"{"permissions":{"deny":["Bash(rm:*)"],"ask":["Bash(a:b)"]},"env":{"permissions":"x:y"}}"#
        let permission = try Self.loaded(userData: #require(json.data(using: encoding)))

        #expect(!permission.hasUnreadableSettings)
        #expect(permission.vetoed == ["a:b", "rm", "rm *"])
    }

    /// A deny list holding an entry that is not a string keeps the rules beside it, so the hook still stands aside from a line they speak for.
    @Test
    func aDenyListWithANonStringEntryStillVetoes() throws {
        let permission = try Self.loaded(userSettings: #"{"permissions":{"deny":[1,"Bash(swift build:*)"]}}"#)

        #expect(permission.vetoed == ["swift build", "swift build *"])
        #expect(try Self.judged("swift build", mode: "auto", permission: permission).verdict.line == "allowed\t\tvetoed")
    }

    /// An ask or deny rule on a `case` arm's command with no blank after its pattern's `)`, or on a function body however its braces are spaced, makes the hook stand aside, since bash runs that command all the same.
    @Test(arguments: [
        "swift build && case a in (a)rm x;; esac",
        "swift build && case a in a)rm x;; esac",
        "f(){ rm x; }; swift build; f",
        "f() { rm x; }; swift build; f",
        "function f { rm x; }; swift build; f",
        "function f(){ rm x; }; swift build; f",
    ])
    func aRuleOnACommandWithNoBlankBeforeItLetsTheLineThroughUntouched(shell: String) throws {
        let permission = WrappedRunPermission(allowed: [], vetoed: ["rm *"])

        #expect(permission.vetoes(line: shell))
        #expect(try Self.judged(shell, mode: "auto", permission: permission).verdict.line == "allowed\t\tvetoed")
    }
}
