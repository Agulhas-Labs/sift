//
// Copyright © Agulhas Labs
//

/// One indexed file's stored identity.
public struct FileRow: Sendable {
    public let id: Int64
    public let path: String
    /// The later of the file's mtime and ctime when it was last parsed or hashed (``FileChangeStat``): the moment the semantic axis compares with the build anchor.
    public let mtime: Double
    public let size: Int64
    public let contentHash: String
    public let module: String
    /// True when no build file declared this path's module, so it was guessed from the first path component.
    public let moduleGuessed: Bool
    public let imports: [String]
    public let parseErrorCount: Int
}
