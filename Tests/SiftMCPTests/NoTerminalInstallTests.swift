//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// Where nobody can answer the allow-rule questions, the install says exactly what to run, and `sift install` and `install.sh` carry the flags that answer them up front.
@Suite(.temporaryDirectories)
struct NoTerminalInstallTests {
    /// The line names the command, the form to type it in from Claude Code, and the lookups-only flag, on one line.
    @Test
    func theNoTerminalLineNamesTheCommandAndTheInSessionForm() throws {
        let machine = try InstallCommandHarness(onPath: ["claude"])

        let run = try machine.run(["--yes"])

        let line = try #require(run.printed.split(separator: "\n").first { $0.contains("permissions: nothing added") })

        #expect(line.contains("(no terminal to ask in)"))
        #expect(line.contains("run: \(machine.binary) install-hook --allow-run"))
        #expect(line.contains("! \(machine.binary) install-hook --allow-run"))
        #expect(line.contains("--allow-lookups"))
    }

    /// `sift install --allow-run` adds both blocks with no terminal, and `--allow-lookups` only the lookups.
    @Test(arguments: [
        (flag: "--allow-run", rules: RunAllowRules.rules + LookupAllowRules.rules),
        (flag: "--allow-lookups", rules: LookupAllowRules.rules),
    ])
    func installTakesTheFlagsThatAnswerForTheTerminal(flag: String, rules: [String]) throws {
        let machine = try InstallCommandHarness(onPath: ["claude"])

        let run = try machine.run(["--yes", flag])

        #expect(run.status == 0)
        #expect(run.asked.isEmpty)
        #expect(!run.printed.contains("nothing added"))
        let settings = machine.home.appendingPathComponent(".claude/settings.json")
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        let allowed = (object["permissions"] as? [String: Any])?["allow"] as? [String]
        #expect(Set(allowed ?? []) == Set(rules))
    }

    /// `install.sh` hands its flags to the one `install-hook` call and refuses any other before installing.
    @Test
    func installShPassesItsFlagsThroughAndRefusesOthers() throws {
        let script = try String(contentsOf: GuideCommandReferenceTests.repositoryRoot.appendingPathComponent("Distribution/install.sh"), encoding: .utf8)
        let calls = script.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") && $0.contains("install-hook") }

        #expect(calls.count == 1)
        #expect(calls.first?.contains("install-hook \"$@\"") == true)
        #expect(script.contains("--allow-run | --allow-lookups) ;;"))
        #expect(script.contains("unknown option"))
    }
}
