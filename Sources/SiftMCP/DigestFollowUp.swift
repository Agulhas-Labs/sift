//
// Copyright © Agulhas Labs
//

import Foundation

/// What the ranged reads that followed a digest went back for.
///
/// A count of files read whole after their digest says the file was read anyway; it cannot say what for, or whether the digest was missing anything at all. This can, because a ranged read names the lines it wanted and the digest text recorded alongside it says which member those lines are. A read that lands on a member the digest spelled out is the loop working; one that lands on a nested type the digest showed only as a count is a digest that should have named more.
public struct DigestFollowUp: Sendable, Equatable {
    /// The read took lines the digest had already named and located.
    public var namedMember = 0

    /// The read took a container — a nested type, or an extension in a file digest — the digest gave a count for and no names.
    public var collapsedNested = 0

    /// The read took essentially the whole declaration back, so no single member explains it.
    public var wholeDeclaration = 0

    /// The read landed past one end of everything the digest described — content no digest records.
    ///
    /// A `#if DEBUG` / `#Preview` block below the last member, the file-head doc comment and imports above the first, or, for a type digest, a different declaration further down the same file. None of it is a digest defect: the symbol visitor skips previews deliberately, prose and imports are not declarations, and a type digest never claimed the rest of the file. Filed as its own row because preview reads would otherwise land in `unattributed` — a row read as "the digest failed to cover these lines" while nothing was ever meant to.
    public var unrecordedContent = 0

    /// The range fell inside what the digest described and still matched no member.
    ///
    /// What is left once the two ends are accounted for, and the only part of this that reads as a defect: the digest described lines either side of these and said nothing about them.
    public var unattributed = 0

    /// Containers read back after being shown as a count.
    public var collapsed: [Collapsed] = []

    public var total: Int {
        namedMember + collapsedNested + wholeDeclaration + unrecordedContent + unattributed
    }

    public static func += (lhs: inout DigestFollowUp, rhs: DigestFollowUp) {
        lhs.namedMember += rhs.namedMember
        lhs.collapsedNested += rhs.collapsedNested
        lhs.wholeDeclaration += rhs.wholeDeclaration
        lhs.unrecordedContent += rhs.unrecordedContent
        lhs.unattributed += rhs.unattributed
        lhs.collapsed += rhs.collapsed
    }

    /// A read covering at least this much of what the digest described is not about any one member.
    static let wholeDeclarationFraction = 0.8
}

public extension DigestFollowUp {
    /// A container read back after being shown as a count, and the local day the read happened.
    ///
    /// Dated like every other finding, so a report shared days after a digest change cannot pass the old examples off as current.
    struct Collapsed: Sendable, Equatable {
        public var name: String
        public var day: String?
    }
}
