//
// Copyright © Agulhas Labs
//

import Foundation

/// Why a scheme could not be read, as the sentence a caller prints.
public enum SchemeError: Error, CustomStringConvertible, Sendable {
    /// A file at the scheme extension whose bytes are not the XML document a scheme is, and what the parser said about them.
    case unreadable(path: String, reason: String)
    /// A root that could not be walked for schemes at all, because it is not a directory that exists.
    case unwalkable(path: String)

    public var description: String {
        switch self {
        case let .unreadable(path, reason):
            "sift could not read the scheme at \(path): \(reason). Schemes are read live from disk rather than indexed, so the file is the whole answer — a scheme that will not parse is one whose test action says nothing here."
        case let .unwalkable(path):
            "sift could not walk \(path) for schemes. Schemes are found by reading the repository itself rather than an index of it, so name a directory that exists and is readable."
        }
    }
}
