//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// `--verdict` and the suppression log name one decision by one rule: a call a gate withheld and let through is printed under the rule the log records, never as `noLookup`.
@Suite(.temporaryDirectories)
struct VerdictNamesLoggedRuleTests {
    /// A search for a name no index declares is withheld by the `unknownName` gate; the probe's line names that gate, as the log does.
    @Test
    func aSearchForAnUndeclaredNameIsPrintedUnderTheRuleTheLogRecords() throws {
        let scratch = try TemporaryDirectory.make("verdict-rule")
        let log = scratch.appendingPathComponent("suppressions.jsonl")

        let verdict = Self.decided("grep -n 'Depot' Sources/App/Depot.swift", scratch: scratch, log: log, declared: false)

        #expect(verdict.line == "allowed\t\tunknownName")
        #expect(try Self.rules(in: log) == ["unknownName"])
    }

    /// A call no gate withheld keeps `noLookup`: the rule is taken from the log only where the log was written.
    @Test
    func aCallNoGateWithheldIsStillNoLookup() throws {
        let scratch = try TemporaryDirectory.make("verdict-rule")
        let log = scratch.appendingPathComponent("suppressions.jsonl")

        let verdict = Self.decided("ls Sources", scratch: scratch, log: log, declared: true)

        #expect(verdict.line == "allowed\t\tnoLookup")
        #expect(try Self.rules(in: log).isEmpty)
    }
}

private extension VerdictNamesLoggedRuleTests {
    /// `command` decided as `run` decides it, against stores under `scratch` and the suppression log at `log`.
    static func decided(_ command: String, scratch: URL, log: URL, declared: Bool) -> PreToolUseCommand.Verdict {
        PreToolUseCommand.decided(
            command: command,
            payload: [:],
            cwd: "/repo",
            session: "s1",
            context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: nil),
            ledger: AdviceLedger(directory: scratch.appendingPathComponent("advice")),
            usage: UsageLog(fileURL: scratch.appendingPathComponent("usage.jsonl")),
            suppressions: log,
            runPermission: { _ in WrappedRunPermission(allowed: [], vetoed: []) },
            couldAnswer: { _, _ in declared }
        ).verdict
    }

    /// The rules the log at `url` records, in order, or none where it was never written.
    static func rules(in url: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
            try (JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["rule"] as? String
        }
    }
}
