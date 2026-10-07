//
// Copyright © Agulhas Labs
//

import Foundation

/// An index call seen on the way out, held until its result says whether it answered.
public struct PendingIndexCall: Sendable, Equatable, Codable {
    /// The tool as the report names it, with the MCP prefix already stripped.
    public let tool: String

    /// What the call was asked about, when its arguments named something.
    public let target: String?

    /// Whether the answer, if it is a whole-file digest, weighed the file against its source.
    ///
    /// A digest paged with an offset or asked for signatures only never makes that comparison, so a summary coming back from one decided nothing about the floor — reading it as "not below" would be reading an absence as a verdict.
    public let weighsSource: Bool

    /// The Swift file stems the call's arguments named, credited as located only once the call answers.
    ///
    /// Held rather than credited on the way out, because a call that is declined, never delivered, times out or fails located nothing: crediting it would score the read that follows as guided, taking a miss out of the share on the strength of an answer that never came.
    public let located: Set<String>

    /// The targets a digest asked for, as the server resolved its arguments, credited once the call answers by the file each resolved to (``LocatedDigest``) rather than by the stems in ``located``.
    public let digestTargets: [String]

    /// The directory the call named: its `root` argument, or else the directory it was made in, and `nil` where neither is known.
    ///
    /// The answer names its files relative to the repository enclosing this, which may be a directory above it (`FloorVerdict`).
    public let root: String?

    /// Whether this call answered from the working tree rather than an `at` revision.
    ///
    /// An `at` digest is a syntactic parse of a past revision, never the working file `located` names — so it earns no `digested` credit against today's file, whatever the answer says.
    public let servesWorkingTree: Bool

    /// Whether the call was counted on its way out, which is what an error result takes back.
    ///
    /// Read off the call's own line rather than its result's, so a call counted just inside a window whose error lands just past its end is still taken back, and one made before the window opened is never taken back from a tally that never held it.
    public let counted: Bool

    public init(tool: String, target: String?, weighsSource: Bool = false, located: Set<String> = [], digestTargets: [String] = [], root: String? = nil, servesWorkingTree: Bool = true, counted: Bool = true) {
        self.tool = tool
        self.target = target
        self.weighsSource = weighsSource
        self.located = located
        self.digestTargets = digestTargets
        self.root = root
        self.servesWorkingTree = servesWorkingTree
        self.counted = counted
    }
}
