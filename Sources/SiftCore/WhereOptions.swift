//
// Copyright © Agulhas Labs
//

/// Caller-tunable `where` behaviour; the defaults are the contract (Docs/Design.md §3).
public struct WhereOptions: Sendable {
    /// Resolves callers, overrides, and store-recorded conformers through the index store; `false` keeps the answer syntactic and never opens the store.
    public var includeSemantic: Bool
    /// Adds every recorded reference site — the rename/delete sweep view, a superset of callers that also covers type mentions.
    public var includeReferences: Bool
    /// Pages the references file list (meaningful only with `includeReferences`); the same cursor idiom as digest's.
    public var offset: Int
    /// Answers a bare name several unrelated owners declare with their declarations and narrowing queries; `false` keeps every owner's uses listed, for a caller that stands the answer in for a search's lines.
    public var collapsesSeveralOwners: Bool
    /// Name-matched call sites listed per unanswered symbol before the rest are only counted; `nil` lists ``WhereRenderer/callSiteCap``, the contract both faces' answers and the hook's in-place answers keep.
    ///
    /// The command line asks for a few: its reader is a person or an agent at a shell, and a list of leads the answer itself says may be other symbols' sites is worth its count and a sample there, not a page of them.
    public var nameMatchedSiteCap: Int?
    /// Set by the hook's in-place answers alone, never by the MCP face or the command line: the answer stands in for the lines a search printed, so it keeps a type's rows and omits the non-code section.
    ///
    /// `InPlaceAnswerer` builds `shownPerName` and `UnshownGrepLines` from those rows, and a count line alone would leave the lines a search printed unaccounted for.
    public var standsInForSearch: Bool
    /// Answers a `--refs` sweep as the files it names, one row each, in place of its sites (``WhereFilesCollector``).
    ///
    /// Implies `includeReferences`; `offset` then pages the files.
    public var filesOnly: Bool
    /// Only the declarations block, for a question that is only where the symbol is defined; the other sections are left out.
    public var declarationsOnly: Bool
    /// How the answer writes a call it suggests — set by the face that will serve it.
    public var spelling: CallSpelling

    public init(includeSemantic: Bool = true, includeReferences: Bool = false, offset: Int = 0, collapsesSeveralOwners: Bool = true, nameMatchedSiteCap: Int? = nil, standsInForSearch: Bool = false, filesOnly: Bool = false, declarationsOnly: Bool = false, spelling: CallSpelling = .commandLine) {
        self.spelling = spelling
        self.declarationsOnly = declarationsOnly
        self.filesOnly = filesOnly
        self.standsInForSearch = standsInForSearch
        self.includeSemantic = includeSemantic
        self.includeReferences = includeReferences
        self.offset = offset
        self.collapsesSeveralOwners = collapsesSeveralOwners
        self.nameMatchedSiteCap = nameMatchedSiteCap
    }
}
