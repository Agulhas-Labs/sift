//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// Covers the lookup allow rules through `install-hook`, `uninstall-hook` and the session primer that depends on them being there.
@Suite(.temporaryDirectories)
struct LookupAllowRulesInstallTests {
    private static func install(_ settings: URL, _ arguments: [String], answer: String? = nil, interactive: Bool = false) throws {
        var command = try InstallHookCommand.parse(["--settings", settings.path] + arguments)
        command.output = RecordedOutput().output
        command.stateDirectory = settings.deletingLastPathComponent().appendingPathComponent("state")
        command.prompt = AllowRunTerminal(answer: answer).prompt(interactive: interactive)
        try command.run()
    }

    private static func allowRules(at url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String]? {
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], sourceLocation: sourceLocation)
        return (object["permissions"] as? [String: Any])?["allow"] as? [String]
    }

    private static func permission(forSettingsAt settings: URL) -> WrappedRunPermission {
        WrappedRunPermission.load(
            project: nil,
            environment: ["HOME": "/nonexistent", "CLAUDE_CONFIG_DIR": settings.deletingLastPathComponent().path],
            managed: "/nonexistent/managed-settings.json"
        )
    }

    /// `--allow-run` writes both blocks, the run rules first.
    @Test
    func theAllowFlagWritesTheLookupRulesBesideTheRunRules() throws {
        let settings = try TemporaryDirectory.make("lookups").appendingPathComponent("settings.json")

        try Self.install(settings, ["--allow-run"])

        #expect(try Self.allowRules(at: settings) == RunAllowRules.rules + LookupAllowRules.rules)
    }

    /// A yes to each question on a terminal adds both blocks, and the lookups question says what the lookups are.
    @Test
    func theQuestionCoversTheLookupsAndAYesAddsThem() throws {
        let settings = try TemporaryDirectory.make("lookups").appendingPathComponent("settings.json")

        try Self.install(settings, [], answer: "y", interactive: true)

        #expect(try Self.allowRules(at: settings) == RunAllowRules.rules + LookupAllowRules.rules)
        #expect(AllowRunPrompt.lookupsQuestion.contains("`sift digest`"))
    }

    /// A decline, or no terminal to ask, adds neither block.
    @Test(arguments: [["--no-allow-run"], []])
    func aDeclineOrNoTerminalAddsNothing(arguments: [String]) throws {
        let settings = try TemporaryDirectory.make("lookups").appendingPathComponent("settings.json")

        try Self.install(settings, arguments)

        #expect(try Self.allowRules(at: settings) == nil)
    }

    /// A file already holding only the run rules gains only the lookups, and the uninstall takes each block out and keeps the rest.
    @Test
    func anOlderInstallGainsTheLookupsAndUninstallKeepsOtherRules() throws {
        let settings = try TemporaryDirectory.make("lookups").appendingPathComponent("settings.json")
        let older = ["Bash(ls:*)"] + RunAllowRules.rules
        try JSONSerialization.data(withJSONObject: ["permissions": ["allow": older], "model": "x"]).write(to: settings)

        try Self.install(settings, ["--allow-run"])
        #expect(try Self.allowRules(at: settings) == older + LookupAllowRules.rules)

        try UninstallHookCommand.parse(["--settings", settings.path]).run()
        let after = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        #expect((after["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(ls:*)"])
        #expect(after["model"] as? String == "x")
    }

    /// The settings the install wrote are what the primer reads: with the rules the lookups run from Bash, without them they do not.
    @Test
    func theInstalledRulesAreWhatMakesTheLookupsAllowed() throws {
        let allowed = try TemporaryDirectory.make("lookups").appendingPathComponent("settings.json")
        let declined = try TemporaryDirectory.make("lookups").appendingPathComponent("settings.json")
        try Self.install(allowed, ["--allow-run"])
        try Self.install(declined, ["--no-allow-run"])

        #expect(Self.permission(forSettingsAt: allowed).allowsLookups())
        #expect(!Self.permission(forSettingsAt: declined).allowsLookups())
    }

    /// With the rules present the closing tells a context to call the CLI rather than load its tools; without them today's sentence stays, for a session and a subagent alike.
    @Test(arguments: ["SessionStart", "SubagentStart"])
    func thePrimerPointsAtTheCLIOnlyWhereTheRulesAreThere(event: String) throws {
        let repo = try MCPTestRepo.make()
        let ledger = try TemporaryDirectory.make("ledger").appendingPathComponent("run.jsonl")
        func primer(allowed: [String], sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
            try #require(SessionStartCommand.output(
                payload: ["cwd": repo.path, "hook_event_name": event, "source": "startup"],
                cwd: nil,
                event: nil,
                runLedgerURL: ledger,
                permission: { _ in WrappedRunPermission(allowed: WrappedRunPermission.patterns(in: allowed), vetoed: []) }
            ), sourceLocation: sourceLocation)
        }

        let with = try primer(allowed: LookupAllowRules.rules)
        let without = try primer(allowed: RunAllowRules.rules)

        #expect(with.contains("rather than loading them"))
        #expect(!with.contains("Without sift tools"))
        #expect(without.contains("Without sift tools, the CLI answers the same queries from Bash"))
        #expect(!without.contains("rather than loading them"))
    }
}
