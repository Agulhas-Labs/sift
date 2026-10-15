//
// Copyright © Agulhas Labs
//

/// What `affected` was asked to look at: which change set, and how far to follow references out of it.
public struct AffectedOptions: Sendable {
    /// The commit range the change set is read from, or `nil` for the working tree against `HEAD`.
    public var range: CommitRange?
    /// How many reference hops to follow out from the changed declarations.
    public var depth: Int
    /// The test or suite names to ask about by themselves, each answered under the list whether or not its caps hid it, in the order given; empty to ask nothing.
    ///
    /// A name given twice is kept once.
    public let probes: [String]
    /// Whether a partly affected target is named by every affected suite's filter at any length, rather than by its own filter where the suite list would pass 2,000 characters.
    public var listSuites: Bool

    public init(range: CommitRange? = nil, depth: Int = AffectedOptions.defaultDepth, probes: [String] = [], listSuites: Bool = false) {
        self.range = range
        self.listSuites = listSuites
        self.depth = max(1, depth)
        var seen: Set<String> = []
        self.probes = probes.filter { seen.insert($0).inserted }
    }
}

public extension AffectedOptions {
    /// Two hops, which is one more than the question sounds like it needs.
    ///
    /// One hop answers "which tests name the changed code themselves", and on a codebase with any test-helper layer at all that is an under-count: a suite that builds its fixture through `TestSources.makeTempRepo` names the helper, never the thing the helper touched. Two hops admit exactly that shape — test → helper → changed symbol — which is the case worth paying for.
    ///
    /// It stops there because the growth is the whole problem, not the depth: at three hops a change deep in a core type reaches most of the suite through some chain, and a list that names everything has stopped being a list. **A bounded walk is bounded**, and the answer says so at whatever depth it ran, because the failure this tool must never have is a reader treating "not listed" as "not affected".
    static let defaultDepth = 2

    /// The two commits a range change set is read between.
    struct CommitRange: Sendable, Equatable {
        public let from: String
        public let to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }

        public var described: String {
            "\(from)..\(to)"
        }
    }

    /// The line saying how many uncommitted `.swift` files a range leaves out, newline-terminated; empty without a range or without such files.
    ///
    /// A range reads commits, so edits not yet committed are outside it, and the answer says so rather than read as a change that affects nothing.
    internal func uncommittedNote(git: GitContext, enumerator: FileEnumerator) throws -> String {
        guard range != nil else { return "" }
        let count = try git.dirtySwiftFiles().filter { enumerator.isIndexable(relativePath: $0.path) }.count
        guard count > 0 else { return "" }
        return "\(count) uncommitted .swift file\(count == 1 ? " is" : "s are") not in this range; drop --from to include them, or commit first.\n"
    }
}
