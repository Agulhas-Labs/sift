//
// Copyright © Agulhas Labs
//

/// The runs of plain literals a `+` joins in one file, and the wording only their joined text holds.
///
/// `strings` lists a line whose literal holds the query, so wording split as `"the build did " +` / `"not complete"` is held by no literal of its own. A run is read as the text its pieces print, and is a match only when no piece holds the query alone: a piece that does is listed already, and listing it twice would spend the cap on one site.
struct ConcatenatedLiteralRuns {
    /// What stands between two pieces where a match is shown, so the row reads `"the build did " + "not complete"`.
    static var separator: String {
        "\" + \""
    }

    private var current: [Piece] = []
    private var runs: [[Piece]] = []

    /// Reads the literals of line `line`, with `continuing` the lexer's ``SwiftLiteralLexer/continuesRun`` for them.
    mutating func add(_ literals: [SwiftLiteralLexer.Literal], continuing: [Bool], line: Int) {
        for (literal, continues) in zip(literals, continuing) {
            if !continues {
                close()
            }
            current.append(Piece(line: line, literal: literal))
        }
    }

    /// Every run of two pieces or more, in file order, whose joined text holds `query` where no piece holds it alone; call it once the file's last line is read.
    mutating func matches(of query: String) -> [Match] {
        close()
        return runs.compactMap { Self.match(of: query, in: $0) }
    }

    private mutating func close() {
        if current.count > 1 {
            runs.append(current)
        }
        current = []
    }

    /// `query` found in the run's joined spelling, or failing that the joined text it prints (``SwiftLiteralLexer/Literal/contains(_:)`` reads both).
    private static func match(of query: String, in run: [Piece]) -> Match? {
        guard !run.contains(where: { $0.literal.contains(query) }) else {
            return nil
        }
        for form in [run.map { $0.literal.segments[0] }, run.map { $0.literal.printedSegments[0] }] {
            let joined = form.joined()
            guard let found = SmartCaseQuery.range(of: query, in: joined) else { continue }
            let start = joined.distance(from: joined.startIndex, to: found.lowerBound)
            return located(start ..< start + joined.distance(from: found.lowerBound, to: found.upperBound), lengths: form.map(\.count), in: run)
        }
        return nil
    }

    /// The pieces `match`, a range of the joined text, touches, shown as written; an offset read in printed text is placed at the same offset of the written piece, near enough to centre a window on.
    private static func located(_ match: Range<Int>, lengths: [Int], in run: [Piece]) -> Match {
        let starts = lengths.indices.map { lengths[..<$0].reduce(0, +) }
        let first = starts.indices.first { starts[$0] + lengths[$0] > match.lowerBound } ?? 0
        let last = starts.indices.last { starts[$0] < match.upperBound } ?? first
        let touched = run[first ... last].map(\.literal.text)
        var shownStarts: [Int] = []
        var offset = 0
        for text in touched {
            shownStarts.append(offset)
            offset += text.count + separator.count
        }
        let shownOffset = { (position: Int, piece: Int) in
            shownStarts[piece - first] + min(position - starts[piece], touched[piece - first].count)
        }
        let window = shownOffset(match.lowerBound, first) ..< shownOffset(match.upperBound, last)
        return Match(line: run[first].line, shown: touched.joined(separator: separator), window: window)
    }
}

extension ConcatenatedLiteralRuns {
    /// One literal of a run and the line it is written on.
    struct Piece {
        let line: Int
        let literal: SwiftLiteralLexer.Literal
    }

    /// A run holding the query: the line of the first piece the match touches, the touched pieces as written joined by `" + "`, and where the match falls in that text.
    struct Match {
        let line: Int
        let shown: String
        let window: Range<Int>
    }
}
