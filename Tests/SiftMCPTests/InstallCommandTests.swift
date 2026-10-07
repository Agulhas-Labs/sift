//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
@testable import SiftCore
import Testing

/// `sift install` on a scratch machine: what it installs into, from which flags and answers, and that a second run and a dry run change nothing.
@Suite(.temporaryDirectories)
struct InstallCommandTests {
    /// All three agents found: `claude` and `codex` on the PATH, `~/.cursor` there.
    private static func allThree() throws -> InstallCommandHarness {
        try InstallCommandHarness(onPath: ["claude", "codex"], directories: [".cursor"])
    }

    /// What each installer writes on its own, run into a second scratch home for the same binary.
    private static func reference(binary: String) throws -> [String: Data] {
        let home = try TemporaryDirectory.make("install-reference")
        let environment = InstallCommandHarness.environment(home: home)
        let output = RecordedOutput().output
        var hook = try InstallHookCommand.parse(["--settings", SiftPaths.claudeSettings(environment: environment).path])
        hook.output = output
        hook.prompt = AllowRunPrompt(isInteractive: false, ask: { _ in nil })
        hook.arguments = [binary]
        hook.environment = environment
        hook.executable = binary
        try hook.install()
        _ = try ClaudeMcpInstall.install(config: SiftPaths.claudeConfig(environment: environment), binary: binary, runner: FakeClaude(config: SiftPaths.claudeConfig(environment: environment)))
        _ = try ClaudeRuleInstall.install(source: ClaudeRuleInstall.source(forBinary: binary), destination: SiftPaths.claudeRule(environment: environment))
        try CursorHookInstaller.install(directory: SiftPaths.cursorDirectory(environment: environment), binary: binary, output: output)
        _ = try CodexHookInstaller.installing(home: CodexInstall.home(flag: nil, environment: environment), binary: binary, runner: FakeCodex(), output: output)
        return try InstallCommandHarness.files(under: home)
    }

    @Test
    func yesFromAnEmptyHomeInstallsAllThreeExactlyAsEachInstallerWould() throws {
        let machine = try Self.allThree()

        let run = try machine.run(["--yes"])

        #expect(run.status == 0)
        #expect(run.asked.isEmpty)
        let files = try machine.files()
        let expected = try Self.reference(binary: machine.binary)
        #expect(expected.keys.sorted() == files.keys.sorted())
        for (path, data) in expected where path != ".claude.json" {
            #expect(files[path] == data, "\(path)")
        }
        // The fake `claude` writes its config with unordered keys, so that one file is compared as JSON.
        let config = try files[".claude.json"].map { try JSONSerialization.jsonObject(with: $0) as? NSDictionary }
        #expect(try config == (expected[".claude.json"].map { try JSONSerialization.jsonObject(with: $0) as? NSDictionary }))
        #expect(Set(files.keys) == [".claude/settings.json", ".claude.json", ".claude/rules/sift.md", ".cursor/mcp.json", ".cursor/hooks.json", ".codex/hooks.json"])
        #expect(files[".claude/rules/sift.md"] == Data(InstallCommandHarness.rule.utf8))
        #expect(machine.claude.calls == [ClaudeMcpInstall.addArguments(binary: machine.binary)])
        #expect(machine.codex.server?.command == machine.binary)
        for agent in ["Claude Code", "Cursor", "Codex"] {
            #expect(run.lines.contains { $0.hasPrefix("  \(agent): installed — wrote ") }, "\(agent)")
        }
        #expect(run.lines.contains("  Codex: installed — wrote \(machine.home.path)/.codex/hooks.json; registered the MCP server. Next: \(InstallSummary.nextStep(.codex))."))
    }

    @Test
    func aSecondRunSaysEachAgentIsAlreadyInstalledAndChangesNothing() throws {
        let machine = try Self.allThree()
        _ = try machine.run(["--yes"])
        let before = try machine.files()
        let claudeCalls = machine.claude.calls.count

        let run = try machine.run(["--yes"])

        #expect(run.status == 0)
        #expect(try machine.files() == before)
        #expect(machine.claude.calls.count == claudeCalls)
        #expect(machine.codex.calls.last?.arguments == CodexMcpServer.getArguments)
        for agent in ["Claude Code", "Cursor", "Codex"] {
            #expect(run.lines.contains("  \(agent): already installed, nothing to do"), "\(agent)")
        }
        #expect(!run.printed.contains("Next:"))
    }

