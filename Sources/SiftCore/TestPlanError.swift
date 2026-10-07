//
// Copyright © Agulhas Labs
//

import Foundation

/// Why a test plan could not be read, as the sentence a caller prints.
public enum TestPlanError: Error, CustomStringConvertible, Sendable {
    /// A file at the plan extension whose bytes are not the JSON document a plan is, and what the decoder said about them.
    case unreadable(path: String, reason: String)
    /// A root that could not be walked for plans at all, because it is not a directory that exists.
    case unwalkable(path: String)

    public var description: String {
        switch self {
        case let .unreadable(path, reason):
            "sift could not read the test plan at \(path): \(reason). Plans are read live from disk rather than indexed, so the file is the whole answer — fix the document, or narrow the answer to another plan with --plan."
        case let .unwalkable(path):
            "sift could not walk \(path) for test plans. Test plans are found by reading the repository itself rather than an index of it, so name a directory that exists and is readable."
        }
    }
}
