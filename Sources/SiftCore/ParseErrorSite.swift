//
// Copyright © Agulhas Labs
//

/// One syntax error the parser recovered from, placed at the line and column where it starts.
public struct ParseErrorSite: Sendable, Equatable {
    /// The 1-based line.
    public let line: Int
    /// The 1-based column, counted in UTF-8 bytes as the compiler counts it.
    public let column: Int
    /// The parser's own wording of the error.
    public let message: String
}
