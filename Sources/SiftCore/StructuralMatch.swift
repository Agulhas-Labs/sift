//
// Copyright © Agulhas Labs
//

/// One declaration that satisfied a structural query.
///
/// Carries the same `path` + line range + signature a digest line does, so a match is directly actionable — a ranged Read of the hit needs nothing further resolved.
public struct StructuralMatch: Sendable, Equatable {
    public let path: String
    public let line: Int
    public let endLine: Int
    public let kind: String
    /// The declaration's own name, qualified by its enclosing types — `SummaryState.load()`, not `load()`.
    public let qualifiedName: String
    /// The declaration head as written, attributes through the signature.
    public let signature: String

    public init(path: String, line: Int, endLine: Int, kind: String, qualifiedName: String, signature: String) {
        self.path = path
        self.line = line
        self.endLine = endLine
        self.kind = kind
        self.qualifiedName = qualifiedName
        self.signature = signature
    }
}
