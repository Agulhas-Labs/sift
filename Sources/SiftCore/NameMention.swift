//
// Copyright © Agulhas Labs
//

/// One place a name is written in the working tree — a spelling, never a resolved symbol.
public struct NameMention: Sendable, Hashable {
    public let path: String
    public let line: Int

    public init(path: String, line: Int) {
        self.path = path
        self.line = line
    }
}
