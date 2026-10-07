//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// The allow rules are two questions with two defaults, the lookups (yes) before the runs (no), each adding only its own block, asked by `install-hook` and by `sift install` alike, and named by the flags where nobody can be asked.
@Suite(.temporaryDirectories)
struct InstallConsentSplitTests {
    private static let both = [AllowRunPrompt.lookupsQuestion, AllowRunPrompt.runsQuestion]

    /// Runs `install-hook` against `settings` with `arguments`, `answers` given in turn at a terminal when they are not `nil`, and returns what it printed and every question asked.
    private static func install(_ settings: URL, _ arguments: [String] = [], answers: [String?]? = nil) throws -> (printed: String, asked: [String]) {
        var command = try InstallHookCommand.parse(["--settings", settings.path] + arguments)
        let recorded = RecordedOutput()
        let terminal = InstallCommandHarness.Terminal(answers: answers ?? [])
        command.output = recorded.output
        command.stateDirectory = settings.deletingLastPathComponent().appendingPathComponent("state")
        command.prompt = AllowRunPrompt(isInteractive: answers != nil, ask: { terminal.ask($0) })
        try command.run()
        return (recorded.printed, terminal.asked)
    }

    private static func allowRules(at url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String]? {
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], sourceLocation: sourceLocation)
        return (object["permissions"] as? [String: Any])?["allow"] as? [String]
    }

    static let heldCases: [HeldCase] = [
        HeldCase(held: LookupAllowRules.rules, asked: [AllowRunPrompt.runsQuestion], after: LookupAllowRules.rules + RunAllowRules.rules),
        HeldCase(held: RunAllowRules.rules, asked: [AllowRunPrompt.lookupsQuestion], after: RunAllowRules.rules + LookupAllowRules.rules),
        HeldCase(held: RunAllowRules.rules + LookupAllowRules.rules, asked: [], after: RunAllowRules.rules + LookupAllowRules.rules),
    ]

    private static func settingsFile() throws -> URL {
        try TemporaryDirectory.make("consent-split").appendingPathComponent("settings.json")
    }

    /// The lookups default to yes and the runs to no, in the text the person reads.
    @Test
    func theQuestionsStateTheirDefaults() {
        #expect(AllowRunPrompt.lookupsQuestion.hasSuffix("[Y/n]\u{20}"))
        #expect(AllowRunPrompt.runsQuestion.hasSuffix("[y/N]\u{20}"))
        #expect(AllowRunPrompt.lookupsQuestion.contains("`sift digest`"))
        #expect(!AllowRunPrompt.lookupsQuestion.contains("sift run"))
        #expect(AllowRunPrompt.runsQuestion.contains("`sift run -- swift build`"))
        #expect(AllowRunPrompt.runsQuestion.contains("package manifests"))
    }

    /// The lookups question says everything the four commands write, `~/.sift` included, and both git switches.
    @Test
    func theLookupsQuestionNamesWhatTheyWrite() {
        let question = AllowRunPrompt.lookupsQuestion

        #expect(question.contains("`~/.sift`"))
        #expect(question.contains("`.sift/`"))
        #expect(question.contains("`.git/info/exclude`"))
        #expect(question.contains("fsmonitor and git hooks switched off"))
        #expect(!question.contains("only the named repository"))
    }

    /// The question is written to stdout and answered on stdin, so it is asked only where both are terminals: with either redirected nobody sees it, or nobody answers it.
    @Test(arguments: [(true, true, true), (true, false, false), (false, true, false), (false, false, false)])
    func aQuestionIsAskedOnlyWhereBothStreamsAreTerminals(stdinIsTerminal: Bool, stdoutIsTerminal: Bool, asks: Bool) {
        #expect(AllowRunPrompt.canAsk(stdinIsTerminal: stdinIsTerminal, stdoutIsTerminal: stdoutIsTerminal) == asks)
    }

    /// Without a terminal, a file already holding both blocks is reported as allowed and no flag is advised, at `install-hook` and at `sift install`.
    @Test
    func withoutATerminalAFileHoldingBothBlocksIsAlreadyAllowed() throws {
        let settings = try Self.settingsFile()
        try JSONSerialization.data(withJSONObject: ["permissions": ["allow": RunAllowRules.rules + LookupAllowRules.rules]]).write(to: settings)

        let run = try Self.install(settings)

        #expect(run.asked.isEmpty)
        #expect(run.printed.contains("permissions: wrapped builds and lookups already allowed"))
        #expect(!run.printed.contains("nothing added"))
        #expect(!run.printed.contains("--allow-run"))
        #expect(!run.printed.contains("--allow-lookups"))
    }

    /// `sift install --yes` with no terminal over settings holding both blocks gives no advice to add rules the file has.
    @Test
    func installWithoutATerminalOverBothBlocksAdvisesNothing() throws {
        let machine = try InstallCommandHarness(onPath: ["claude"])
        let settings = machine.home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["permissions": ["allow": RunAllowRules.rules + LookupAllowRules.rules]]).write(to: settings)

        let run = try machine.run(["--yes"])

        #expect(run.printed.contains("already allowed"))
        #expect(!run.printed.contains("sift install-hook --allow-run"))
        #expect(!run.printed.contains("sift install-hook --allow-lookups"))
    }

    /// Each pair of answers adds the blocks it says yes to, the lookups first in the asking and the run rules first in the file, and an empty line is each question's own default.
    @Test(arguments: [
        (answers: ["", ""] as [String?], rules: LookupAllowRules.rules),
        (answers: ["n", "y"] as [String?], rules: RunAllowRules.rules),
        (answers: ["y", "n"] as [String?], rules: LookupAllowRules.rules),
        (answers: ["y", "y"] as [String?], rules: RunAllowRules.rules + LookupAllowRules.rules),
        (answers: ["n", ""] as [String?], rules: []),
        (answers: [nil, nil] as [String?], rules: []),
        (answers: ["maybe", "maybe"] as [String?], rules: []),
    ])
    func eachAnswerAddsOnlyItsOwnBlock(answers: [String?], rules: [String]) throws {
        let settings = try Self.settingsFile()

        let run = try Self.install(settings, answers: answers)

        #expect(run.asked == Self.both)
        #expect(try Self.allowRules(at: settings) == (rules.isEmpty ? nil : rules))
        #expect(run.printed.contains(rules.isEmpty ? "permissions: nothing added\n" : "permissions: allowed \(rules[0])"))
    }

    /// Where nobody can answer nothing is asked or added, and the line names the flag for both blocks and the flag for the lookups alone.
    @Test
    func withoutATerminalNothingIsAddedAndBothFlagsAreNamed() throws {
        let settings = try Self.settingsFile()

        let run = try Self.install(settings)

        #expect(run.asked.isEmpty)
        #expect(try Self.allowRules(at: settings) == nil)
        let lines = run.printed.split(separator: "\n").filter { $0.hasPrefix("permissions: nothing added") }
        #expect(lines.count == 1)
        #expect(lines.first?.contains("sift install-hook --allow-run") == true)
        #expect(lines.first?.contains("sift install-hook --allow-lookups") == true)
    }

    /// The flags answer without a question, at a terminal or without one.
    @Test(arguments: [
        (flag: "--allow-run", rules: RunAllowRules.rules + LookupAllowRules.rules),
        (flag: "--allow-lookups", rules: LookupAllowRules.rules),
        (flag: "--no-allow-run", rules: []),
    ], [true, false])
    func aFlagAnswersWithoutAsking(given: (flag: String, rules: [String]), interactive: Bool) throws {
        let settings = try Self.settingsFile()

        let run = try Self.install(settings, [given.flag], answers: interactive ? ["n", "n"] : nil)

        #expect(run.asked.isEmpty)
        #expect(try Self.allowRules(at: settings) == (given.rules.isEmpty ? nil : given.rules))
    }

    /// `--allow-lookups` over a file holding the run block adds the lookups beside it and leaves the run block as it was.
    @Test
    func allowLookupsLeavesAnExistingRunBlockAlone() throws {
        let settings = try Self.settingsFile()
        try JSONSerialization.data(withJSONObject: ["permissions": ["allow": RunAllowRules.rules]]).write(to: settings)

        _ = try Self.install(settings, ["--allow-lookups"])

        #expect(try Self.allowRules(at: settings) == RunAllowRules.rules + LookupAllowRules.rules)
    }

    /// `--allow-lookups` with `--no-allow-run` contradict each other, and `--allow-lookups` is for Claude Code like the other allow flags.
    @Test
    func contradictoryOrMisplacedFlagsAreRefused() {
        #expect(throws: (any Error).self) { try InstallHookCommand.parse(["--allow-lookups", "--no-allow-run"]) }
        #expect(throws: (any Error).self) { try InstallHookCommand.parse(["--agent", "cursor", "--allow-lookups"]) }
        #expect(throws: Never.self) { try InstallHookCommand.parse(["--allow-lookups", "--allow-run"]) }
    }

    /// A block the file already holds is not asked about again; the other block still is.
    @Test(arguments: InstallConsentSplitTests.heldCases)
    func aHeldBlockIsNotAskedAboutAgain(given: HeldCase) throws {
        let (held, asked, after) = (given.held, given.asked, given.after)
        let settings = try Self.settingsFile()
        try JSONSerialization.data(withJSONObject: ["permissions": ["allow": held]]).write(to: settings)

        let run = try Self.install(settings, answers: ["y", "y"])

        #expect(run.asked == asked)
        #expect(try Self.allowRules(at: settings) == after)
    }

    /// `sift install` at a terminal asks both questions and adds per the answers, whether or not `--yes` spared the agent question.
    @Test(arguments: [
        (answers: ["", ""] as [String?], rules: LookupAllowRules.rules),
        (answers: ["n", "y"] as [String?], rules: RunAllowRules.rules),
        (answers: ["n", "n"] as [String?], rules: []),
    ])
    func installAsksBothQuestionsAtATerminal(answers: [String?], rules: [String]) throws {
        let machine = try InstallCommandHarness(onPath: ["claude"])

        let run = try machine.run(["--yes"], answers: answers)

        #expect(run.status == 0)
        #expect(run.asked == Self.both)
        let settings = machine.home.appendingPathComponent(".claude/settings.json")
        #expect(try Self.allowRules(at: settings) == (rules.isEmpty ? nil : rules))
    }

    /// `sift install` over a settings file holding one block asks only about the other.
    @Test
    func installDoesNotAskAboutABlockTheFileHolds() throws {
        let machine = try InstallCommandHarness(onPath: ["claude"])
        let settings = machine.home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["permissions": ["allow": LookupAllowRules.rules]]).write(to: settings)

        let run = try machine.run(["--yes"], answers: ["y"])

        #expect(run.asked == [AllowRunPrompt.runsQuestion])
        #expect(try Self.allowRules(at: settings) == LookupAllowRules.rules + RunAllowRules.rules)
    }

    /// `sift install` with no terminal adds nothing and its Claude Code section names how to add the rules.
    @Test
    func installWithoutATerminalNamesTheFlags() throws {
        let machine = try InstallCommandHarness(onPath: ["claude"])

        let run = try machine.run(["--yes"])

        #expect(run.status == 0)
        #expect(run.asked.isEmpty)
        #expect(run.printed.contains("permissions: nothing added"))
        #expect(run.printed.contains("sift install-hook --allow-run"))
        #expect(run.printed.contains("sift install-hook --allow-lookups"))
        let settings = machine.home.appendingPathComponent(".claude/settings.json")
        #expect(try Self.allowRules(at: settings) == nil)
    }

    /// `install.sh` leaves the questions to `install-hook`, so its questions and defaults are the ones above: its call to `install-hook` carries no allow flag.
    @Test
    func installShAsksThroughInstallHookWithNoFlagOfItsOwn() throws {
        let script = try String(contentsOf: GuideCommandReferenceTests.repositoryRoot.appendingPathComponent("Distribution/install.sh"), encoding: .utf8)
        let calls = script.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") && $0.contains("install-hook") }

        #expect(calls.count == 1)
        for flag in ["--allow-run", "--no-allow-run", "--allow-lookups"] {
            #expect(!calls.joined().contains(flag), "\(flag)")
        }
    }
}

extension InstallConsentSplitTests {
    /// A file holding `held`, the questions still asked of it, and the rules it holds after two yes answers.
    struct HeldCase {
        let held: [String]
        let asked: [String]
        let after: [String]
    }
}
