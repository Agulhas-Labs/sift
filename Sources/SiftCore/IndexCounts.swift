//
// Copyright © Agulhas Labs
//

/// The index's row tallies, surfaced in status output and the freshness header.
public struct IndexCounts: Sendable {
    public let files: Int
    public let symbols: Int
    public let parseErrorFiles: Int
}
