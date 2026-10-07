//
// Copyright © Agulhas Labs
//

import Foundation

/// The fallback for a file target whose directory was guessed wrong: `DigestRenderer.resolveFile`'s exact-and-suffix match has already come back `.missing`, but the file's basename is indexed once, or several times, elsewhere.
///
/// Split out of `DigestRenderer` itself — which it wraps rather than extends, so the file it lives in is free to be named for what it holds — to keep `DigestRenderer.swift` under the line-length guideline.
struct DigestFileBasenameFallback {
    let renderer: DigestRenderer

    /// Only reached once `resolveFile`'s own suffix match has already failed, so a bare basename target (no directory guessed at all) never lands here: it already matched by that suffix check, one path segment being the same as a one-segment suffix.
    func resolution(for path: String) throws -> Outcome? {
        guard path.contains("/"), path.hasSuffix(".swift") else { return nil }
        let basename = URL(fileURLWithPath: path).lastPathComponent
        let inventory = try renderer.store.fileInventory()
        let matches = inventory.keys.filter { URL(fileURLWithPath: $0).lastPathComponent == basename }.sorted()
        return switch matches.count {
        case 0:
            nil
        case 1:
            inventory[matches[0]].map(Outcome.served)
        default:
            .ambiguous(matches)
        }
    }

    /// A basename several indexed files share: none is served, because guessing one would be exactly the wrong-directory mistake this fallback exists to fix.
    ///
    /// Capped at `memberCap`, like the sibling suffix-ambiguity answer, with a truncation line rather than a list that reads as every match there is.
    func ambiguousAnswer(path: String, candidates: [String]) -> String {
        var lines = ["no indexed file matches \(path) — \(candidates.count) indexed files share that basename; digest one of these exact targets:"]
        lines += candidates.prefix(DigestRenderer.memberCap).map { "  digest \($0)" }
        if candidates.count > DigestRenderer.memberCap {
            lines.append("  truncated: \(candidates.count - DigestRenderer.memberCap) more files")
        }
        return lines.joined(separator: "\n")
    }

    /// Asks the plain-miss answer first, so a file that exists on disk but is deliberately excluded from the index keeps that answer rather than being served a different indexed file that merely shares its basename.
    ///
    /// The basename search only ever runs on a genuine miss — the path resolves inside this repository and nothing exists on disk at it — which is exactly the wrong-directory guess this fallback exists to fix.
    func missingFileResolution(path: String) throws -> MissingFileResolution {
        let plainMiss = renderer.unindexedFileAnswer(path: path)
        guard !plainMiss.excluded else {
            return .answer(MeasuredAnswer(text: plainMiss.text, missed: false))
        }
        guard let relative = renderer.relativeToRepository(path), !renderer.fileExistsOnDisk(relative) else {
            return .answer(MeasuredAnswer(text: plainMiss.text, missed: true))
        }
        return switch try resolution(for: path) {
        case let .served(row):
            .resolved(row, notice: ExactAnswer.servedNotice(asked: path, served: row.path))
        case let .ambiguous(candidates):
            .answer(MeasuredAnswer(text: ambiguousAnswer(path: path, candidates: candidates), missed: true))
        case nil:
            .answer(MeasuredAnswer(text: plainMiss.text, missed: true))
        }
    }
}

extension DigestFileBasenameFallback {
    /// What a wrong directory guess on an otherwise-real file name resolves to: nothing indexed ends in the asked path, but at least one indexed file shares its basename.
    enum Outcome {
        /// The one indexed file of that basename.
        case served(FileRow)
        /// Several indexed files share the basename — every path in the answer.
        case ambiguous([String])
    }

    /// What a file target resolves to once `DigestRenderer.resolveFile` has already come back `.missing` — this fallback, or (finding no basename match either) the plain miss `unindexedFileAnswer` already renders.
    enum MissingFileResolution {
        /// The one file the basename fallback served, and the leading line that says so.
        case resolved(FileRow, notice: String)
        /// Nothing to serve — a basename shared by several files, or no basename match at all.
        case answer(MeasuredAnswer)
    }
}
