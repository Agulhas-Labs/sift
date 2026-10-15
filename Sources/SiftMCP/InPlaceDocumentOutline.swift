//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The in-place answer to a whole read of a document: its heading outline (``InPlaceAnswerer``).
struct InPlaceDocumentOutline {
    /// The heading outline of the document at `path`, or why it is withheld — the offer's own answer, read live from disk and handed over rather than proven.
    ///
    /// **The cheap checks run first here too, and no index is consulted at all.** The path has to name a regular file that is there, which costs a file probe; the engine is then opened for the store alone, to place that path inside the repository and render the outline through `digest`'s own renderer. Nothing calls `ensureFresh`: no part of this answer comes from the index, so there is nothing about it a stale index could make wrong.
    ///
    /// **No freshness header over it, deliberately.** The outline's own first line already says the document was read live from disk and that nothing in it is indexed; a tree line above that would price an index state nothing here consulted, and would read as a claim that this answer came from it.
    static func answer(at path: String, root: String, directory: String?) throws -> InPlaceAnswerer.Computation {
        guard let file = OperandFile.existing(path, in: directory) else { return .withheld(.notExact) }
        let engine = try EngineReuse.engine(on: root)
        defer { EngineReuse.release(engine, root: root) }
        guard let outline = try outline(ofFile: file, in: engine) else { return .withheld(.notExact) }
        // An outline past a third of the document is a table of contents nearly as long as the text, and costs
        // the turn a re-run takes to read it anyway: the read runs.
        return outline.call.served * 3 > outline.call.source ?? .max ? .withheld(.outlineTooLarge) : .answer(InPlaceAnswerer.Computed(
            calls: [outline.call],
            root: engine.repoRoot.path,
            answer: outline.text,
            standsIn: "an outline stands in for the document"
        ))
    }

    /// The heading outline of the document at `file`, with the call that served it, or `nil` where the outline would not stand in for the read.
    static func outline(ofFile file: String, in engine: SiftEngine) throws -> (call: InPlaceAnswerer.ComputedCall, text: String)? {
        guard let relative = ExactAnswer.repositoryRelativePath(of: file, in: engine),
              let outline = try ExactAnswer.documentOutline(in: engine, path: relative)
        else {
            return nil
        }
        return (InPlaceAnswerer.ComputedCall(tool: "digest", target: relative, served: outline.text.utf8.count, source: outline.bytes?.source), outline.text)
    }
}
