//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Claude Code defers an MCP tool unless the tool asks otherwise, so every exposed tool carries the ask wherever the server loads its tools up front.
struct ToolsLoadUpFrontTests {
    @Test
    func everyExposedToolAsksToLoadWithTheToolList() {
        let tools = MCPToolCatalog.tools(loadUpFront: true)
        #expect(!tools.isEmpty)
        for tool in tools {
            let meta = tool["_meta"] as? [String: Any]
            #expect(meta?["anthropic/alwaysLoad"] as? Bool == true, "\(tool["name"] ?? "?") would be deferred")
        }
    }
}
