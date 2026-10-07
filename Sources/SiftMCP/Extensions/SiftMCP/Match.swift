//
// Copyright © Agulhas Labs
//

public extension InPlaceShape.Match {
    /// The file each call reading a whole file reads, spelled out against ``directory``; a call reading only windows of its file, or no file at all, names none.
    var wholeReadPaths: [String] {
        calls.indices.compactMap { index in
            guard !windowed[index], let path = calls[index].readPath else { return nil }
            return SwiftTree.resolve(readPath: path, relativeTo: directory) ?? path
        }
    }

    /// This match without the reads the predicate holds of — handed the read's path spelled out against ``directory``, the windows the call reads it through, and whether the call answers nothing but those windows (``windowed``) rather than a read of the whole file — or `nil` where no call is left.
    ///
    /// The predicate says which reads the hook would let through standing alone: a window of a file the context has located, a whole read of a file whose whole digest it holds or that it wrote. Such a read still prints its source, which no answer to the rest reproduces, so what is left no longer covers the whole command — a compound line's literals, which placed the whole line's output, go with it — and the line runs (``runsOtherStatements``): an answer would swallow the source the context asked for in place of a digest it already holds. A call that is no read (a search answered beside the reads) is always kept.
    func droppingReads(where letThrough: (_ path: String, _ windows: [LineWindow], _ windowed: Bool) -> Bool) -> Self? {
        let kept = calls.indices.filter { index in
            guard let path = calls[index].readPath else { return true }
            return !letThrough(SwiftTree.resolve(readPath: path, relativeTo: directory) ?? path, calls[index].windows, windowed[index])
        }
        guard !kept.isEmpty else { return nil }
        guard kept.count < calls.count else { return self }
        return Self(
            calls: kept.map { calls[$0] },
            directory: directory,
            isWholeCommand: false,
            windowed: kept.map { windowed[$0] },
            lookups: lookups,
            fallbackFollows: fallbackFollows,
            statements: statements.isEmpty ? [] : kept.map { statements[$0] }
        ).running(others: true).falling(backTo: ordinary?.droppingReads(where: letThrough))
    }
}
