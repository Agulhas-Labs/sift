//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The index call that would have answered a whole-file read — of Swift source, or of a Markdown document.
///
/// The other half of the population `ShellAdvice` covers. The lookups that go around the index are shell commands and whole-file `Read`s, and a context whose shell misses are refused turns to reads instead. Refusing one without the other just moves the miss.
///
/// **A document is here because `digest` already answers one.** A `.md` path comes back as a heading outline — every heading with its section's line range and size, read live from disk — which is the same locating step for a ranged read of a long doc that a digest is for a long Swift file. The capability shipped without the advice that routes anyone to it, and a repository whose spec is Markdown (`Docs/Design.md`, `README.md`, `AGENTS.md`) is one where those reads are the ones repeated most. Substitution is what works: a refusal is an instruction and charges a whole context re-send to say no, while a whole read has no exactness cap on standing in for it — an outline is an exact answer to "what is in this document", as a digest is to "what is in this file".
///
/// The exclusions are the same three, read in each subject's own terms — all of them cases where reading the file is the *right* move and a refusal would be noise:
///
/// - **A ranged read is the loop working, once something located the file.** `Read(file, offset:, limit:)` after a digest is the second half of digest-to-locate-then-read, which is exactly what the advice asks for, and refusing it would punish compliance. Whether anything did is a fact about the context, which only the hook holds, so the hook asks this for a Swift file's ranged read as the whole read it stands in for and lets it through where the file is located. A document's ranged read is left alone here: the outline's section ranges are what it was located by.
/// - **A file below the compression floor costs nothing.** `digest` hands back the source itself down there and says so, so the read got byte-identical content. There is nothing to save and no advice worth giving. Judged by `SourcePassthrough.standsOverLittleCode`, which is the part of that decision a path holding only the file's bytes can answer — so it is conservative in the counting direction and, here, in the interrupting one: a short file dense enough to clear the code ceiling is nudged even where the byte ratios would have served its source anyway. The bias and its bounds are stated at that predicate. **A document is weighed by the same floor in its own units** (`DigestFloor.wouldServeContent`): sixty lines and twenty *non-blank* ones, since prose has no code for the Swift scan to find, and a page-and-a-half note is exactly the document `digest` already answers with its own text rather than a table of contents for it. No threshold of this rule's own invention — the floor here is the one the renderer applies when it decides what a small `.md` gets back.
/// - **A small document is cheaper read than guessed at.** A whole read of a Markdown document of at most ``smallDocumentBytes`` on disk — about 2k tokens — is let through by the hook, and logged there as `smallDocument`. The outline saves a fraction of a read that small, and an agent reading a document whole is often about to edit it, which needs the exact text: then it pays for the outline, the file and a round trip over its whole context, so a wrong guess costs more than a right one saves. Bytes are the measure because bytes are what the read costs. The judgement is ``isSmallDocument(_:)``, asked by the hook rather than here, so the withholding is logged under its own rule while a document below the floor above stays excused as it always was.
/// - **Anything that is neither Swift nor Markdown** is none of this tool's business — and a build manifest is not Swift *source*: the index deliberately excludes `Package.swift`, so reading one is the right move and a `digest Package` suggestion would be a dead end.
///
/// **A Markdown lookup is advised but not counted.** `TranscriptScan`'s read population is Swift-only, so a document read whole is neither a miss against the index's share nor a lookup it served — the ruling for now, so that a number measured over Swift lookups keeps meaning what it meant; the advice is worth giving either way, since it costs the share nothing to be right.
public struct ReadAdvice {
    /// The size, in bytes on disk, at or under which a whole read of a Markdown document is let through rather than answered with its outline.
    public static let smallDocumentBytes = 8192

    /// Whether `path` is a Markdown document of at most ``smallDocumentBytes`` on disk, which the hook lets a whole read of through untouched.
    ///
    /// A file whose size cannot be read is not small: say nothing different about what cannot be judged, and the read is advised as before.
    public static func isSmallDocument(_ path: String) -> Bool {
        guard MarkdownOutline.names(path),
              let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
        else { return false }
        return size.intValue <= smallDocumentBytes
    }

    /// The suggestion for reading `path`, or `nil` when the read is not one worth interrupting.
    ///
    /// `belowFloor` is injected so the caller can share one memoised judgement, and so a test can pin the exclusion without writing files of a particular length. It is asked last, after the cheap tests on the path itself, because it is the only one that opens the file.
    public static func suggestion(
        path: String,
        ranged: Bool,
        belowFloor: (String) -> Bool = DigestFloor.wouldServeContent
    ) -> IndexSuggestion? {
        let markdown = MarkdownOutline.names(path)
        let swift = path.hasSuffix(".swift") && !SwiftPMManifest.isManifestPath(path)
        guard markdown || swift, !ranged, !belowFloor(path) else { return nil }
        // Asked for as every other surface asks for a file, and not interrupted at all where no call can be
        // made for it: a refusal has to offer a call that can be made.
        if markdown {
            guard let target = IndexSuggestion.documentTarget(for: path) else { return nil }
            return IndexSuggestion(
                call: "digest \(target)",
                yields: "every heading with its section's line range and size, read live from disk — then a ranged Read of just the section that matters"
            )
        }
        guard let target = IndexSuggestion.digestTarget(for: path) else { return nil }
        return IndexSuggestion(
            call: "digest \(target)",
            yields: "every member with its exact line range — then a ranged Read of just the part that matters"
        )
    }
}
