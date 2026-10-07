//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A header says `clean` only for a tree measured to be one, and every other state keeps both fields it always had (Docs/AnswerContract.md §1).
@Suite(.temporaryDirectories)
struct CleanHeaderTests {
    /// The fields of a header's first line, split where the header separates them.
    private static func fields(of header: String) -> [String] {
        let first = header.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? header
        return first.components(separatedBy: WorkingTree.fieldSeparator)
    }

    private static func freshness(head: String = "abc1234", dirty: Int = 0, parseErrors: Int = 0) -> Freshness {
        Freshness(tree: WorkingTree(repository: "repo"), headShort: head, dirtyCount: dirty, parseErrorFiles: parseErrors)
    }

    // MARK: The measured state

    @Test
    func aTreeMeasuredCleanSaysSoInOneWordInPlaceOfBothFields() {
        let header = Self.freshness().headerLine

        #expect(header == "tree: repo  head: abc1234  clean  semantic: syntactic-only")
        #expect(!header.contains("dirty:"))
        #expect(!header.contains("parse_errors:"))
    }

    @Test
    func aDirtyCountAboveZeroPrintsBothFields() {
        let header = Self.freshness(dirty: 2).headerLine

        #expect(!Self.fields(of: header).contains("clean"))
        #expect(header.contains("dirty: 2  parse_errors: 0"))
    }

    @Test
    func aParseErrorCountAboveZeroPrintsBothFields() {
        let header = Self.freshness(parseErrors: 1).headerLine

        #expect(!Self.fields(of: header).contains("clean"))
        #expect(header.contains("dirty: 0  parse_errors: 1"))
    }

    /// Files the answer found changed that the dirty listing did not carry are a dirty count the listing could not measure, so the header says what it did and does not call the tree clean.
    @Test
    func aDirtyCountThatMissedFilesIsNotCalledClean() {
        let reparsed = Self.freshness().noting(reparsed: ["A.swift"], unreparsed: [])
        let unreparsed = Self.freshness().noting(reparsed: [], unreparsed: ["B.swift"])

        for header in [reparsed.headerLine, unreparsed.headerLine] {
            #expect(!Self.fields(of: header).contains("clean"), "\(header)")
            #expect(header.contains("dirty: 0 (+1 not in git status"), "\(header)")
            #expect(header.contains("parse_errors: 0"), "\(header)")
        }
    }

    /// A parse-error count the answer's own reparse raised reaches the header through `noting`, and takes `clean` away with it.
    @Test
    func aParseErrorFoundWhileReparsingTakesCleanAway() {
        let header = Self.freshness().noting(reparsed: ["A.swift"], unreparsed: [], parseErrorFiles: 1).headerLine

        #expect(!Self.fields(of: header).contains("clean"))
        #expect(header.contains("parse_errors: 1"))
    }

    @Test
    func aRepositoryWithNoCommitHasNoRevisionToBeCleanAgainst() {
        let header = Self.freshness(head: Freshness.unbornHead).headerLine

        #expect(!Self.fields(of: header).contains("clean"))
        #expect(header.contains("head: unborn  dirty: 0  parse_errors: 0"))
    }

    // MARK: Real headers

    private static func repo(committed: Bool = true) throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Alpha {}\n", to: "Sources/App/Alpha.swift", in: root)
        if committed {
            try TestSources.commitAll(in: root, message: "add alpha")
        }
        return root
    }

    @Test
    func aCommittedTreeNothingHasTouchedHasACleanHeader() async throws {
        let engine = try SiftEngine(directory: Self.repo())

        let header = try await engine.ensureFresh().headerLine

        #expect(Self.fields(of: header).contains("clean"), "\(header)")
    }

    @Test
    func anUncommittedEditHasNoCleanInItsHeader() async throws {
        let root = try Self.repo()
        try TestSources.write("struct Alpha {}\nstruct Beta {}\n", to: "Sources/App/Alpha.swift", in: root)
        let engine = try SiftEngine(directory: root)

        let header = try await engine.ensureFresh().headerLine

        #expect(!Self.fields(of: header).contains("clean"), "\(header)")
        #expect(header.contains("dirty: 1"), "\(header)")
    }

    @Test
    func aTreeWithAFileThatDoesNotParseHasNoCleanInItsHeader() async throws {
        let root = try Self.repo()
        try TestSources.write("struct Broken {\n    func one( {\n", to: "Sources/App/Broken.swift", in: root)
        try TestSources.commitAll(in: root, message: "add broken")
        let engine = try SiftEngine(directory: root)

        let header = try await engine.ensureFresh().headerLine

        #expect(!Self.fields(of: header).contains("clean"), "\(header)")
        #expect(header.contains("parse_errors: 1"), "\(header)")
    }

    @Test
    func anAnswerAtARevisionNamesTheRevisionAndNeverSaysClean() throws {
        let engine = try SiftEngine(directory: Self.repo())

        let answer = try engine.digest(targets: ["Alpha"], at: "HEAD", options: DigestOptions())

        #expect(!Self.fields(of: answer).contains("clean"), "\(answer)")
    }

    @Test
    func anAnswerReadLiveNeverSaysClean() throws {
        let header = try Freshness.liveHeaderLine(tree: WorkingTree.describing(Self.repo()))

        #expect(!Self.fields(of: header).contains("clean"), "\(header)")
    }

    // MARK: Readers

    /// What reads a header back finds the tree in either form, and the same one.
    @Test
    func theTreeReadsBackTheSameFromBothForms() {
        let tree = WorkingTree(repository: "repo", worktree: "agent-1a2b3c4d")
        let new = Freshness(tree: tree, headShort: "abc1234", dirtyCount: 0, parseErrorFiles: 0).headerLine + "\nbody"
        let old = Freshness(tree: tree, headShort: "abc1234", dirtyCount: 3, parseErrorFiles: 1).headerLine + "\nbody"

        #expect(WorkingTree.named(inAnswer: new) == tree)
        #expect(WorkingTree.named(inAnswer: old) == tree)
        #expect(WorkingTree.named(inAnswer: "tree: repo (worktree agent-1a2b3c4d)  head: abc1234  dirty: 0  parse_errors: 0  semantic: fresh\nbody") == tree)
    }

    // MARK: The mode line and the help topic

    @Test
    func aNoStoreWhereAnswerPointsAtTheTopicAndKeepsItsStateClause() async throws {
        let engine = try SiftEngine(directory: Self.repo())
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Alpha", freshness: freshness)
        let mode = try #require(output.split(separator: "\n").first { $0.hasPrefix("mode:") })

        #expect(mode.hasPrefix("mode: syntactic (sift help answers); no index store for this tree yet"), "\(mode)")
        #expect(!mode.contains("conformers matched by written name"), "\(mode)")
    }

    /// The explanation that left the line is in the topic the line points at, and the topic names the worktree recipe's home.
    @Test
    func theAnswersTopicHoldsWhatTheModeLineNoLongerSays() throws {
        let body = try #require(HelpTopics.topic(named: "answers")).body

        #expect(body.contains("matched by written name"))
        #expect(body.contains("callers, overrides and references are not answered"))
        #expect(body.contains("sift help worktree-index"))
        #expect(body.contains("`clean`"))
    }

    // MARK: The references line

    @Test
    func theTwoReferenceCaveatsAreOneLine() {
        #expect(WhereRenderer.referenceBoundaryLine == "references: code only (not comments or strings) and this repo's own build only (a sibling repo or an uncompiled target has no occurrence here) — check those before deleting")
        #expect(!WhereRenderer.referenceBoundaryLine.contains("\n"))
    }
}
