//
// Copyright © Agulhas Labs
//

/// One file's share of a build's timings, body time and expression time kept apart because the first already includes most of the second.
public struct BuildTimingFileTotal: Sendable, Equatable {
    /// Repo-relative path of the file.
    public let path: String
    public let bodyMilliseconds: Double
    public let bodyLines: Int
    public let expressionMilliseconds: Double
    public let expressionLines: Int

    public init(path: String, bodyMilliseconds: Double, bodyLines: Int, expressionMilliseconds: Double, expressionLines: Int) {
        self.path = path
        self.bodyMilliseconds = bodyMilliseconds
        self.bodyLines = bodyLines
        self.expressionMilliseconds = expressionMilliseconds
        self.expressionLines = expressionLines
    }
}
