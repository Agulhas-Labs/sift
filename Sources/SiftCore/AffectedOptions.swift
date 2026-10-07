//
// Copyright © Agulhas Labs
//

/// What `affected` was asked to look at: which change set, and how far to follow references out of it.
public struct AffectedOptions: Sendable {
    /// The commit range the change set is read from, or `nil` for the working tree against `HEAD`.
    public var range: CommitRange?
    /// How many reference hops to follow out from the changed declarations.
    public var depth: Int
    /// A test or suite name to ask about by itself, answered under the list whether or not its caps hid it, or `nil` to ask nothing.
    public var probe: String?

    public init(range: CommitRange? = nil, depth: Int = AffectedOptions.defaultDepth, probe: String? = nil) {
        self.range = range
        self.depth = max(1, depth)
        self.probe = probe
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
}
