//
// Copyright © Agulhas Labs
//

import Foundation

/// How a run's answer spells the paths in it — the one thing about that answer which is a property of the reader rather than of the run.
///
/// A path inside the directory the answer is being read in is printed relative to it: the same file at a fraction of the width, and directly usable as a `Read` target. That is worth doing, and it is *only* a display decision, which is the whole reason it is a type of its own. Applied on the way **into** the measurement, the width of a path would decide how much of the answer the reader is given: one 85-error build, run twice with the same result, lists all 85 errors from inside the package and is sampled to a single `×85` line from a directory that is not its parent, where the same paths are sixty characters wider. Thirteen times the answer, decided by a `cd`.
///
/// So this hands out two things, and a listing needs both. ``shown(_:)-(String)`` is the spelling to print. ``shortening(of:)`` is what that spelling saved, which ``RunFailureCensus/listing(of:within:entries:)`` charges back to its budget so the decision is taken on the run's own spelling — the same in every directory the answer could be read in, and, because making a path relative only ever shortens it, an upper bound on what is actually served.
public struct RunAnswerPaths: Sendable {
    /// The directory paths are stated relative to, carrying its trailing separator; `nil` prints every path as the run did.
    private let base: String?
}

public extension RunAnswerPaths {
    /// Every path exactly as the run printed it, which is what a shape measured on its own terms wants.
    static let asPrinted = RunAnswerPaths(base: nil)

    /// Paths under `directory` stated relative to it, and every other path left alone.
    static func read(in directory: URL) -> RunAnswerPaths {
        let path = directory.path
        return RunAnswerPaths(base: path.hasSuffix("/") ? path : path + "/")
    }

    /// `path` as this answer states it.
    func shown(_ path: String) -> String {
        guard let base, path.hasPrefix(base) else {
            return path
        }
        return String(path.dropFirst(base.count))
    }

    /// The same diagnostic with its path stated as this answer states paths.
    ///
    /// A whole diagnostic rather than a rendered line, because a diagnostic is measured as well as printed: the shape counts the files its errors span, and it has to count the names the reader can see.
    func shown(_ diagnostic: RunDiagnostic) -> RunDiagnostic {
        guard diagnostic.path != nil || diagnostic.expansion != nil else {
            return diagnostic
        }
        return RunDiagnostic(
            severity: diagnostic.severity,
            path: diagnostic.path.map(shown),
            line: diagnostic.line,
            column: diagnostic.column,
            message: diagnostic.message,
            detail: diagnostic.detail,
            expansion: diagnostic.expansion.map { RunDiagnostic.ExpansionSite(path: shown($0.path), line: $0.line) }
        )
    }

    /// How many bytes stating `diagnostic`'s paths this way saved — its own and its macro expansion's source file both.
    func shortening(of diagnostic: RunDiagnostic) -> Int {
        shortening(of: diagnostic.path) + shortening(of: diagnostic.expansion?.path)
    }

    /// How many bytes stating `path` this way saved — nothing at all where it was left as the run printed it.
    func shortening(of path: String?) -> Int {
        guard let path else {
            return 0
        }
        return path.utf8.count - shown(path).utf8.count
    }
}
