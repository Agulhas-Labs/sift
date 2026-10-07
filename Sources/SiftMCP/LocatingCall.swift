//
// Copyright © Agulhas Labs
//

import Foundation

/// The index call that first located a file in a context: the tool it was, and its `tool_use_id`.
///
/// `tool` is the index tool's own name for an MCP call, `bash` for a `sift` command line, and `answer` for an answer the advice hook gave in a refusal's place.
public struct LocatingCall: Sendable, Equatable, Hashable, Codable {
    public let tool: String
    public let call: String

    public init(tool: String, call: String) {
        self.tool = tool
        self.call = call
    }
}
