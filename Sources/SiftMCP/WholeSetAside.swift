//
// Copyright © Agulhas Labs
//

import Foundation

extension InPlaceAnswerer {
    /// Why a candidate answer that could state its own size is still not served: the checks ``chosen(_:under:)`` holds every candidate to, in the order it holds them.
    enum Shortfall {
        /// Its refusal runs past the size budget.
        case overBudget
        /// Its refusal is no smaller than the source it weighed, or its closing line says it saved nothing.
        case notSmaller
        /// It stands in for lines it does not show while saving less than ``InPlaceAnswer/windowSavingFloor``.
        case belowFloor
    }
}

extension InPlaceAnswerer.Computed {
    /// The lines and bytes of the file a whole read asked for, where the answer is that one file's digest: what the identical re-run prints, for the opening line to state.
    ///
    /// `nil` for a file of more lines than a `Read` prints by default (``LineWindow/readDefaultLimit``), whose identical re-run does not print them all.
    var rerun: (lines: Int, bytes: Int)? {
        guard calls.count == 1, calls[0].tool == "digest", let lines = calls[0].fileLines, let bytes = calls[0].source, lines <= LineWindow.readDefaultLimit else { return nil }
        return (lines, bytes)
    }

    /// Why a whole digest no smaller than the lines its window asks for was set aside for their members: said of the digest as one that was not served, so the note is never read as the verdict on the members answer it sits in, which its closing line gives.
    static var digestNoSmallerThanItsLines: String {
        "the whole digest would be no smaller than these lines"
    }

    /// The same of the whole digests together, where a file read whole beside the window weighs in too.
    static var digestsNoSmallerThanTheOutput: String {
        "the whole digests would be no smaller than the output"
    }

    /// `reasons` as one note says them: each once, where it first appears, joined by `or`.
    static func joined(reasons: [String]) -> String {
        reasons.reduce(into: [String]()) {
            if !$0.contains($1) {
                $0.append($1)
            }
        }.joined(separator: " or ")
    }

    /// The first check the candidate framed as `refusal` fails, where it is held to the size budget `sizeBudget` and, where `weighed`, to the source its calls weighed; `nil` where it passes them all.
    func shortfall(as refusal: InPlaceAnswer.Refusal, sizeBudget: Int, weighed: Bool) -> InPlaceAnswerer.Shortfall? {
        guard refusal.served <= sizeBudget else { return .overBudget }
        guard weighed else { return nil }
        guard undercutsWhatItWeighs(served: refusal.served), !InPlaceAnswer.deniesSaving(inReason: refusal.text) else { return .notSmaller }
        return savesTooLittleForWhatItHides(served: refusal.served) ? .belowFloor : nil
    }

    /// Why this whole answer was set aside for the members of its windows, as the members answer's note says it: `shortfall`, of the whole digest, or of the whole digests together where a file read whole weighs in too.
    ///
    /// Beside a file read whole, no one window's digest is what fell short. Where the line as a whole saves enough and one file's own windows fall short, the note names that file and its saving, not the line's. Each reason is worded no longer than the one it replaced, since the note is part of what the members answer is weighed as, and a line of several files can carry more than one. A whole answer with no shortfall is served itself, so its wording is never read.
    func whySetAside(_ shortfall: InPlaceAnswerer.Shortfall?, served: Int) -> String {
        let readsWhole = calls.contains { $0.fileLines != nil }
        return switch shortfall {
        case .overBudget:
            "the whole digest is over the size budget"
        case .belowFloor where !lineSavesTooLittle(served: served):
            fileSavingTooLittleForWhatItHides.map {
                "\($0.file)'s windows save only \($0.saving) B, under \(InPlaceAnswer.windowSavingFloor) B"
            } ?? "the whole digests save under \(InPlaceAnswer.windowSavingFloor) B"
        case .belowFloor:
            (readsWhole ? "the whole digests save" : "the whole digest saves") + " under \(InPlaceAnswer.windowSavingFloor) B"
        case .notSmaller, nil:
            readsWhole ? Self.digestsNoSmallerThanTheOutput : Self.digestNoSmallerThanItsLines
        }
    }
}
