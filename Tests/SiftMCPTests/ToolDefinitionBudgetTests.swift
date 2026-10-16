//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// The tool list loads in full in every Swift session, so its schema is held to a budget (Docs/Design.md §4): every tool stays, and a parameter stays while callers use it.
struct ToolDefinitionBudgetTests {
    /// About 2.2 kB serialized, alwaysLoad marks included: 1,028 tokens of first-call context before `at`, `count` and the `root` and `offset` descriptions left it, 870 after (a one-turn probe, Claude Code 2.1.299).
    static let budget = 2300

    @Test
    func theServedToolListFitsTheBudget() throws {
        let data = try JSONSerialization.data(withJSONObject: MCPToolCatalog.tools(loadUpFront: true), options: [.sortedKeys])

        #expect(data.count <= Self.budget, "\(data.count) bytes")
    }

    /// `at` and `count` left the schema for their tokens (15 of 4,598 calls in 30 days, measured 14 Oct 2026); the server still accepts both.
    @Test
    func everyToolListsTheParametersCallersUse() {
        let expected: [String: Set<String>] = [
            "digest": ["target", "targets", "root", "all", "signaturesOnly", "offset"],
            "where": ["symbol", "root", "refs", "files", "decl", "offset"],
            "search": ["query", "root", "offset"],
            "strings": ["query", "root"],
        ]
        var served: [String: Set<String>] = [:]
        for tool in MCPToolCatalog.tools(loadUpFront: false) {
            let schema = tool["inputSchema"] as? [String: Any]
            let properties = schema?["properties"] as? [String: Any] ?? [:]
            served[tool["name"] as? String ?? "?"] = Set(properties.keys)
        }

        #expect(served == expected)
    }

    /// Each description is still the trigger the model acts on, not a feature list.
    @Test
    func everyDescriptionStillOpensWithItsTrigger() {
        for tool in MCPToolCatalog.tools(loadUpFront: false) {
            let description = tool["description"] as? String ?? ""
            #expect(description.hasPrefix("Call this"), "\(tool["name"] ?? "?")")
        }
    }
}
