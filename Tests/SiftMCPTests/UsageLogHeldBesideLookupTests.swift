//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// A lookup no answer covers, beside whole reads the context already holds, is logged under the rule that withholds it — also where one of the reads is held only by the usage log and so dropped before the ledger is asked.
@Suite(.temporaryDirectories)
struct UsageLogHeldBesideLookupTests {
    /// One read held by the usage log, one by the ledger, and a count of matches beside them: the line is let through as `alreadyDigested`, and the count's search is logged as the lookup it is.
    ///
    /// The usage-log read is the one dropped first, so classifying the line again without its key would take that read for the lookup and log nothing of the search.
    @Test
    func aSearchBesideAUsageLogHeldReadIsLoggedUnderItsRule() throws {
        let fixture = try HeldWindowLineTests.fixture()
        fixture.take(tool: IndexToolName.prefix + "digest", input: ["target": "Sources/App/Other.swift"])

        let judged = try HeldWindowLineTests.judged("cat Sources/App/Shell.swift; cat Sources/App/Other.swift; grep -rn part1 Sources | wc -l", in: fixture, located: true)

        #expect(judged.line == "allowed\t\talreadyDigested")
        let logged = try Self.logged(in: fixture)
        #expect(logged.contains { $0["rule"] as? String == "textSearch" && $0["symbol"] as? String == "part1" }, "\(logged)")
    }

    /// The suppressions the hook noted, one object per line.
    private static func logged(in fixture: AlreadyDigestedReadTests.Fixture) throws -> [[String: Any]] {
        let text = try String(contentsOf: fixture.stores.appendingPathComponent("suppressions.jsonl"), encoding: .utf8)
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
}
