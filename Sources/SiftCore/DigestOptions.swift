//
// Copyright © Agulhas Labs
//

/// Caller-tunable digest behaviour; the defaults are the contract (Docs/Design.md §3).
public struct DigestOptions: Sendable {
    /// Includes `private`/`fileprivate` symbols in a module digest, the only digest that hides them.
    ///
    /// A type digest and a file digest always show everything: private stored properties *are* the shape, and `private` is scoped to the very file a file digest was asked about.
    public var includeAllAccess: Bool
    /// Drops doc summaries and leading attributes from member lines.
    public var signaturesOnly: Bool
    /// Skips this many member lines — the pagination cursor paired with the `truncated:` marker.
    public var offset: Int
    /// How the answer writes a call it suggests — set by the face that will serve it.
    public var spelling: CallSpelling
    /// Member lines per page.
    ///
    /// The CLI and the MCP tool use the default alone: only the hook's answer cut to fit a size budget sets another.
    public var pageSize: Int = DigestRenderer.memberCap

    public init(includeAllAccess: Bool = false, signaturesOnly: Bool = false, offset: Int = 0, spelling: CallSpelling = .commandLine) {
        self.includeAllAccess = includeAllAccess
        self.signaturesOnly = signaturesOnly
        self.offset = offset
        self.spelling = spelling
    }
}
