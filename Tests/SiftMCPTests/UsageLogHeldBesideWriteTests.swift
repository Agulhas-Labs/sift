//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// A whole read of a file this context wrote, beside a whole read of a file whose digest the usage log holds, is let through as written: the line is never run with a note naming the digest the context already holds.
@Suite(.temporaryDirectories)
struct UsageLogHeldBesideWriteTests {
    /// The written read and the held read let the line through as written and print nothing, whether the ledger holds the digest as well or only the usage log does.
    @Test(arguments: [false, true])
    func aWrittenReadBesideAUsageLogHeldReadIsLetThroughAsWritten(alsoOnTheLedger: Bool) throws {
        let fixture = try HeldWindowLineTests.fixture()
        let edit: [String: Any] = ["tool_name": "Edit", "tool_input": ["file_path": fixture.repo.appendingPathComponent("Sources/App/Other.swift").path], "agent_id": "a1"]
        #expect(PreToolUseCommand.notesWrite(context: fixture.context("s1"), payload: edit, cwd: fixture.repo.path, ledger: fixture.ledger))
        if alsoOnTheLedger {
            fixture.take(tool: IndexToolName.prefix + "digest", input: ["target": "Sources/App/Shell.swift"])
        }

        let judged = try HeldWindowLineTests.judged("cat Sources/App/Other.swift; cat Sources/App/Shell.swift", in: fixture, located: true)

        #expect(judged.line == "allowed\t\twritten")
        #expect(judged.json == nil)
    }

    /// The control: with the held file cold, the line still runs with the note naming the call for it.
    @Test
    func aWrittenReadBesideAColdReadStillNamesTheColdOne() throws {
        let fixture = try HeldWindowLineTests.fixture()
        let edit: [String: Any] = ["tool_name": "Edit", "tool_input": ["file_path": fixture.repo.appendingPathComponent("Sources/App/Other.swift").path], "agent_id": "a1"]
        #expect(PreToolUseCommand.notesWrite(context: fixture.context("s1"), payload: edit, cwd: fixture.repo.path, ledger: fixture.ledger))

        let judged = try HeldWindowLineTests.judged("cat Sources/App/Other.swift; cat Sources/App/Shell.swift", in: fixture)

        #expect(judged.line == "allowed\t\totherStatementsRun")
    }
}
