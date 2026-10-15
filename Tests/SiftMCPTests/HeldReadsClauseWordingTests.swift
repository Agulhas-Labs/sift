//
// Copyright © Agulhas Labs
//

@testable import SiftCLI
import Testing

/// The clause a batched-read note closes on names each held file once, and does not call its read a whole one: the dropped read may be a line window.
struct HeldReadsClauseWordingTests {
    /// `cat A A B` drops two reads of A; the clause names A once, then B, in first-seen order.
    @Test func aFileReadTwiceIsNamedOnce() {
        let clause = HeldReadsClause.text(for: ["A.swift", "A.swift", "B.swift"])

        #expect(clause == ", keeping their own reads of `A.swift`, `B.swift`, which this context already holds", "\(clause)")
    }

    /// A file named twice leaves one file, so the clause is singular.
    @Test func repeatsOfOneFileReadAsOneRead() {
        let clause = HeldReadsClause.text(for: ["A.swift", "A.swift"])

        #expect(clause == ", keeping its own read of `A.swift`, which this context already holds", "\(clause)")
    }

    /// The caller knows only the path, so a window held (`sed -n '10,40p' A.swift`) is not described as a read of the file.
    @Test func theWordingDoesNotCallTheHeldReadAWholeRead() {
        let clause = HeldReadsClause.text(for: ["A.swift"])

        #expect(!clause.contains("the read of"), "\(clause)")
    }

    /// No read dropped, no clause.
    @Test func nothingHeldIsNoClause() {
        #expect(HeldReadsClause.text(for: []).isEmpty)
    }
}
