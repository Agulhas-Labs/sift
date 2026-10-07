//
// Copyright © Agulhas Labs
//

/// Everything the index stores about one parsed file.
public struct ParsedFile: Sendable {
    /// Repo-relative path with symlinks resolved — the canonical identity of the file.
    public let path: String
    public let size: Int
    /// The later of the file's mtime and ctime when it was read (``FileChangeStat``); zero for content with no file behind it.
    public let mtime: Double
    public let contentHash: String
    /// Imported module names in source order.
    public let imports: [String]
    /// Number of syntax errors the parser recovered from; non-zero output is flagged, never hidden.
    public let parseErrorCount: Int
    /// All declarations in pre-order, so a parent always precedes its children.
    public let symbols: [ParsedSymbol]
}
