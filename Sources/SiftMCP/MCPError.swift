//
// Copyright © Agulhas Labs
//

/// A tool-level failure, reported inside the tool result rather than as a protocol error.
struct MCPError: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}
