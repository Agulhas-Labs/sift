//
// Copyright © Agulhas Labs
//

extension String {
    /// This string right-aligned in `width` columns, or unchanged when it is already wider.
    ///
    /// One definition, for ``ByteSize``'s reason: both text faces over the logs print a leading count column, and a private copy of this in each would make the column that makes `usage` and `flakes` read as one tool two constants nothing keeps equal.
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }

    /// This string left-aligned in `width` columns, or unchanged when it is already wider.
    ///
    /// The other direction, for the same reason: the roster prints four ragged fields per server and a reader compares them down the column rather than along the line.
    func rightPadded(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
