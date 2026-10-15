//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The `not code` section a `where --refs` answer ends with: its header counts, its per-file rows, the `file names:` row, the none line, its paging beside the code lists, and the answers that carry no section.
@Suite(.temporaryDirectories)
struct WhereNonCodeSectionTests {
    private typealias Line = NonCodeMentions.Line

    private static func swiftFile(_ path: String, _ lines: [Line], codeLines: Int = 0) -> NonCodeMentions.File {
        NonCodeMentions.File(path: path, isMarkdown: false, lines: lines, codeLines: codeLines)
    }

    private static func mentions(_ files: [NonCodeMentions.File], names: [NonCodeMentions.FileName] = []) -> NonCodeMentions {
        NonCodeMentions(files: files, fileNames: names, swiftFilesRead: 12, markdownFilesRead: 3)
    }

    /// One file per path, each with one comment line, for paging.
    private static func commented(_ count: Int) -> NonCodeMentions {
        mentions((1 ... count).map { swiftFile(String(format: "Sources/F%03d.swift", $0), [Line(number: 1, kind: .comment)]) })
    }

    private static let mixed = mentions([
        swiftFile("Sources/Gizmo.swift", [Line(number: 3, kind: .docLink), Line(number: 4, kind: .doc), Line(number: 9, kind: .comment), Line(number: 12, kind: .string)], codeLines: 2),
        NonCodeMentions.File(path: "Docs/Gizmo.md", isMarkdown: true, lines: [Line(number: 2, kind: .docLink), Line(number: 7, kind: .markdown), Line(number: 9, kind: .markdown)], codeLines: 0),
    ], names: [NonCodeMentions.FileName(path: "Sources/Gizmo.swift", isLead: false), NonCodeMentions.FileName(path: "Sources/GizmoCore.swift", isLead: true)])

    @Test
    func theHeaderCountsEachKindOverTheTreeAndTheLinesAlsoCode() {
        let section = WhereNonCodeSection(mentions: Self.mixed, isAmbiguous: false)

        #expect(section.header == "not code, by written name — 2 DocC-link lines, 1 doc-comment line, 1 comment line, 1 string-literal line, 2 Markdown lines, 2 file names (1 a lead); 2 of these lines are also code lines listed above:")
    }

    @Test
    func severalOwnersOrAQualifiedQuerySayTheSectionMayHoldOtherSymbols() {
        let section = WhereNonCodeSection(mentions: Self.mentions([Self.swiftFile("A.swift", [Line(number: 1, kind: .comment)])]), isAmbiguous: true)

        #expect(section.header == "not code, by written name; may include same-named symbols — 1 comment line:")
    }

    @Test
    func eachFileIsOneRowWithEveryKindListedAndMarkdownLinesBare() {
        let many = (1 ... WhereRenderer.lineListCap + 5).map { Line(number: $0, kind: .doc) }
        let section = WhereNonCodeSection(mentions: Self.mixed, isAmbiguous: false)
        let long = section.row(Self.swiftFile("Sources/Long.swift", many))
        let shown = many.map { String($0.number) }.joined(separator: ", ")

        #expect(section.row(Self.mixed.files[0]) == "  Sources/Gizmo.swift (4): DocC 3 · doc 4 · comment 9 · string 12")
        #expect(section.row(Self.mixed.files[1]) == "  Docs/Gizmo.md (3): DocC 2 · 7, 9")
        #expect(long == "  Sources/Long.swift (\(many.count)): doc \(shown)")
    }

    @Test
    func theFileNamesRowIsOnTheFirstPageOnly() {
        let section = WhereNonCodeSection(mentions: Self.mixed, isAmbiguous: false)
        let first = SyntacticSweepPaging(offset: 0)
        let later = SyntacticSweepPaging(offset: 1)

        #expect(first.settle(section.lines(offset: 0, paging: first, joinsPager: false)).last == "  file names: Sources/Gizmo.swift, Sources/GizmoCore.swift (a lead)")
        #expect(!later.settle(section.lines(offset: 1, paging: later, joinsPager: false)).contains { $0.contains("file names:") })
    }

