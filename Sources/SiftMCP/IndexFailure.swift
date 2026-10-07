//
// Copyright © Agulhas Labs
//

import Foundation

/// An index call that came back an error, with enough on it to act on.
///
/// A bare count — `failed 10 index calls that came back an error` — says nothing else. Ten of what, asked about what, failing how: none of it survives, in the one row of the report that is unambiguously a defect rather than a habit. The usage log has the tool, the target, the reason and the day; this keeps them rather than throwing the audit's copy away at the moment it classifies the line.
public struct IndexFailure: Sendable, Equatable {
    /// The tool that failed, named as the report names it: `digest`, `where`, `search`.
    public let tool: String

    /// What it was asked about, when the call named something.
    public let target: String?

    /// What came back, as the server wrote it.
    public let reason: String

    public init(tool: String, target: String?, reason: String) {
        self.tool = tool
        self.target = target
        self.reason = reason
    }

    /// What kind of failure this is — the diagnosis, in a form that survives redaction.
    ///
    /// A pseudonymised reason (`reason-3f2a1b`) groups perfectly and diagnoses nothing, which is no use in a report that is redacted by default: knowing that six failures were the same failure does not tell you it was a root nobody had indexed. The kind is read off our own message text, carries no name from the caller's code, and so can be printed in full either way.
    ///
    /// Matching on our own strings is a real cost and worth being honest about: change a message without changing this and its failures fall to ``Kind/other``. That degrades in the one safe direction — `other` is a visible row, so a classifier that has stopped working shows up as a bucket that has stopped emptying, rather than as a confident wrong answer.
    public var kind: Kind {
        Kind(reason: reason)
    }
}

public extension IndexFailure {
    enum Kind: String, Sendable, Equatable {
        /// A root that was never indexed — the commonest failure by far, and the one with a one-line fix.
        case notIndexed = "root not indexed"
        /// A name that exists in several indexed repositories, needing `root:` to say which.
        case ambiguousRoot = "ambiguous across roots"
        /// The call arrived without the argument it needs.
        case missingArgument = "argument missing"
        /// A `search` query naming a field or kind that does not exist.
        case badQuery = "query not understood"
        /// The index build behind the answer failed.
        case indexBuild = "index build failed"
        /// Anything this does not recognise, including a message whose wording has moved on.
        case other

        init(reason: String) {
            let text = reason.lowercased()
            self = if text.contains("is not inside a git repository") {
                .notIndexed
            } else if text.contains("indexed repositories") {
                .ambiguousRoot
            } else if text.contains(" needs a ") {
                .missingArgument
            } else if text.hasPrefix("unknown field") || text.hasPrefix("unknown kind") || text.hasPrefix("unknown tool") {
                .badQuery
            } else if text.contains("step failed") {
                .indexBuild
            } else {
                .other
            }
        }
    }
}
