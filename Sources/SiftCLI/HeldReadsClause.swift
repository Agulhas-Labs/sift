//
// Copyright © Agulhas Labs
//

import SiftCore

/// What a batched-read note adds when it leaves a file out because the context already holds its digest: that file's read stays on the line, since the digest of the rest does not replace it.
struct HeldReadsClause {
    /// The clause closing the note's sentence, empty where no read was dropped.
    ///
    /// Each file is named once, in the order it was first read, however many times the line reads it. The wording does not say whole: the dropped read may be a line window of the file, and "the read of" a file reads as the whole file.
    static func text(for held: [String]) -> String {
        var seen = Set<String>()
        let distinct = held.filter { seen.insert($0).inserted }
        guard !distinct.isEmpty else { return "" }
        let named = distinct.map { "`\(ShellWord.quoted($0))`" }.joined(separator: ", ")
        let reads = distinct.count == 1 ? "its own read" : "their own reads"
        return ", keeping \(reads) of \(named), which this context already holds"
    }
}
