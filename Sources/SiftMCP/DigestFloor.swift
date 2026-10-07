//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Whether reading a Swift file whole actually cost anything a digest could have saved.
///
/// `digest` has a compression floor: below it the summary costs more than the code, so the tool serves the source itself and says so. A session that read such a file directly got byte-identical content to what the index would have returned — `digest ChuteTap` answers "a digest would cost 67% of the source, so the source itself follows". Counting those reads as lookups that went *around* the index is simply false, and it makes the adoption number worse than the truth.
///
/// The judgement here is **`SourcePassthrough`'s own**, asked of the part of it a path out of a transcript can answer: `SourcePassthrough.wouldServeSource(source:)` decides, this only finds the bytes to hand it. It is not the whole predicate, and cannot be — the two byte ratios need a rendered digest and the declaration ceiling needs a parse — so that call states the bias each omission carries, in both directions. What the two never do is run different arithmetic: sharing one constant and restating the decision around it is the divergence that agrees until it doesn't — a line-count-only floor would excuse whole-file reads of exactly the files the code ceiling had just decided were worth a digest.
///
/// One consequence stays worth stating here: it is measured against the file's content **now**, not when it was read.
public struct DigestFloor {
    /// The crossover, for the callers that state it — the decision itself is `SourcePassthrough`'s.
    public static let lines = SourcePassthrough.floorLineCeiling

    /// Above this many bytes the file is taken as over the floor without being opened.
    ///
    /// This runs on the audit's path, which walks every transcript in a window. Reading a 300 KB file to discover it has more than 60 lines is pure waste, and a size this far past `lines × a generous line length` cannot be under the floor by any realistic formatting. A minified or generated file could in principle beat it; that resolves to "not below the floor", which is the conservative direction everything here rounds towards.
    public static let byteCeiling = lines * 200

    /// Whether `digest` would have handed back this file's source rather than a summary.
    ///
    /// A file that cannot be read — missing, deleted, or not text this can decode — is *not* excused: the honest answer to "did this cost anything" is unknown, and the conservative reading is that it did.
    ///
    /// The byte ceiling above is the only judgement made here; everything past it is `SourcePassthrough`'s. Cheap enough for the path it runs on: the ceiling caps what is ever decoded at `lines × 200` bytes, and the scan that follows is one pass over that.
    public static func wouldServeSource(_ path: String) -> Bool {
        guard let source = text(at: path) else { return false }
        return SourcePassthrough.wouldServeSource(source: source)
    }

    /// The same question for whichever kind of file `path` is: a Swift file's source, or a Markdown document's own text in place of its heading outline.
    ///
    /// Which of the two is asked is `MarkdownOutline.names`, the test `digest` itself routes on, so the floor cannot decide a path is prose that the renderer would have treated as a type name. Everything else a `digest` answers — a module, a repo overview — reaches no floor at all, and a path that is neither is judged as source, which is what every caller but ``ReadAdvice`` has always passed.
    public static func wouldServeContent(_ path: String) -> Bool {
        guard let source = text(at: path) else { return false }
        return MarkdownOutline.names(path)
            ? SourcePassthrough.wouldServeDocument(source: source)
            : SourcePassthrough.wouldServeSource(source: source)
    }

    /// The file's text, or `nil` where it is past the byte ceiling, missing, or not text this can decode — each of which resolves to "not below the floor" in the callers above.
    private static func text(at path: String) -> String? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard let size = (attributes?[.size] as? NSNumber)?.intValue, size <= byteCeiling else { return nil }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A `wouldServeContent` that answers each path once.
    ///
    /// A cold read is a first touch, so within one transcript nothing repeats — but the audit walks every transcript in a window, and the same `SummaryState.swift` is first-touched in each of them. Sharing one of these across a run turns hundreds of redundant reads into one per file.
    public static func memoised() -> (String) -> Bool {
        let answers = Answers()
        return { path in answers.value(for: path) }
    }
}

private extension DigestFloor {
    /// A tiny reference box, so the closure above can memoise without static mutable state.
    final class Answers {
        private var known: [String: Bool] = [:]

        func value(for path: String) -> Bool {
            if let known = known[path] {
                return known
            }
            let answer = DigestFloor.wouldServeContent(path)
            known[path] = answer
            return answer
        }
    }
}