    @Test
    func aDryRunSaysWhatItWouldWriteAndWritesAndRunsNothing() throws {
        let machine = try Self.allThree()
        let before = try machine.files()

        let run = try machine.run(["--dry-run"])

        #expect(run.status == 0)
        #expect(try machine.files() == before)
        #expect(machine.claude.calls.isEmpty)
        #expect(machine.codex.calls.isEmpty)
        #expect(run.printed.hasPrefix(AgentDetection.detect(machine.machine).text + "\n"))
        #expect(run.lines.contains("Claude Code MCP server: would register \(machine.binary) mcp through `claude mcp add`"))
        #expect(run.lines.contains("Claude Code rule: would copy Sift.md to \(machine.home.path)/.claude/rules/sift.md"))
        #expect(run.lines.contains("dry run: nothing written and nothing run; without --dry-run this installs into Claude Code, Cursor, Codex"))
    }

    @Test
    func agentCursorInstallsIntoCursorAlone() throws {
        let machine = try Self.allThree()

        let run = try machine.run(["--agent", "cursor"])

        #expect(run.status == 0)
        #expect(try Set(machine.files().keys) == [".cursor/mcp.json", ".cursor/hooks.json"])
        #expect(machine.claude.calls.isEmpty)
        #expect(machine.codex.calls.isEmpty)
        #expect(!run.lines.contains("Claude Code:"))
        #expect(!run.lines.contains("Codex:"))
    }

    @Test
    func aNamedAgentThatWasNotFoundIsInstalledWithANoteSayingSo() throws {
        let machine = try InstallCommandHarness()

        let run = try machine.run(["--agent", "codex"])

        #expect(run.status == 0)
        let note = "Codex was not found (looked for `codex` on PATH, ~/.codex); installing because --agent codex named it"
        #expect(run.lines.first == note)
        #expect(try Set(machine.files().keys) == [".codex/hooks.json"])
        #expect(machine.codex.server?.command == machine.binary)
    }

    @Test(arguments: [
        (answers: ["", "n", "y"] as [String?], installed: [".claude/settings.json", ".codex/hooks.json"] as Set<String>, asked: 3),
        (answers: ["y", nil] as [String?], installed: [".claude/settings.json"] as Set<String>, asked: 2),
        (answers: ["n", "no", "N"] as [String?], installed: [] as Set<String>, asked: 3),
    ])
    func eachAnswerAtATerminalDecidesItsAgent(answers: [String?], installed: Set<String>, asked: Int) throws {
        let machine = try Self.allThree()

        let run = try machine.run([], answers: answers)

        #expect(run.status == 0)
        // Where Claude Code was installed the two allow-rule questions follow the agent questions, and the answers have run out by then.
        let allowQuestions = installed.contains(".claude/settings.json") ? [AllowRunPrompt.lookupsQuestion, AllowRunPrompt.runsQuestion] : []
        #expect(run.asked == Array(InstallAgent.allCases.map(InstallPrompt.question).prefix(asked)) + allowQuestions)
        #expect(run.printed.hasPrefix(AgentDetection.detect(machine.machine).text + "\n"))
        #expect(try Set(machine.files().keys).intersection([".claude/settings.json", ".cursor/hooks.json", ".codex/hooks.json"]) == installed)
        if installed.isEmpty {
            #expect(run.lines.contains("every agent was declined, so nothing was installed"))
        }
    }

    @Test
    func withoutATerminalOrAFlagItSaysWhatToRunAndDoesNothing() throws {
        let machine = try Self.allThree()
        let before = try machine.files()

        let run = try machine.run([])

        #expect(run.status == 0)
        #expect(run.printed == AgentSelection.needsFlagsText(detected: AgentDetection.detect(machine.machine)) + "\n")
        #expect(run.asked.isEmpty)
        #expect(try machine.files() == before)
        #expect(machine.claude.calls.isEmpty)
        #expect(machine.codex.calls.isEmpty)
    }

    @Test(arguments: [[], ["--yes"]])
    func nothingFoundSaysHowToNameAnAgentAndDoesNothing(arguments: [String]) throws {
        let machine = try InstallCommandHarness()

        let run = try machine.run(arguments, answers: ["y", "y", "y"])

        #expect(run.status == 0)
        #expect(run.printed == AgentSelection.nothingDetectedText(AgentDetection.detect(machine.machine)) + "\n")
        #expect(run.asked.isEmpty)
        #expect(try machine.files().isEmpty)
    }
}
