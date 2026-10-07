//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// A whole read of a file whose whole digest this context holds only through the usage log is let through as one held through the ledger is: classified as no lookup and noted `alreadyDigested`, never answered with the digest it already holds.
@Suite(.temporaryDirectories)
struct UsageLogHeldReadTests {
    /// A shell line whose only lookup is a whole read of the held file — bare, beside a statement that is no lookup, or ahead of a fallback that runs only if it fails — is let through, where the same line with nothing on the usage log is still answered.
    @Test(arguments: [
        "cat Sources/App/Shell.swift",
        "cat Sources/App/Shell.swift; echo done",
        "cat Sources/App/Shell.swift || cat Sources/App/Other.swift",
    ])
    func aBareShellReadOfAFileHeldThroughTheUsageLogIsLetThrough(command: String) throws {
        let fixture = try HeldWindowLineTests.fixture()

        let held = try Self.judged(command, in: fixture, usageLog: ["Sources/App/Shell.swift"])
        let cold = try HeldWindowLineTests.judged(command, in: fixture, session: "s2")

        #expect(held.lookup == nil)
        #expect(held.rules == ["alreadyDigested"])
        #expect(cold.line.hasPrefix("in-place\t"))
    }

    /// A lookup no answer covers beside such a read — a grep whose output is filtered — is logged under the rule that withholds it, as it is beside a read the ledger holds.
    @Test
    func aFilteredGrepBesideAReadHeldThroughTheUsageLogIsStillLogged() throws {
        let fixture = try HeldWindowLineTests.fixture()

        let judged = try Self.judged("cat Sources/App/Shell.swift; grep -rn part1 Sources | sort", in: fixture, usageLog: ["Sources/App/Shell.swift"])

        #expect(judged.lookup == nil)
        #expect(judged.rules == ["filteredOutput", "alreadyDigested"])
    }

    /// A line of several whole reads, every one of a file held through the usage log, is no lookup, noted `alreadyDigested` once; with one of them cold the held read is dropped and the cold one left.
    @Test
    func aLineOfWholeReadsAllHeldThroughTheUsageLogIsNotedAlreadyDigested() throws {
        let fixture = try HeldWindowLineTests.fixture()
        let command = "cat Sources/App/Shell.swift; cat Sources/App/Other.swift"

        let both = try Self.judged(command, in: fixture, usageLog: ["Sources/App/Shell.swift", "Sources/App/Other.swift"])
        let one = try Self.judged(command, in: fixture, usageLog: ["Sources/App/Shell.swift"])

        #expect(both.lookup == nil)
        #expect(both.rules == ["alreadyDigested"])
        #expect(one.lookup?.inPlace?.calls.compactMap(\.readPath) == ["Sources/App/Other.swift"])
        #expect(one.rules.isEmpty)
    }

    /// The lookup the hook classifies `command` as, run in the repository in session `s1`, agent `a1`, whose usage log holds a digest of each of `usageLog`, and the rules it logged classifying it.
    private static func judged(
        _ command: String,
        in fixture: AlreadyDigestedReadTests.Fixture,
        usageLog targets: [String]
    ) throws -> (lookup: PreToolUseCommand.Lookup?, rules: [String]) {
        let usage = try DigestedFilesTests.UsageLogFile(targets.map {
            ["tool": "digest", "target": $0, "root": fixture.repo.path, "ms": 3, "ok": true, "session": "s1", "agent": "a1", "outBytes": 900, "srcBytes": 12000]
        })
        let recording = try AdviceAgreementTests.Recording()
        defer {
            usage.cleanup()
            recording.cleanup()
        }
        let lookup = PreToolUseCommand.lookup(
            command: nil,
            payload: ["session_id": "s1", "agent_id": "a1", "tool_name": "Bash", "tool_input": ["command": command], "tool_use_id": "toolu_u1"],
            in: fixture.repo.path,
            noting: recording.log,
            digested: usage.digested,
            couldAnswer: { _, _ in true }
        )
        return (lookup, recording.rules)
    }
}
