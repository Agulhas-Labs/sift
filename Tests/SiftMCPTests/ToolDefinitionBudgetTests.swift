//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// The tool list loads in full in every Swift session, so its schema is held to a budget (Docs/Design.md §4) without dropping a tool or a parameter.
struct ToolDefinitionBudgetTests {
    /// Measured at about 1.4k tokens before this budget; the slim list serializes to about 2.5 kB here, alwaysLoad marks included.
    static let budget = 2600

    @Test
    func theServedToolListFitsTheBudget() throws {
        let data = try JSONSerialization.data(withJSONObject: MCPToolCatalog.tools(loadUpFront: true), options: [.sortedKeys])

        #expect(data.count <= Self.budget, "\(data.count) bytes")
    }

    /// Slimming is wording only: every parameter a caller could pass before is still in the schema.
    @Test
    func everyToolKeepsEveryParameter() {
        let expected: [String: Set<String>] = [
            "digest": ["target", "targets", "root", "all", "signaturesOnly", "offset", "at"],
            "where": ["symbol", "root", "refs", "offset", "at"],
            "search": ["query", "root", "offset", "count"],
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