    @Test
    func nothingFoundIsOneLineNamingWhatWasReadAndWhatWasNot() {
        let section = WhereNonCodeSection(mentions: Self.mentions([]), isAmbiguous: false)

        #expect(section.lines(offset: 0, paging: SyntacticSweepPaging(offset: 0), joinsPager: false) == [
            "",
            "not code, by written name — none in the 12 Swift and 3 Markdown files read; storyboards, xibs, plists, string catalogs and project files not read",
        ])
    }

    @Test
    func withAStoreTheSectionShowsTheStoresWindowAndContinuesPastTheCodeList() {
        let offset = WhereRenderer.listCap
        let paging = SyntacticSweepPaging(offset: offset)
        let code = paging.pastEnd(ofOutsideList: 3)
        let lines = paging.settle(["  " + code] + WhereNonCodeSection(mentions: Self.commented(offset + 5), isAmbiguous: false).lines(offset: offset, paging: paging, joinsPager: false))

        #expect(lines.first == "  (all 3 files shown on earlier pages)")
        #expect(lines.contains("  (…\(offset) files skipped)"))
        #expect(lines.contains(String(format: "  Sources/F%03d.swift (1): comment 1", offset + 5)))
        #expect(!lines.contains { $0.contains("truncated:") })
    }

    @Test
    func withAStoreTheSectionPastItsEndSaysSoWhileTheCodeListContinues() {
        let offset = WhereRenderer.listCap
        let paging = SyntacticSweepPaging(offset: offset)
        let code = paging.pastEnd(ofOutsideList: offset + 10)
        let lines = paging.settle([code] + WhereNonCodeSection(mentions: Self.commented(2), isAmbiguous: false).lines(offset: offset, paging: paging, joinsPager: false))

        #expect(lines.contains("  (all 2 files shown on earlier pages)"))
        #expect(!lines.contains { $0.contains("drop offset") })
    }

    @Test
    func everyListPastItsEndStillAdvisesDroppingTheOffset() {
        let paging = SyntacticSweepPaging(offset: 50)
        let lines = paging.settle(WhereNonCodeSection(mentions: Self.commented(2), isAmbiguous: false).lines(offset: 50, paging: paging, joinsPager: false))

        #expect(lines.contains("  " + PastEndLine.text(offset: 50, count: 2, noun: "files")))
    }

    @Test
    func inANoStoreSweepTheSectionJoinsThePagerAndACodeListPastItsEndSaysSo() {
        let offset = 3
        let paging = SyntacticSweepPaging(offset: offset)
        let code = paging.page(files: ["Sources/A.swift"], indent: "  ") { ["  \($0): 1"] }
        let lines = paging.settle(code + WhereNonCodeSection(mentions: Self.commented(offset + 2), isAmbiguous: false).lines(offset: offset, paging: paging, joinsPager: true))

        #expect(lines.first == "  (all 1 file shown on earlier pages)")
        #expect(lines.contains("  (…\(offset) files skipped)"))
        #expect(lines.contains("  Sources/F005.swift (1): comment 1"))
    }

    /// The section's pages are no part of the owners' sweep, so running past one alone raises no advice to narrow it; a code list past one still does.
    @Test
    func aSectionAlonePastOnePageDoesNotSpanTheSweep() {
        let alone = SyntacticSweepPaging(offset: 0)
        let section = WhereNonCodeSection(mentions: Self.commented(WhereRenderer.listCap + 2), isAmbiguous: false)
        let aloneLines = alone.settle(alone.page(files: ["Sources/A.swift"], indent: "  ") { ["  \($0): 1"] } + section.lines(offset: 0, paging: alone, joinsPager: true))
        #expect(aloneLines.contains { $0.contains("truncated:") })
        #expect(!alone.spansPages)

        let both = SyntacticSweepPaging(offset: 0)
        let files = (1 ... WhereRenderer.listCap + 2).map { String(format: "Sources/C%03d.swift", $0) }
        _ = both.settle(both.page(files: files, indent: "  ") { ["  \($0): 1"] })
        #expect(both.spansPages)
    }

    /// A store answer that carries the section has no boundary line pointing at it or at `where --refs`: the section speaks for itself.
    @Test
    func aStoreAnswerWithTheSectionCarriesNoBoundaryLine() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        let swept = try await engine.lookup(symbol: "Base", freshness: freshness, options: WhereOptions(includeReferences: true))

        #expect(swept.contains("not code, by written name"), "\(swept)")
        #expect(!swept.contains("references: code occurrences"), "\(swept)")
        #expect(!swept.contains("listed under not code below"), "\(swept)")
    }

    /// With no index store, a plain answer for a name several related owners declare points at the one declaration's qualified name, not the bare query.
    @Test
    func theNoStorePointerQualifiesAnAmbiguousName() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("class Alpha { class Gizmo {} }\nclass Beta: Alpha { class Gizmo {} }\nlet one = Alpha.Gizmo()\n" + (1 ... 8).map { "let more\($0) = Alpha.Gizmo()\n" }.joined(), to: "Sources/App/Owners.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        let answer = try await engine.lookup(symbol: "Gizmo", freshness: freshness, options: WhereOptions())

        #expect(!answer.contains("where --refs Gizmo lists them"), "\(answer)")
        #expect(answer.contains("where --refs Alpha.Gizmo lists them") || answer.contains("where --refs Beta.Gizmo lists them"), "\(answer)")
    }

    @Test
    func aNameARenameDoesNotRespellHasNoSection() {
        #expect(WhereNonCodeSection.bareName(of: "save(_:to:)") == "save")
        #expect(WhereNonCodeSection.bareName(of: "init(name:)") == nil)
        #expect(WhereNonCodeSection.bareName(of: "subscript(_:)") == nil)
        #expect(WhereNonCodeSection.bareName(of: "+") == nil)
    }

    private static func makeRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("/// A ``Gizmo`` holds parts.\nstruct Gizmo {}\nlet label = \"Gizmo\"\n", to: "Sources/App/Gizmo.swift", in: root)
        try TestSources.write("func build() -> Gizmo { Gizmo() } // makes a Gizmo\n", to: "Sources/App/Builder.swift", in: root)
        try TestSources.write("# Parts\n\nThe Gizmo type.\n", to: "Docs/Parts.md", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        return root
    }

    @Test
    func aRefsAnswerEndsWithTheSectionAndTheHooksAndARevisionsDoNot() async throws {
        let root = try Self.makeRepo()
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        let swept = try await engine.lookup(symbol: "Gizmo", freshness: freshness, options: WhereOptions(includeReferences: true))
        let hook = try await engine.lookup(symbol: "Gizmo", freshness: freshness, options: WhereOptions(includeReferences: true, standsInForSearch: true))
        let revision = try await engine.lookup(symbol: "Gizmo", at: "HEAD", options: WhereOptions(includeReferences: true))
        let tail = swept.split(separator: "\n", omittingEmptySubsequences: false).suffix(5).map(String.init)

        #expect(tail == [
            "not code, by written name — 1 DocC-link line, 1 comment line, 1 string-literal line, 1 Markdown line, 1 file name; 1 of these lines is also a code line listed above:",
            "  Docs/Parts.md (1): 3",
            "  Sources/App/Builder.swift (1): comment 1",
            "  Sources/App/Gizmo.swift (2): DocC 1 · string 3",
            "  file names: Sources/App/Gizmo.swift",
        ], "\(swept)")
        #expect(!hook.contains("not code, by written name"), "\(hook)")
        #expect(revision.hasSuffix("\n\n" + WhereNonCodeSection.atRevisionLine), "\(revision)")
    }
}
