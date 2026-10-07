//
// Copyright © Agulhas Labs
//

/// One module's row in the repo overview digest: how many files it spans and how many top-level declarations it exports.
public struct ModuleOverview: Sendable {
    public let module: String
    public let files: Int
    public let topLevelSymbols: Int
}
