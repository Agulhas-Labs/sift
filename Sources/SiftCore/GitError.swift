//
// Copyright © Agulhas Labs
//

/// A failed git invocation, carrying git's own stderr.
public struct GitError: Error, CustomStringConvertible, Sendable {
    public let message: String
    /// What git itself printed on stderr, trimmed — the wording a refusal quotes when the fault is in what the caller asked git for.
    public var detail = ""

    public var description: String {
        message
    }
}
