//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A no to the lookups question is remembered in the state directory, and the next ask defaults to no until a yes or `--allow-lookups`.
@Suite(.temporaryDirectories)
struct LookupsDeclineRememberedTests {
    fileprivate static func machine() throws -> Machine {
        let root = try TemporaryDirectory.make("decline")
        return Machine(settings: root.appendingPathComponent("settings.json"), state: root.appendingPathComponent("state"))
    }

    /// A no is recorded, and the next ask shows the no default and takes an empty line as no.
    @Test
    func aDeclineMakesTheNextAskDefaultToNo() throws {
        let machine = try Self.machine()

        let first = try machine.install(answer: "n")
        #expect(first == [AllowRunPrompt.lookupsQuestion, AllowRunPrompt.runsQuestion])
        #expect(machine.record.exists)

        let second = try machine.install(answer: "")
        #expect(second.first == AllowRunPrompt.lookupsQuestion(defaultingToNo: true))
        #expect(second.first?.hasSuffix("[y/N]\u{20}") == true)
        #expect(try !machine.hasLookupRules())
        #expect(machine.record.exists)
    }

    /// Without a decline the empty line still means yes.
    @Test
    func withNoRecordAnEmptyLineIsYes() throws {
        let machine = try Self.machine()

        _ = try machine.install(answer: "")

        #expect(try machine.hasLookupRules())
        #expect(!machine.record.exists)
    }

    /// A yes at the no default, and `--allow-lookups`, clear the record.
    @Test(arguments: [(["--allow-lookups"], nil), ([], "y")] as [([String], String?)])
    func aYesOrTheFlagClearsTheRecord(arguments: [String], answer: String?) throws {
        let machine = try Self.machine()
        machine.record.write()

        _ = try machine.install(arguments, answer: answer)

        #expect(try machine.hasLookupRules())
        #expect(!machine.record.exists)
    }

    /// An install that asks nothing neither writes nor removes the record.
    @Test(arguments: [true, false])
    func aNonInteractiveInstallLeavesTheRecordAsItWas(recorded: Bool) throws {
        let machine = try Self.machine()
        if recorded {
            machine.record.write()
        }

        for arguments in [[], ["--no-allow-run"]] {
            let asked = try machine.install(arguments, answer: "y", interactive: false)
            #expect(asked.isEmpty)
            #expect(machine.record.exists == recorded)
        }
    }
}

private extension LookupsDeclineRememberedTests {
    struct Machine {
        let settings: URL
        let state: URL

        var record: LookupsDeclineRecord {
            LookupsDeclineRecord(directory: state, environment: [:])
        }

        func install(_ arguments: [String] = [], answer: String?, interactive: Bool = true) throws -> [String] {
            var command = try InstallHookCommand.parse(["--settings", settings.path] + arguments)
            let terminal = AllowRunTerminal(answer: answer)
            command.output = RecordedOutput().output
            command.stateDirectory = state
            command.prompt = terminal.prompt(interactive: interactive)
            try command.run()
            return terminal.asked
        }

        func hasLookupRules() throws -> Bool {
            guard let data = try? Data(contentsOf: settings), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            let allow = (object["permissions"] as? [String: Any])?["allow"] as? [String] ?? []
            return LookupAllowRules.rules.allSatisfy(allow.contains)
        }
    }
}
