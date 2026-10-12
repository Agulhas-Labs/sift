//
// Copyright © Agulhas Labs
//

/// What `affected` returns to its callers beside the rendered answer.
extension AffectedRenderer {
    struct Output {
        let body: String
        let axis: SemanticAxis
        /// The tests the list names, for a caller that renders them in its own words — `diff`, which embeds them as one bounded section rather than the whole answer.
        var reached: [ReachedTest] = []
        /// How many ways the limits block lists of this answer being short — the number a caller pointing at that block owes its reader.
        var limitCount = 0
        var depth = AffectedOptions.defaultDepth
        /// How many changed files the resolved walk went on from past `depth`, so a caller stating the bound states its exception too.
        var walkedOn = 0
        /// The furthest hop the walk-on went to, or `nil` where it went on from no file.
        var walkedTo: Int?
        /// The repo-relative files the axis counted as newer than the build, so a caller judging more files can count each once.
        var newerFiles: Set<String> = []
    }

    /// One test the walk reached, as the list prints it.
    struct ReachedTest: Sendable {
        let target: String
        let described: String
        let depth: Int
        let nameMatch: Bool
        /// `path:line`, and the drift marker where the evidence no longer stands against the build.
        let location: String
    }
}
