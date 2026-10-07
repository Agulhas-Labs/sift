//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `digest <file>.md`: the heading outline a large document is located by, read live from disk and never stored.
///
/// The fixtures are deliberately longer than the compression floor, because everything but the floor's own case has to be measured on a document whose outline is actually served rather than replaced by the source.
@Suite(.temporaryDirectories)
struct MarkdownOutlineDigestTests {
    /// Nineteen lines of headings, then filler: the sections' ranges stay fixed while the document grows past the floor, and the last one is the one that has to run to the end of the file.
    private static var document: String {
        """
        # Guide

        The document a reader lands in.

        ## Scope

        What this covers.

        ### Details

        One level down.

        ### Limits

        Another.

        ## Storage

        Where it goes.
        """
    }

    /// The document with enough filler beneath it to clear the floor — 80 lines, the last section running to the last of them.
    private static var paddedDocument: String {
        document + "\n" + (1 ... 61).map { "Filler line \($0)." }.joined(separator: "\n") + "\n"
    }

    private static func engine(_ documents: [String: String]) async throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Anchor {}\n", to: "Sources/App/Anchor.swift", in: root)
        for (path, text) in documents {
            try TestSources.write(text, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        return engine
    }

    private static func outline(of document: String, at path: String = "Docs/Notes.md") async throws -> String {
        let engine = try await engine([path: document])
        return try engine.digest(target: path, options: DigestOptions())
    }

    @Test
    func everyHeadingCarriesItsLevelItsRangeAndItsSize() async throws {
        let answer = try await Self.outline(of: Self.paddedDocument)

        let lines = answer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Indented against the shallowest level present, two spaces a level, so the nesting is the outline.
        #expect(lines[2].hasPrefix("Guide  :1-80  (80 lines, "))
        #expect(lines[3].hasPrefix("  Scope  :5-16  (12 lines, "))
        #expect(lines[4].hasPrefix("    Details  :9-12  (4 lines, "))
        #expect(lines[5].hasPrefix("    Limits  :13-16  (4 lines, "))
        // The last section runs to the end of the file, and a `##` holds the `###`s beneath it.
        #expect(lines[6].hasPrefix("  Storage  :17-80  (64 lines, "))
        #expect(lines.count == 7)
    }

    /// A document whose headings all start at `##` is not pushed a level in from the left for nothing.
    @Test
    func indentationIsMeasuredFromTheShallowestLevelTheDocumentUses() async throws {
        let document = "## Scope\n\n" + (1 ... 61).map { "Filler line \($0)." }.joined(separator: "\n") + "\n### Details\n\nbody\n"

        let answer = try await Self.outline(of: document)

        #expect(answer.contains("\nScope  :1-66  "))
        #expect(answer.contains("\n  Details  :64-66  "))
    }

    /// The rule the whole thing turns on: these documents quote shell sessions and Markdown at each other, so a `#` under a fence is code.
    @Test
    func aHashInsideAFencedBlockIsNotAHeading() async throws {
        let document = """
        # Guide

        ```sh
        # not a heading
        ```

        ~~~
        ## also not a heading
        ~~~

        ## Real

        """ + (1 ... 61).map { "Filler line \($0)." }.joined(separator: "\n") + "\n"

        let answer = try await Self.outline(of: document)

        #expect(!answer.contains("not a heading"))
        #expect(answer.contains("\n  Real  :11-72  "))
    }

    /// A fence a document never closes — a truncated transcript, an unfinished example — runs to the end of it, so nothing beneath is a heading.
    @Test
    func anUnclosedFenceRunsToTheEndOfTheFile() async throws {
        let document = "# Guide\n\n```\n## swallowed\n\n" + (1 ... 61).map { "Filler line \($0)." }.joined(separator: "\n") + "\n"

        let answer = try await Self.outline(of: document)

        #expect(!answer.contains("swallowed"))
        #expect(answer.contains("\nGuide  :1-66  "))
    }

    @Test
    func aClosingRunOfHashesIsStrippedFromTheTitle() async throws {
        let document = "# Guide ##\n\n## Scope ###\n\n## C#\n\n" + (1 ... 61).map { "Filler line \($0)." }.joined(separator: "\n") + "\n"

        let answer = try await Self.outline(of: document)

        #expect(answer.contains("\nGuide  :1-67  "))
        #expect(answer.contains("\n  Scope  :3-4  "))
        // A run closes the heading only where a space precedes it, so a name that ends in one keeps it.
        #expect(answer.contains("\n  C#  :5-67  "))
    }

    @Test
    func aDocumentWithNoHeadingsSaysSoRatherThanAnsweringWithAnEmptyList() async throws {
        let document = (1 ... 61).map { "Filler line \($0)." }.joined(separator: "\n") + "\n"

        let answer = try await Self.outline(of: document)

        #expect(answer.contains("Docs/Notes.md — 61 lines, "))
        #expect(answer.hasSuffix("no headings — a plain Read is the way to see this one"))
    }

    /// The cap and the cursor every digest uses, counting the entries this answer actually has.
    @Test
    func theCapPagesTheHeadingsWithAnOffset() async throws {
        let document = (1 ... 70).map { "## Section \($0)\n\nbody\n" }.joined()
        let engine = try await Self.engine(["Docs/Notes.md": document])

        let first = try engine.digest(target: "Docs/Notes.md", options: DigestOptions())
        let second = try engine.digest(target: "Docs/Notes.md", options: DigestOptions(offset: 60))

        #expect(first.contains("\nSection 1  :1-3  "))
        #expect(first.contains("\nSection 60  :178-180  "))
        #expect(!first.contains("\nSection 61  "))
        #expect(first.hasSuffix("truncated: 10 more outline lines — pass --offset 60"))
        #expect(second.contains("(…60 outline lines skipped)"))
        #expect(second.contains("\nSection 61  :181-183  "))
        #expect(second.contains("\nSection 70  :208-210  "))
    }

    /// The file line, and the measurement the answer carries: the outline as served, against the document it stands in for.
    @Test
    func theFileLineNamesItsSizeAndTheOutlineIsWeighedAgainstTheDocument() async throws {
        let engine = try await Self.engine(["Docs/Notes.md": Self.paddedDocument])

        let answer = try engine.measuredDigest(target: "Docs/Notes.md", options: DigestOptions())

        let bytes = try #require(answer.bytes)

        #expect(answer.text.hasPrefix(
            "Docs/Notes.md — 80 lines, \(ByteSize.short(bytes.source)) — read live from disk — headings only, nothing in it is indexed\n\n"
        ))
        #expect(bytes.answer == answer.text.utf8.count)
        #expect(bytes.source == Self.paddedDocument.utf8.count - 1)
    }

    /// The floor applies to prose as it does to source: a table of contents for a page and a half summarises nothing the document does not already say.
    @Test
    func aShortDocumentIsServedAsItsOwnSourceWithTheArithmetic() async throws {
        let document = "# Guide\n\nOne short paragraph.\n\n## Scope\n\nAnother.\n"

        let answer = try await Self.outline(of: document)

        #expect(answer.contains("an outline would cost ") && answer.contains("% of the document, so the source itself follows"))
        #expect(!answer.contains("declaration"))
        #expect(answer.contains("One short paragraph."))
        #expect(answer.contains("## Scope"))
    }

    /// The same rule a Swift digest keeps: `signaturesOnly` asks for less than the default, so the floor never answers it with the whole document.
    @Test
    func signaturesOnlyKeepsAShortDocumentAnOutline() async throws {
        let document = "# Guide\n\nOne short paragraph.\n\n## Scope\n\nAnother.\n"
        let engine = try await Self.engine(["Docs/Notes.md": document])

        let answer = try engine.digest(target: "Docs/Notes.md", options: DigestOptions(signaturesOnly: true))

        #expect(!answer.contains("so the source itself follows"))
        #expect(!answer.contains("One short paragraph."))
        #expect(answer.contains("Scope"))
    }

    /// An absolute path under the root is the same document; one outside it is refused for leaving the root, not for being absent.
    ///
    /// The document here sits in no repository, so there is no root to name — the refusal says that rather than pointing at a flag that would not help.
    @Test
    func anAbsolutePathUnderTheRootAnswersAndOneOutsideItIsRefusedForLeavingIt() async throws {
        let engine = try await Self.engine(["Docs/Notes.md": Self.paddedDocument])
        let elsewhere = try TestSources.makeTempDirectory().appendingPathComponent("Notes.md")
        try Self.paddedDocument.write(to: elsewhere, atomically: true, encoding: .utf8)

        let inside = try engine.digest(target: engine.repoRoot.appendingPathComponent("Docs/Notes.md").path, options: DigestOptions())
        let outside = try engine.digest(target: elsewhere.path, options: DigestOptions())

        #expect(inside.hasPrefix("Docs/Notes.md — 80 lines, "))
        #expect(outside == "\(elsewhere.path) is outside this root (\(CanonicalPath.of(engine.repoRoot.path))) — the file is there, in no repository to root at — read it directly")
    }

    /// A document in another repository names the root that would answer, because the refusal already knows both paths.
    ///
    /// The clause a reader acts on is the first one: "no Markdown file at <path>" for a file `ls` confirms sends them to look for the path, and the next move is a `find` that returns the path just rejected.
    @Test
    func aDocumentInAnotherRepositoryNamesTheRootThatWouldAnswerIt() async throws {
        let engine = try await Self.engine(["Docs/Notes.md": Self.paddedDocument])
        let sibling = try TestSources.makeTempRepo()
        try TestSources.write(Self.paddedDocument, to: "Docs/Contract.md", in: sibling)
        let target = sibling.appendingPathComponent("Docs/Contract.md").path

        let answer = try engine.digest(target: target, options: DigestOptions())

        #expect(answer == "\(target) is outside this root (\(CanonicalPath.of(engine.repoRoot.path))) — the file is there; re-run with --root \(CanonicalPath.of(sibling.path))")
    }

    /// A relative target that leaves the root is resolved against the root, not against the directory the process happens to be in.
    ///
    /// `--root` is there to be pointed elsewhere, so a caller standing in some third directory is the ordinary case rather than the odd one. The probe that decides this refusal has to resolve the target the way the reading that decided it left the root already resolved it, or the two are talking about different files: one asks "is there a document here?" of the caller's directory while the other has already answered "not under the root" about another place entirely. Resolved against the caller instead, this document — which is there — is reported absent.
    @Test
    func aRelativeTargetOutsideTheRootIsResolvedAgainstTheRootAndNotTheCallersDirectory() async throws {
        let container = try TestSources.makeTempDirectory()
        let root = try TestSources.makeTempRepo(at: container.appendingPathComponent("repo"))
        try TestSources.write("struct Anchor {}\n", to: "Sources/App/Anchor.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try Self.paddedDocument.write(to: container.appendingPathComponent("Contract.md"), atomically: true, encoding: .utf8)
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()

        let answer = try engine.digest(target: "../Contract.md", options: DigestOptions())

        #expect(answer.contains(" is outside this root ("))
        #expect(answer.hasPrefix("/"))
    }

    /// A path inside the root that names nothing keeps the exact-path rule: there the first clause is true, and the rule is what the reader needs.
    @Test
    func aPathInsideTheRootThatNamesNothingKeepsTheExactPathRule() async throws {
        let engine = try await Self.engine(["Docs/Notes.md": Self.paddedDocument])

        let answer = try engine.digest(target: engine.repoRoot.appendingPathComponent("Docs/Absent.md").path, options: DigestOptions())

        #expect(answer.hasPrefix("no Markdown file at "))
        #expect(answer.hasSuffix(" — a .md target is read live from disk by its exact path, repo-relative or absolute under the root"))
    }

    /// A path that is not there is told what a `.md` target takes — with or without a directory in front of it, since a bare `.md` name is no type either, and "no indexed file" would be true of every document.
    @Test
    func aMarkdownPathThatIsNotThereNamesTheExactPathRule() async throws {
        let engine = try await Self.engine(["Docs/Notes.md": Self.paddedDocument])

        let nested = try engine.digest(target: "Docs/Absent.md", options: DigestOptions())
        let bare = try engine.digest(target: "Absent.md", options: DigestOptions())

        #expect(nested == "no Markdown file at Docs/Absent.md — a .md target is read live from disk by its exact path, repo-relative or absolute under the root")
        #expect(bare == "no Markdown file at Absent.md — a .md target is read live from disk by its exact path, repo-relative or absolute under the root")
    }

    /// A `.md` target no document answers is a miss like any other, so the face that knows what was typed can say that `A.md B.md` was most likely two targets sent as one.
    @Test
    func aMarkdownMissIsMarkedAsAMissAndAnOutlineIsNot() async throws {
        let engine = try await Self.engine(["Docs/Notes.md": Self.paddedDocument])

        #expect(try engine.measuredDigest(target: "Absent.md Other.md", options: DigestOptions()).missed)
        #expect(try !engine.measuredDigest(target: "Docs/Notes.md", options: DigestOptions()).missed)
    }

    /// A CRLF document outlines exactly as its LF twin: no carriage return in a title, and a closing run of `#`s still stripped.
    @Test
    func aDocumentWithCRLFLineEndingsOutlinesAsItsLFTwinDoes() async throws {
        let crlf = Self.paddedDocument.replacingOccurrences(of: "\n", with: "\r\n")
        let engine = try await Self.engine(["Docs/Notes.md": Self.paddedDocument, "Docs/Windows.md": crlf])

        let unix = try engine.digest(target: "Docs/Notes.md", options: DigestOptions())
        let windows = try engine.digest(target: "Docs/Windows.md", options: DigestOptions())

        #expect(!windows.contains("\r"))
        #expect(windows.split(separator: "\n").dropFirst(2).map { $0.split(separator: "  :")[0] }
            == unix.split(separator: "\n").dropFirst(2).map { $0.split(separator: "  :")[0] })
    }

    /// A heading with no text is an entry a reader can still tell apart from a rendering fault.
    @Test
    func aHeadingWithNoTextIsShownAsUntitled() async throws {
        let answer = try await Self.outline(of: "# Guide\n\n###\n\nBody.\n" + Self.paddedDocument)

        #expect(answer.contains("  (untitled)  :3-5  (3 lines, "))
    }

    /// Read live, so an edit since the last commit is in the answer — there is nothing stored about a document to go stale.
    @Test
    func theDocumentIsReadFromDiskAtQueryTime() async throws {
        let engine = try await Self.engine(["Docs/Notes.md": Self.paddedDocument])
        try TestSources.write("## Added since the commit\n\n" + Self.paddedDocument, to: "Docs/Notes.md", in: engine.repoRoot)

        let answer = try engine.digest(target: "Docs/Notes.md", options: DigestOptions())

        #expect(answer.contains("Added since the commit  :1-2  "))
    }

    /// A `.md` target in a list of several renders exactly as it would alone.
    @Test
    func aMarkdownTargetBesideOthersRendersAsItWouldAlone() async throws {
        let engine = try await Self.engine(["Docs/Notes.md": Self.paddedDocument])

        let alone = try engine.digest(target: "Docs/Notes.md", options: DigestOptions())
        let together = try engine.digest(targets: ["Sources/App/Anchor.swift", "Docs/Notes.md"], options: DigestOptions())

        #expect(together.contains(alone))
    }

    /// A UTF-8 BOM ahead of the first heading is not part of any line by the time this sees them — decoding a file as UTF-8 strips it — so the outline is exactly the same as the twin with no BOM at all.
    @Test
    func aDocumentStartingWithAByteOrderMarkOutlinesTheSameAsWithoutIt() async throws {
        let withBOM = try await Self.outline(of: "\u{FEFF}" + Self.paddedDocument)
        let without = try await Self.outline(of: Self.paddedDocument)

        #expect(withBOM == without)
    }

    /// The extension check is case-insensitive by design, so `.MD` is a Markdown target exactly as `.md` is.
    @Test
    func anUppercaseMDExtensionIsRecognisedAsMarkdown() async throws {
        let engine = try await Self.engine(["Docs/Notes.MD": Self.paddedDocument])

        let answer = try engine.digest(target: "Docs/Notes.MD", options: DigestOptions())

        #expect(answer.hasPrefix("Docs/Notes.MD — 80 lines, "))
    }

    /// A path spelled with `..` resolves lexically to the document it names, inside the root, and answers under that document's own canonical path.
    @Test
    func aPathContainingDotDotResolvesWithinTheRoot() async throws {
        let engine = try await Self.engine(["Docs/Notes.md": Self.paddedDocument])

        let answer = try engine.digest(target: "Docs/../Docs/Notes.md", options: DigestOptions())

        #expect(answer.hasPrefix("Docs/Notes.md — 80 lines, "))
    }

    /// The case the issue was filed over: a heading whose own body is one long run of top-level bullets stays a single row in the outline until this — now each bullet is its own row underneath it, woven in at the position it sits in the document, range first.
    @Test
    func aSectionsTopLevelBulletsAreWovenInBeneathItsHeading() async throws {
        let document = """
        # Known-open

        - **Crate.init(crateData:) turns a missing weight statistic into 0**
          instead of leaving it unset.
        - ~~CrateClassifier's dead year-less date formats remain~~

        """ + (1 ... 61).map { "Filler line \($0)." }.joined(separator: "\n") + "\n"

        let answer = try await Self.outline(of: document)

        #expect(answer.contains(
            "\n  :3-4  Crate.init(crateData:) turns a missing weight statistic into 0\n"
        ))
        #expect(answer.hasSuffix(
            "\n  :5-66  ~~CrateClassifier's dead year-less date formats remain~~  [struck]"
        ))
    }

    /// A directory whose own name ends in `.md` is not a document: it gets the same honest miss an absent file gets, never a crash and never a wrong outline.
    @Test
    func aDirectoryNamedWithADotMDSuffixIsAMissNotADocument() async throws {
        let engine = try await Self.engine(["Docs/Notes.md": Self.paddedDocument])
        try FileManager.default.createDirectory(
            at: engine.repoRoot.appendingPathComponent("Docs/Folder.md"),
            withIntermediateDirectories: true
        )

        let answer = try engine.digest(target: "Docs/Folder.md", options: DigestOptions())

        #expect(answer == "no Markdown file at Docs/Folder.md — a .md target is read live from disk by its exact path, repo-relative or absolute under the root")
    }
}
