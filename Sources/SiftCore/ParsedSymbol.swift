//
// Copyright © Agulhas Labs
//

/// One declaration extracted from a file — the compact value record the visitor emits per symbol.
public struct ParsedSymbol: Sendable {
    public let kind: SymbolKind
    public let name: String
    /// Index of the enclosing container within the file's symbol array, or `nil` at top level.
    public let parentIndex: Int?
    public let line: Int
    public let column: Int
    public let endLine: Int
    public let accessLevel: AccessLevel
    public let isStatic: Bool
    /// `true` for a stored property (a variable binding with no accessor block).
    public let isStored: Bool
    /// The declaration head as written in source, whitespace-collapsed (attributes through return/inheritance clause).
    public let signature: String
    /// The inheritance clause entries as written — superclass and protocols are indistinguishable syntactically, so both land here.
    public let inherited: [String]
    /// First line of the doc comment, when present.
    public let docSummary: String?
    /// The enclosing `#if` condition chain, when the declaration sits inside conditional compilation.
    public let ifConfigCondition: String?
    /// For a `some View` property, the nesting of view constructions in its body — see `ViewOutline`.
    public let viewOutline: String?
}
