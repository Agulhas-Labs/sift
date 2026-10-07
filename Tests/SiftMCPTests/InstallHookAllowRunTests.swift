//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// Covers `install-hook` asking whether to add the `sift run` allow rules, and `uninstall-hook` taking back only what the install added.
@Suite(.temporaryDirectories)
struct InstallHookAllowRunTests {
    /// Runs `install-hook` against `settings` with `arguments`, `terminal` answering, and returns what it printed.
    private static func install(
        _ settings: URL,
        _ arguments: [String] = [],
        terminal: AllowRunTerminal,
        interactive: Bool
    ) throws -> String {
        var command = try InstallHookCommand.parse(["--settings", settings.path] + arguments)
        let recorded = RecordedOutput()
        command.output = recorded.output
        command.stateDirectory = settings.deletingLastPathComponent().appendingPathComponent("state")
        command.prompt = terminal.prompt(interactive: interactive)
        try command.run()
        return recorded.printed
    }

    private static func allowRules(at url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String]? {
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], sourceLocation: sourceLocation)
        return (object["permissions"] as? [String: Any])?["allow"] as? [String]
    }

    /// On a terminal the install asks both questions, saying what each block allows, and a yes to each adds every rule.
    @Test(arguments: ["y", "YES", " yes\n"])
    func aYesOnATerminalAddsTheRules(answer: String) throws {
        let settings = try TemporaryDirectory.make("allow-run").appendingPathComponent("settings.json")
        let terminal = AllowRunTerminal(answer: answer)

        let printed = try Self.install(settings, terminal: terminal, interactive: true)

        #expect(terminal.asked == [AllowRunPrompt.lookupsQuestion, AllowRunPrompt.runsQuestion])
        #expect(AllowRunPrompt.runsQuestion.contains("[y/N]"))
        #expect(try Self.allowRules(at: settings) == RunAllowRules.rules + LookupAllowRules.rules)
        #expect(printed.contains("permissions: allowed Bash(sift run -- swift build:*)"))
    }

    /// No, the end of input and anything unrecognised all mean no: the install asks both questions and adds nothing.
    ///
    /// An empty line is each question's own default, which `InstallConsentSplitTests` covers.
    @Test(arguments: ["n", nil, "maybe"] as [String?])
    func anythingButYesOnATerminalAddsNothing(answer: String?) throws {
        let settings = try TemporaryDirectory.make("allow-run").appendingPathComponent("settings.json")
        let terminal = AllowRunTerminal(answer: answer)

        let printed = try Self.install(settings, terminal: terminal, interactive: true)

        #expect(terminal.asked.count == 2)
        #expect(try Self.allowRules(at: settings) == nil)
        #expect(printed.contains("permissions: nothing added\n"))
    }

    /// Without a terminal nobody is asked and nothing is added, and one line names the flag that adds the rules.
    @Test
    func withoutATerminalNothingIsAddedAndTheFlagIsNamed() throws {
        let settings = try TemporaryDirectory.make("allow-run").appendingPathComponent("settings.json")
        let terminal = AllowRunTerminal(answer: "y")

        let printed = try Self.install(settings, terminal: terminal, interactive: false)

        #expect(terminal.asked.isEmpty)
        #expect(try Self.allowRules(at: settings) == nil)
        let lines = printed.split(separator: "\n").filter { $0.contains("sift install-hook --allow-run") }
        #expect(lines.count == 1)
    }

    /// The flags answer without the question, on a terminal or not.
    @Test(arguments: [(["--allow-run"], true), (["--no-allow-run"], false)], [true, false])
    func aFlagAnswersWithoutTheQuestion(flag: (arguments: [String], adds: Bool), interactive: Bool) throws {
        let settings = try TemporaryDirectory.make("allow-run").appendingPathComponent("settings.json")
        let terminal = AllowRunTerminal(answer: flag.adds ? "n" : "y")

        _ = try Self.install(settings, flag.arguments, terminal: terminal, interactive: interactive)

        #expect(terminal.asked.isEmpty)
        #expect(try Self.allowRules(at: settings) == (flag.adds ? RunAllowRules.rules + LookupAllowRules.rules : nil))
    }

    /// Where the rules are all there, nobody is asked, and a re-run with only the rules to add still rewrites the file.
    @Test
    func rulesAlreadyThereAreNotAskedAbout() throws {
        let settings = try TemporaryDirectory.make("allow-run").appendingPathComponent("settings.json")
        _ = try Self.install(settings, terminal: AllowRunTerminal(answer: nil), interactive: false)
        _ = try Self.install(settings, ["--allow-run"], terminal: AllowRunTerminal(answer: nil), interactive: false)
        #expect(try Self.allowRules(at: settings) == RunAllowRules.rules + LookupAllowRules.rules)

        let terminal = AllowRunTerminal(answer: "y")
        let printed = try Self.install(settings, terminal: terminal, interactive: true)

        #expect(terminal.asked.isEmpty)
        #expect(printed.contains("permissions: wrapped builds and lookups already allowed"))
    }

    /// Install then uninstall leaves `permissions` as it was, whether it was absent or held rules of the user's own.
    @Test(arguments: [nil, #"{"allow": ["Bash(ls:*)"], "deny": ["Bash(rm:*)"]}"#])
    func installThenUninstallLeavesThePermissionsAsTheyWere(permissions: String?) throws {
        let settings = try TemporaryDirectory.make("allow-run").appendingPathComponent("settings.json")
        try Data((permissions.map { #"{"permissions": \#($0)}"# } ?? "{}").utf8).write(to: settings)
        let before = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])["permissions"]

        _ = try Self.install(settings, ["--allow-run"], terminal: AllowRunTerminal(answer: nil), interactive: false)
        #expect(try Self.allowRules(at: settings)?.suffix(RunAllowRules.rules.count + LookupAllowRules.rules.count) == ArraySlice(RunAllowRules.rules + LookupAllowRules.rules))
        try UninstallHookCommand.parse(["--settings", settings.path]).run()

        let after = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])["permissions"]
        #expect(after.map { NSDictionary(dictionary: $0 as? [String: Any] ?? [:]) } == before.map { NSDictionary(dictionary: $0 as? [String: Any] ?? [:]) })
    }

    /// A rule of the set the user wrote, without the install adding the rest, survives the uninstall, and so does the file's other content.
    @Test(arguments: [[], ["--only-advice"]])
    func aRuleTheUserWroteSurvivesUninstall(arguments: [String]) throws {
        let settings = try TemporaryDirectory.make("allow-run").appendingPathComponent("settings.json")
        try Data(#"{"permissions": {"allow": ["Bash(sift run -- swift test:*)"]}}"#.utf8).write(to: settings)

        _ = try Self.install(settings, ["--no-allow-run"], terminal: AllowRunTerminal(answer: nil), interactive: false)
        try UninstallHookCommand.parse(["--settings", settings.path] + arguments).run()

        #expect(try Self.allowRules(at: settings) == ["Bash(sift run -- swift test:*)"])
    }

    /// A `permissions` of a shape the rules cannot go into does not stop `--no-allow-run` registering the hooks.
    @Test
    func anOddPermissionsShapeDoesNotBlockADeclinedInstall() throws {
        let settings = try TemporaryDirectory.make("allow-run").appendingPathComponent("settings.json")
        try Data(#"{"permissions": "weird"}"#.utf8).write(to: settings)

        _ = try Self.install(settings, ["--no-allow-run"], terminal: AllowRunTerminal(answer: nil), interactive: false)

        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])

        #expect(object["permissions"] as? String == "weird")
        #expect(object["hooks"] != nil)
    }

    /// A `permissions.allow` of an odd shape is not ours: the uninstall leaves it and still removes the hooks.
    @Test
    func anOddAllowShapeDoesNotBlockAnUninstall() throws {
        let settings = try TemporaryDirectory.make("allow-run").appendingPathComponent("settings.json")
        let hook = #"{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "/usr/local/bin/sift session-start"}]}]}, "#
        try Data((hook + #""permissions": {"allow": "Bash"}}"#).utf8).write(to: settings)

        try UninstallHookCommand.parse(["--settings", settings.path]).run()

        let after = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])

        #expect((after["permissions"] as? [String: Any])?["allow"] as? String == "Bash")
        #expect(after["hooks"] == nil)
    }

    /// Each question says the flag that declines it without asking.
    @Test
    func theQuestionNamesTheFlagThatDeclinesIt() {
        #expect(AllowRunPrompt.lookupsQuestion.contains("--no-allow-run"))
        #expect(AllowRunPrompt.runsQuestion.contains("--no-allow-run"))
    }
}
