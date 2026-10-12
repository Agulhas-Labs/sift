//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// What the search an in-place answer stands in for prints, worked out for ``InPlaceAnswerer`` before it opens an engine.
struct GrepPrintedLines {
    /// The lines the command's own search prints, or why no answer can account for them — worked out before the engine is opened, since it needs nothing but the files.
    ///
    /// A whole read — of a Swift file or of a document — makes no search, and prints nothing this has to account for. A search that prints nothing is not answered: an answer would name lines the command never showed. A sweep's search runs under a ceiling (``referenceCeiling(budget:)``) and stops at the first line no `where` answer could locate, or once locating them all would cost more than the whole refusal may.
    ///
    /// A names search runs wherever it carries the command's own search (``InPlaceCall/symbols(names:paths:uncovered:proof:unchecked:spelled:)``). One whose pattern needs a proof (``InPlaceShape/needsProof(_:)``) runs under a ceiling that stops at a line outside Swift source but spends nothing, since the references it is proven against are never served; any other admits every file and stops once what it prints passes the size budget, past which any answer that fits is smaller. Printing nothing leaves it the names search it is.
    ///
    /// With the lines comes what a sweep's answer is weighed against: the bytes its search prints after its cut, the fewest any order prints where the cut is across files whose order grep leaves unfixed (every line any order prints coming with them, for the answer to locate), `Int.max` where the search stopped past its print limit, and `nil` for every other shape. A search that cannot be worked out at all cannot be weighed either, so it is withheld `unchecked` — except a names search with no proof, which ran no search before it was weighed and is answered unweighed, as it was then.
    static func of(_ call: InPlaceCall, from directory: String?, sizeBudget: Int) -> Result<(lines: [ShellGrep.PrintedLine], bytes: Int?), InPlaceAnswerer.Withholding> {
        let search: ShellGrep
        var proves = true
        switch call {
        case .fileDigest, .documentOutline, .symbols(_, _, _, nil, _, _), .memberRange:
            return .success(([], nil))
        case let .symbols(_, _, _, grep?, unchecked, _):
            // A tree searched beside a Swift file is withheld `unchecked` once its bounds hold, and runs nothing first.
            proves = InPlaceShape.needsProof(grep.pattern)
            guard proves || !unchecked else { return .success(([], nil)) }
            search = grep
        case let .declarations(_, grep), let .members(grep), let .references(_, grep):
            search = grep
        }
        let ceiling: ShellGrep.Ceiling? = switch call.shape {
        case .sweep:
            referenceCeiling(budget: sizeBudget)
        case .symbols where proves:
            ShellGrep.Ceiling(admits: ExactAnswer.whereAnswerLocates(linesOf:), cost: { _, _ in 0 }, budget: 0)
        case .symbols:
            ShellGrep.Ceiling(admits: { _ in true }, cost: { _, _ in 0 }, budget: 0, printLimit: sizeBudget)
        default:
            nil
        }
        let namedFiles = call.shape == .members || call.shape == .symbols && search.paths.contains { $0.hasSuffix(".swift") }
        let weighed = call.shape == .sweep || call.shape == .symbols
        // A names search proves nothing against what it prints, so sift's own cache is no line it has to account for.
        let measured = search.measured(in: directory, ceiling: ceiling, namedFiles: namedFiles, weighsAnyOrder: weighed, skipsCache: call.shape == .symbols && !proves)
        return switch measured.outcome {
        case let .printed(lines) where lines.isEmpty && call.shape == .symbols:
            .success((lines, measured.bytes))
        case let .printed(lines) where lines.isEmpty:
            .failure(.notExact)
        case let .printed(lines):
            .success((lines, weighed ? measured.bytes : nil))
        case .undecided where call.shape == .symbols && !proves, .pastLimit where call.shape == .symbols && !proves:
            // What a search that cannot be worked out prints is unknown, so it is answered unweighed, as it was before it was weighed.
            .success(([], nil))
        case .undecided, .pastLimit:
            .failure(.unchecked)
        case .pastCeiling(.unaccounted):
            .failure(.notExact)
        case .pastCeiling(.overBudget) where search.cut != nil && measured.bytes <= sizeBudget:
            // A cut search past its budget has read every file, and an answer over the budget is larger than the
            // fewest bytes any order of them prints wherever those fit it.
            .failure(.notSmaller)
        case .pastCeiling(.overBudget):
            .failure(.overSize)
        case .pastCeiling(.printsPastLimit):
            .success(([], Int.max))
        }
    }

    /// The most a sweep's search may print: lines only of files a `where` answer lists lines of, and no more of them than the fewest bytes that locate them fit inside `budget`.
    static func referenceCeiling(budget: Int) -> ShellGrep.Ceiling {
        ShellGrep.Ceiling(admits: ExactAnswer.whereAnswerLocates(linesOf:), cost: ExactAnswer.leastSpentLocating(_:ofFileAt:), budget: budget)
    }
}
