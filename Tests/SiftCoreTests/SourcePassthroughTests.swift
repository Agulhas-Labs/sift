//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the decision to serve source instead of a digest that would cost as much as the code it summarises.
///
/// Kept in its own fixture: the sizes here are the subject of the test, so they must be free to change without disturbing the line numbers `DigestRenderTests` pins.
@Suite(.temporaryDirectories)
struct SourcePassthroughTests {
    private static func render(_ target: String, sources: [(String, String)], options: DigestOptions = DigestOptions()) throws -> String {
        try measure(target, sources: sources, options: options).text
    }

    private static func measure(_ target: String, sources: [(String, String)], options: DigestOptions = DigestOptions()) throws -> MeasuredAnswer {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let parsed = try sources.map { try TestSources.parsed($1, path: $0, in: root) }
        try store.replaceFiles(parsed) { _ in ("Alpha", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
        return try renderer.measured(target: target, options: options)
    }

    @Test
    func aTypeCheaperToPrintThanToSummariseIsServedAsSource() throws {
        let output = try Self.render("Tiny", sources: [Self.tinyType])

        #expect(output.contains("so the source itself follows"))
        #expect(output.contains("struct Tiny {"))
        #expect(output.contains("let flag: Bool"))
        // The header stays, so the answer still says where the code lives.
        #expect(output.contains("Tiny — Alpha — Sources/Alpha/Tiny.swift"))
    }

    @Test
    func theNoteShowsTheArithmeticThatDecidedIt() throws {
        let output = try Self.render("Tiny", sources: [Self.tinyType])

        // A caller who asked for a digest and got source must be able to see why, not just that.
        #expect(output.contains("4 lines"))
        #expect(output.contains("% of the source"))
    }

    @Test
    func aTypeWhoseDigestActuallyCompressesKeepsTheDigest() throws {
        let output = try Self.render("Substantial", sources: [Self.substantialType])

        #expect(!output.contains("so the source itself follows"))
        #expect(output.contains("stored properties:"))
        #expect(output.contains("members:"))
        // The bodies are what the digest exists to leave out.
        #expect(!output.contains("total += Int(String(character))"))
    }

    @Test
    func sourceIsNeverServedBeyondTheLineCeiling() throws {
        // Many very short members: the digest is capped at its member budget while the source keeps growing,
        // so the ratio alone would say "serve source" for something far too long to serve.
        let members = (0 ..< 260).map { "    let a\($0) = \($0)" }.joined(separator: "\n")
        let output = try Self.render("Sprawl", sources: [("Sources/Alpha/Sprawl.swift", "struct Sprawl {\n\(members)\n}")])

        #expect(!output.contains("so the source itself follows"))
        #expect(output.contains("stored properties:"))
    }

    @Test
    func pagingKeepsTheDigestBecauseACursorNeedsSomethingToPage() throws {
        let output = try Self.render("Tiny", sources: [Self.tinyType], options: DigestOptions(offset: 1))

        #expect(!output.contains("so the source itself follows"))
    }

    @Test
    func signaturesOnlyKeepsTheDigestBecauseItAsksForLessNotMore() throws {
        let output = try Self.render("Tiny", sources: [Self.tinyType], options: DigestOptions(signaturesOnly: true))

        #expect(!output.contains("so the source itself follows"))
    }

    @Test
    func anUnreadableSiteKeepsTheDigestRatherThanServingAPartialType() throws {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let primary = try TestSources.parsed("struct Split {\n    let flag: Bool\n}", path: "Sources/Alpha/Split.swift", in: root)
        let extended = try TestSources.parsed("extension Split {\n    var negated: Bool { !flag }\n}", path: "Sources/Alpha/Split+Ext.swift", in: root)
        try store.replaceFiles([primary, extended]) { _ in ("Alpha", false) }
        // One site gone: the comparison can no longer be made honestly, and serving the rest would hand back
        // a type with a hole in it under a header claiming both sites.
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Alpha/Split+Ext.swift"))
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)

        let output = try renderer.render(target: "Split", options: DigestOptions())

        #expect(!output.contains("so the source itself follows"))
        #expect(output.contains("stored properties:"))
    }

    @Test
    func aSmallFileIsServedAsSourceRatherThanSummarised() throws {
        let output = try Self.render("Sources/Alpha/Tiny.swift", sources: [Self.tinyType])

        #expect(output.contains("so the source itself follows"))
        #expect(output.contains("struct Tiny {"))
        #expect(output.contains("Sources/Alpha/Tiny.swift — module: Alpha"))
    }

    /// A whole-file digest's decision can be read back out of the answer it produced, in both directions.
    ///
    /// Read off answers the renderer actually wrote, so the header and note the reader looks for cannot drift from the ones written: this is what lets a finished transcript say whether a file was under the floor when the file itself is long gone.
    @Test
    func aFileDigestsVerdictIsReadBackOutOfItsOwnAnswer() throws {
        let served = try Self.render("Sources/Alpha/Tiny.swift", sources: [Self.tinyType])
        let summarised = try Self.render("Sources/Alpha/Substantial.swift", sources: [Self.substantialType])

        #expect(SourcePassthrough.fileVerdict(in: served) == SourcePassthrough.FileVerdict(path: "Sources/Alpha/Tiny.swift", servedSource: true))
        #expect(
            SourcePassthrough.fileVerdict(in: summarised)
                == SourcePassthrough.FileVerdict(path: "Sources/Alpha/Substantial.swift", servedSource: false)
        )
        // Behind the notices an answer can open with, the header is still found.
        let noticed = "⚠ a notice about the binary\n\ntree: Alpha  head: 0000000  dirty: 0\n" + served
        #expect(SourcePassthrough.fileVerdict(in: noticed)?.servedSource == true)
    }

    /// A shared answer's second file is credited from its own header, never from a header-shaped line sitting inside an earlier file's body.
    ///
    /// A file served as source is printed raw, and raw source can hold anything — including a column-0 line that happens to match the header shape for another file this same shared answer goes on to name. `Gizmo`'s real header sits after the blank line `DigestRenderer.joinedAnswers` puts between parts; the look-alike sitting inside `Rogue`'s served body starts no part at all, so it must never stand in for the header that does.
    @Test
    func aHeaderShapedLineInAServedFilesBodyNeverCreditsTheFileBehindIt() throws {
        let rogueSource = "struct Rogue {\n    let marker = \"\"\"\nSources/Alpha/Gizmo.swift — module: Alpha\n\"\"\"\n}\n"
        let rogue = ("Sources/Alpha/Rogue.swift", rogueSource)
        let gizmo = ("Sources/Alpha/Gizmo.swift", "struct Gizmo {\n    let flag: Bool\n    let count: Int\n}\n")
        let rogueAnswer = try Self.render("Sources/Alpha/Rogue.swift", sources: [rogue, gizmo])
        let gizmoAnswer = try Self.render("Sources/Alpha/Gizmo.swift", sources: [rogue, gizmo])
        // Both served as source, and the look-alike line landed where it was meant to.
        #expect(rogueAnswer.contains("so the source itself follows"))
        #expect(gizmoAnswer.contains("so the source itself follows"))
        #expect(rogueAnswer.contains("Sources/Alpha/Gizmo.swift — module: Alpha"))
        // The exact join every multi-answer path in `DigestRenderer` shares (`joinedAnswers`, private to that file): a blank
        // line, then the boundary mark `partMarker` on the next part's first character.
        let shared = "\(rogueAnswer)\n\n\(SourcePassthrough.partMarker)\(gizmoAnswer)"

        let verdict = SourcePassthrough.fileVerdict(in: shared, of: "Sources/Alpha/Gizmo.swift")

        #expect(verdict == SourcePassthrough.FileVerdict(path: "Sources/Alpha/Gizmo.swift", servedSource: true))
    }

    /// The same defence where the body's look-alike sits right after a blank line — the shape the real join leaves between parts — rather than mid-paragraph.
    ///
    /// A blank line alone is not what starts a part: `DigestRenderer.joinedAnswers` marks the boundary it actually writes, so a served body that happens to reproduce a blank line followed by a header-shaped line for a file this same answer goes on to name still credits nothing until that file's own real part.
    @Test
    func aBlankLineThenALookAlikeHeaderInABodyNeverCreditsTheFileBehindIt() throws {
        let rogueSource = "struct Rogue {\n    let marker = \"\"\"\n\nSources/Alpha/Gizmo.swift — module: Alpha\n\"\"\"\n}\n"
        let rogue = ("Sources/Alpha/Rogue.swift", rogueSource)
        let gizmo = ("Sources/Alpha/Gizmo.swift", "struct Gizmo {\n    let flag: Bool\n    let count: Int\n}\n")
        let rogueAnswer = try Self.render("Sources/Alpha/Rogue.swift", sources: [rogue, gizmo])
        let gizmoAnswer = try Self.render("Sources/Alpha/Gizmo.swift", sources: [rogue, gizmo])
        #expect(rogueAnswer.contains("\n\nSources/Alpha/Gizmo.swift — module: Alpha\n"))

        let shared = "\(rogueAnswer)\n\n\(SourcePassthrough.partMarker)\(gizmoAnswer)"
        let verdict = SourcePassthrough.fileVerdict(in: shared, of: "Sources/Alpha/Gizmo.swift")

        #expect(verdict == SourcePassthrough.FileVerdict(path: "Sources/Alpha/Gizmo.swift", servedSource: true))
    }

    /// `strippingPartMarker` removes only the marker that opens a part — never one a served body happens to contain mid-line, which passthrough exists to hand back untouched.
    @Test
    func strippingPartMarkerLeavesAMidLineMarkerInAServedBodyAlone() {
        let midLine = "struct Rogue {\n    let marker = \"\(SourcePassthrough.partMarker)\"\n}\n"
        let shared = "\(midLine)\n\n\(SourcePassthrough.partMarker)Sources/Alpha/Gizmo.swift — module: Alpha"

        let stripped = SourcePassthrough.strippingPartMarker(from: shared)

        #expect(stripped.contains(SourcePassthrough.partMarker))
        #expect(stripped == "\(midLine)\n\nSources/Alpha/Gizmo.swift — module: Alpha")
    }

    /// A type's digest decides nothing about its file, whichever way its own floor went.
    ///
    /// It weighs the type's extents, and a small type can sit in a large file — so its served source is no evidence that reading the whole file cost what the digest would have.
    @Test
    func aTypeDigestCarriesNoVerdictAboutItsFile() throws {
        let served = try Self.render("Tiny", sources: [Self.tinyType])
        let summarised = try Self.render("Substantial", sources: [Self.substantialType])

        #expect(served.contains("so the source itself follows"))
        #expect(SourcePassthrough.fileVerdict(in: served) == nil)
        #expect(SourcePassthrough.fileVerdict(in: summarised) == nil)
    }

    /// A digest of two declarations is a signature list, whatever ratio its own bytes produce.
    ///
    /// The case no arithmetic over the digest's bytes can catch: both the whole-file and the code-only ratios sit under break-even, so the digest would be kept and the caller would read the file — the `wholeDeclaration` row.
    @Test
    func aDigestOfTwoDeclarationsIsServedAsSourceHoweverWellItScores() throws {
        let output = try Self.render("Sources/Alpha/Degenerate.swift", sources: [Self.degenerateType])

        #expect(output.contains("so the source itself follows"))
        #expect(output.contains("let standardized = URL(fileURLWithPath: path).standardizedFileURL"))
        // The note says which comparison decided it: a reader checking the arithmetic against a ratio it
        // never used would find the tool's own number contradicting its explanation.
        #expect(output.contains("a digest of 2 declarations over 14 lines of code summarises little the source does not say"))
    }

    /// Two declarations are only degenerate while there is nothing under them.
    ///
    /// The count alone consults no arithmetic, so on its own it would serve every short declaration as source however well its digest scored — digests doing exactly the job the tool exists for included, some of them at a few percent of their source.
    @Test
    func twoDeclarationsOverRealCodeKeepTheDigest() throws {
        let answer = try Self.measure("Worked", sources: [Self.workedType])

        #expect(!answer.text.contains("so the source itself follows"))
        #expect(answer.text.contains("members:"))
        // The bodies are what the digest exists to leave out, and here there are bodies to leave out.
        #expect(!answer.text.contains("merged[trimmed] = running + value"))
        // Pinned as the arithmetic, not just the verdict: the floor is meant to fire where a digest saves
        // nothing, and this one saves four fifths of the answer.
        let bytes = try #require(answer.bytes)
        #expect(Double(bytes.answer) / Double(bytes.source) < 0.35)
    }

    /// Past the crossover the whole-source ratio governs alone, degenerate or not.
    ///
    /// Without the bound, a declaration holding fifteen lines of code under a hundred and thirty of prose would be served in full — the biggest single answer the floor could produce, to say what the digest already said.
    @Test
    func aDegenerateDeclarationPastTheCrossoverKeepsTheDigest() throws {
        let output = try Self.render("Sources/Alpha/DegenerateLong.swift", sources: [Self.degenerateLongType])

        #expect(!output.contains("so the source itself follows"))
        #expect(!output.contains("let standardized = URL(fileURLWithPath: path).standardizedFileURL"))
    }

    /// Doc prose lands wholly in the denominator, so a digest that shortens almost nothing reads as an excellent compression.
    ///
    /// The break-even ratio was measured over an app's types, which carry little of it. Judged against the code it summarised — the comparison the measurement was always a proxy for — this digest is most of it.
    @Test
    func aShortFileIsJudgedOnItsCodeRatherThanItsProse() throws {
        let output = try Self.render("Sources/Alpha/Documented.swift", sources: [Self.documentedType])

        #expect(output.contains("so the source itself follows"))
        #expect(output.contains("Documented(flag: flag || other.flag, count: count + other.count)"))
        #expect(output.contains("% of the code inside it"))
    }

    /// An enum names its cases on a line of their own, above the member budget — counting the budget alone would make a twenty-case enum a one-declaration digest.
    ///
    /// That is the one shape the degenerate floor must never fire on: listing the cases *is* the answer, and serving the bodies underneath them instead would throw away the compression the digest genuinely made.
    @Test
    func anEnumThatNamesItsCasesIsNotADegenerateDigest() throws {
        let cases = (0 ..< 20).map { "    case reticulatedOption\($0)" }.joined(separator: "\n")
        let body = (0 ..< 20).map { "        case .reticulatedOption\($0): return \($0) * multiplier + offset" }.joined(separator: "\n")
        let source = """
        enum Choice {
        \(cases)

            func weight(multiplier: Int, offset: Int) -> Int {
                switch self {
        \(body)
                }
            }
        }
        """
        let output = try Self.render("Choice", sources: [("Sources/Alpha/Choice.swift", source)])

        #expect(!output.contains("so the source itself follows"))
        #expect(output.contains("cases (20):"))
    }

    /// Both floors are bounded at the measured crossover, where a digest starts genuinely earning its keep.
    ///
    /// Same prose density, a longer declaration: judged on code alone this would pass through too, and serving a hundred-odd lines to save a summary is the failure the tool exists to prevent.
    @Test
    func aLongDeclarationKeepsItsDigestHoweverMuchProseItCarries() throws {
        let output = try Self.render("Sources/Alpha/DocumentedLong.swift", sources: [Self.documentedLongType])

        #expect(!output.contains("so the source itself follows"))
        #expect(output.contains("func evaluate0(input: String) -> Int"))
        #expect(!output.contains("let trimmed = input.trimmingCharacters"))
    }

    /// The code ceiling is a hard verdict, so its boundary is pinned rather than left to the fixtures that happen to straddle it.
    ///
    /// The other fixtures sit at 14/15 and 34/36 code lines — comfortably either side, and comfortable is exactly what an off-by-one survives. Same shape, one line apart, and only the ceiling separates them: both ratios sit well under break-even in each.
    @Test
    func theCodeCeilingIsInclusiveAtItsExactValue() throws {
        let atCeiling = try Self.render(
            "Sources/Alpha/Ceiling.swift",
            sources: [Self.ceilingFile(codeLines: SourcePassthrough.degenerateCodeCeiling)]
        )
        let overCeiling = try Self.render(
            "Sources/Alpha/Ceiling.swift",
            sources: [Self.ceilingFile(codeLines: SourcePassthrough.degenerateCodeCeiling + 1)]
        )

        #expect(atCeiling.contains("a digest of 2 declarations over 20 lines of code"))
        #expect(atCeiling.contains("so the source itself follows"))
        #expect(!overCeiling.contains("so the source itself follows"))
        // The body is what the digest exists to leave out, and its absence is the verdict rather than a
        // section heading a one-member file digest never prints.
        #expect(!overCeiling.contains("total += input.count"))
        #expect(overCeiling.contains("static func run(_ input: String) -> Int"))
    }

    /// A block comment that closes part-way along its line ends there, and the code after it is code.
    ///
    /// A line filter that only looks at a line's ends lets an opener that does not also *end* the line swallow everything until some later line happens to finish with `*/`. One `/* … */ var total = …` then takes this file's 21 code lines down to the 2 above it, which is not a moved ratio but a flipped verdict: under the ceiling the digest is served as source, and this file sits one line over it.
    @Test
    func aBlockCommentClosingMidLineDoesNotSwallowTheRestOfTheFile() throws {
        let (path, source) = Self.ceilingFile(codeLines: SourcePassthrough.degenerateCodeCeiling + 1)
        let poisoned = source.replacingOccurrences(
            of: "        var total = 0",
            with: "        /* legacy spelling, kept */ var total = 0"
        )

        let output = try Self.render("Sources/Alpha/Ceiling.swift", sources: [(path, poisoned)])

        #expect(!output.contains("so the source itself follows"))
        #expect(!output.contains("total += input.count"))
    }

    /// Counted directly, because the verdict above only shows whether the count is wrong and not by how much.
    @Test
    func theCodeScanFindsCodeOnBothSidesOfABlockComment() {
        let lines = [
            "/* legacy spelling, kept */ let opened = 1",
            "let plain = 2",
            "/* a comment that runs",
            "   across several lines */ let closed = 3",
            "let after = 4",
            "// an ordinary line comment",
            "let trailing = 5 // with a note after it",
        ]

        #expect(SourcePassthrough.code(in: lines) == [
            "/* legacy spelling, kept */ let opened = 1",
            "let plain = 2",
            "   across several lines */ let closed = 3",
            "let after = 4",
            "let trailing = 5 // with a note after it",
        ])
    }

    /// A comment delimiter inside a string literal is a character in a literal, not a comment.
    ///
    /// The direction matters more than the case: a spurious comment *under*-counts code, which serves source and excuses reads — the one direction the whole floor promises it rounds away from.
    @Test
    func aCommentDelimiterInsideAStringLiteralOpensNothing() {
        let lines = [
            #"let pattern = "/*""#,
            "let after = 1",
            #"let slashes = "// not a comment""#,
            #"let escaped = "a quote \" and then /* ""#,
            "let last = 2",
        ]

        #expect(SourcePassthrough.code(in: lines) == lines)
    }

    /// Swift's block comments nest, so the outer `*/` is the one that closes them.
    @Test
    func aNestedBlockCommentClosesAtItsOuterDelimiter() {
        let lines = [
            "/* outer /* inner */ still comment */",
            "let after = 1",
        ]

        #expect(SourcePassthrough.code(in: lines) == ["let after = 1"])
    }

    /// And it nests across lines too, which is where getting it wrong costs the remainder of the extent rather than one line.
    @Test
    func aNestedBlockCommentRunsUntilItsDepthReturnsToZero() {
        let lines = [
            "/* outer",
            "   /* inner",
            "   */ still comment",
            "   let notCode = 1",
            "*/ let after = 2",
            "let last = 3",
        ]

        #expect(SourcePassthrough.code(in: lines) == ["*/ let after = 2", "let last = 3"])
    }

    /// A file's trailing newline ends its last line rather than starting an empty one after it.
    ///
    /// Every other fixture here is a Swift multi-line literal, which carries none, so the correction that keeps a newline-terminated file off the wrong side of the crossover needs a fixture of its own to pin it. Written at the boundary, since one phantom line is exactly what it costs.
    @Test
    func aTrailingNewlineDoesNotPushAFileOverTheCrossover() {
        let atCeiling = Self.paddedSource(lines: SourcePassthrough.floorLineCeiling) + "\n"
        let overCeiling = Self.paddedSource(lines: SourcePassthrough.floorLineCeiling + 1) + "\n"

        #expect(SourcePassthrough.wouldServeSource(source: atCeiling))
        #expect(!SourcePassthrough.wouldServeSource(source: overCeiling))
    }

    @Test
    func aTypeIsJudgedOnAllItsSitesNotJustItsPrimaryDeclaration() throws {
        // A three-line declaration whose members all live in an extension: judging against the primary
        // declaration alone would call the digest wasteful and serve three lines that answer nothing.
        let primary = ("Sources/Alpha/Spread.swift", "protocol Spread {\n    var flag: Bool { get }\n}")
        let bodies = ("Sources/Alpha/Spread+Ext.swift", """
        extension Spread {
            func evaluate(input: String) -> Int {
                let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return 0
                }
                var total = 0
                for character in trimmed where character.isNumber {
                    total += Int(String(character)) ?? 0
                }
                return total
            }

            func describe(verbose: Bool) -> String {
                guard verbose else {
                    return "Spread"
                }
                return "Spread(flag: \\(flag))"
            }

            func merged(with other: [String]) -> [String] {
                var seen: Set<String> = []
                var result: [String] = []
                for entry in other {
                    let key = entry.lowercased()
                    guard !seen.contains(key) else {
                        continue
                    }
                    seen.insert(key)
                    result.append(entry)
                }
                return result.sorted()
            }

            func partitioned(_ entries: [Int]) -> (low: [Int], high: [Int]) {
                var low: [Int] = []
                var high: [Int] = []
                for entry in entries {
                    if entry < 0 {
                        low.append(entry)
                    } else {
                        high.append(entry)
                    }
                }
                return (low, high)
            }
        }
        """)

        let output = try Self.render("Spread", sources: [primary, bodies])

        // Judged against the primary declaration alone — three lines — this would serve source and answer
        // nothing. Counting the extension is what makes the digest the right call.
        #expect(!output.contains("so the source itself follows"))
        #expect(output.contains("extension Spread"))
        #expect(try Self.render("Spread", sources: [primary]).contains("so the source itself follows"))
    }

    /// A digest that was kept still carries what it was weighed against.
    ///
    /// This is the measurement the usage log reports as a saving, and the comparison happens either way — throwing it out after the decision would leave the tool able to say how often it was asked and never what an answer cost.
    @Test
    func aKeptDigestRecordsBothSidesOfTheComparison() throws {
        let answer = try Self.measure("Substantial", sources: [Self.substantialType])
        let bytes = try #require(answer.bytes)

        #expect(bytes.answer == answer.text.utf8.count)
        #expect(bytes.answer < bytes.source)
    }

    /// Source served in place of a digest is measured on what was actually served.
    ///
    /// Recording the digest's ratio here would report a saving on the one call that made none — and dropping the call entirely would leave the aggregate counting only the wins.
    @Test
    func passedThroughSourceIsMeasuredOnWhatItActuallyServed() throws {
        let answer = try Self.measure("Tiny", sources: [Self.tinyType])
        let bytes = try #require(answer.bytes)

        #expect(answer.text.contains("so the source itself follows"))
        #expect(bytes.answer == answer.text.utf8.count)
        #expect(bytes.source > 0)
    }

    /// A type too long to pass through is measured all the same.
    ///
    /// The ceiling decides what to serve, not what to count — and it fires on exactly the large types whose digests compress best, so stopping short of the arithmetic would have left the tool's biggest savings out of its own numbers.
    @Test
    func aTypeAboveTheLineCeilingIsStillMeasured() throws {
        let members = (0 ..< 260).map { "    let a\($0) = \($0)" }.joined(separator: "\n")
        let answer = try Self.measure("Sprawl", sources: [("Sources/Alpha/Sprawl.swift", "struct Sprawl {\n\(members)\n}")])
        let bytes = try #require(answer.bytes)

        #expect(!answer.text.contains("so the source itself follows"))
        #expect(bytes.answer == answer.text.utf8.count)
    }

    /// A comparison that could not be made records nothing rather than a partial one.
    @Test
    func anUnreadableSiteMeasuresNothingRatherThanHalfTheType() throws {
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let primary = try TestSources.parsed("struct Split {\n    let flag: Bool\n}", path: "Sources/Alpha/Split.swift", in: root)
        let extended = try TestSources.parsed("extension Split {\n    var negated: Bool { !flag }\n}", path: "Sources/Alpha/Split+Ext.swift", in: root)
        try store.replaceFiles([primary, extended]) { _ in ("Alpha", false) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Alpha/Split+Ext.swift"))
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)

        let answer = try renderer.measured(target: "Split", options: DigestOptions())

        #expect(answer.bytes == nil)
    }

    /// A page of a digest stands in for a page of nothing — it is not weighed, so it claims no saving.
    @Test
    func aPagedDigestMeasuresNothing() throws {
        let answer = try Self.measure("Substantial", sources: [Self.substantialType], options: DigestOptions(offset: 1))

        #expect(answer.bytes == nil)
    }

    /// A module listing and a repo overview replace no source, so neither reports a ratio against one.
    @Test
    func anAnswerThatStandsInForNoSourceMeasuresNothing() throws {
        #expect(try Self.measure("Alpha", sources: [Self.tinyType]).bytes == nil)
        #expect(try Self.measure(".", sources: [Self.tinyType]).bytes == nil)
    }

    /// A digest call answered with anything but a type's or a file's digest measures nothing: one member's source, the candidates for an ambiguous type or file name, and a miss.
    ///
    /// More than the savings figure rests on this. The `PreToolUse` hook takes a recorded measurement as its evidence that a digest call served a file's digest, so an answer that measured itself here would let a whole read through on the strength of a candidate list.
    @Test
    func anAnswerThatIsNoTypeOrFileDigestMeasuresNothing() throws {
        let twin = ("Sources/Beta/Substantial.swift", "enum Substantial {\n    case only\n}")
        let member = try Self.measure("Substantial.evaluate", sources: [Self.substantialType])
        let ambiguousType = try Self.measure("Substantial", sources: [Self.substantialType, twin])
        let ambiguousFile = try Self.measure("Substantial.swift", sources: [Self.substantialType, twin])
        let miss = try Self.measure("Absent", sources: [Self.substantialType])

        // Each answer checked for being the shape it stands for, so a nil below is never a miss standing in for one.
        #expect(member.text.contains("func evaluate(input: String) -> Int {"))
        #expect(ambiguousType.text.contains("Substantial is ambiguous"))
        #expect(ambiguousFile.text.contains("Substantial.swift is ambiguous"))
        #expect(!miss.text.contains("struct Substantial"))
        #expect(member.bytes == nil)
        #expect(ambiguousType.bytes == nil)
        #expect(ambiguousFile.bytes == nil)
        #expect(miss.bytes == nil)
    }
}

/// The source the decisions above are measured over.
///
/// Out of the suite's own body because they are the bulk of this file: the sizes here are the subject of every test, so a fixture runs to the length it has to be and the tests stay readable beside each other.
private extension SourcePassthroughTests {
    /// A type whose members are one-liners: the digest's per-member overhead exceeds the code itself.
    static let tinyType = ("Sources/Alpha/Tiny.swift", """
    struct Tiny {
        let flag: Bool
        let count: Int
    }
    """)

    /// A type with real bodies, where summarising is the whole point.
    static let substantialType = ("Sources/Alpha/Substantial.swift", """
    struct Substantial {
        let flag: Bool
        let count: Int

        func evaluate(input: String) -> Int {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return 0
            }
            var total = 0
            for character in trimmed where character.isNumber {
                total += Int(String(character)) ?? 0
            }
            return total * count
        }

        func describe(verbose: Bool) -> String {
            guard verbose else {
                return "Substantial(\\(count))"
            }
            var parts: [String] = []
            parts.append("count=\\(count)")
            parts.append("flag=\\(flag)")
            return parts.joined(separator: " ")
        }

        func combined(with other: Substantial) -> Substantial {
            let merged = count + other.count
            let either = flag || other.flag
            return Substantial(flag: either, count: merged)
        }
    }
    """)

    /// A real case, transcribed: a doc-heavy file whose whole digest is one type line and one signature.
    ///
    /// `CanonicalPath.swift` — 28 lines, one twelve-line function. Its digest reads as 18% of the file and 46% of the code inside it, so *both* ratios say "keep the digest" — and a caller reads the file anyway. What is actually wrong with it is that two declarations over fifteen lines of code summarise nothing, which no ratio over the digest's own bytes can see.
    static let degenerateType = ("Sources/Alpha/Degenerate.swift", """
    /// The one true spelling of a path, for the comparisons that decide which repository a query belongs to.
    ///
    /// Standardizing a path resolves `..`, `.` and a trailing slash but leaves its *case* alone, and macOS
    /// volumes are case-insensitive by default. So two spellings of one directory compare as two, which is
    /// not hypothetical: it was found with the session primer announcing an indexed repository as "not
    /// indexed yet", because the shell's cwd had arrived in a different case from the roots registry.
    ///
    /// Asked of the filesystem rather than lowercased, because case-insensitivity is a property of the
    /// volume and not of the platform: on a case-sensitive volume the two spellings really are two
    /// directories, and folding them together would be the same bug pointing the other way.
    struct Degenerate {
        /// The path as the filesystem spells it, or its standardized form when nothing is there to ask.
        ///
        /// The fallback matters more than the resolution: paths that do not exist are ordinary here — a
        /// pruned root, a fixture in a test, a repository on a volume that is not mounted — and they have
        /// to keep comparing equal to themselves rather than becoming unresolvable.
        static func canonical(_ path: String) -> String {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL
            let trimmed = standardized.path.count > 1 && standardized.path.hasSuffix("/")
                ? String(standardized.path.dropLast())
                : standardized.path
            guard let resolved = try? standardized.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath,
                  !resolved.isEmpty
            else {
                return trimmed
            }
            return resolved.count > 1 && resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
        }
    }
    """)

    /// Two declarations with a page of real work under them: the declaration count alone would call this degenerate.
    ///
    /// Transcribed from `HookOutput`, one of the types the count alone would make worse — two static functions, thirty-odd lines of code, a digest at a fifth of the source. That fifth is the compression the tool exists for, and counting declarations and stopping would throw it away.
    static let workedType = ("Sources/Alpha/Worked.swift", """
    struct Worked {
        /// Folds one reading into the running set.
        static func merge(_ existing: [String: Int], with incoming: [String: Int]) -> [String: Int] {
            var merged = existing
            for (key, value) in incoming {
                let trimmed = key.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else {
                    continue
                }
                if let running = merged[trimmed] {
                    merged[trimmed] = running + value
                } else {
                    merged[trimmed] = value
                }
            }
            return merged
        }

        /// The set as one line per key, widest count first.
        static func render(_ counts: [String: Int], limit: Int) -> String {
            let ordered = counts.sorted { left, right in
                left.value == right.value ? left.key < right.key : left.value > right.value
            }
            var lines: [String] = []
            for (key, value) in ordered.prefix(limit) {
                let padded = String(repeating: " ", count: max(0, 6 - String(value).count))
                lines.append("\\(padded)\\(value)  \\(key)")
            }
            if ordered.count > limit {
                lines.append("  … and \\(ordered.count - limit) more")
            }
            return lines.joined(separator: "\\n")
        }
    }
    """)

    /// Two declarations over almost no code, buried under a hundred and thirty lines of prose: past the crossover, the digest is worth its bytes again.
    ///
    /// The bound the degenerate floor is held inside. Serving this would hand back a hundred and fifty lines to say what five lines of digest already said, which is the failure the whole crossover exists to prevent.
    static let degenerateLongType = ("Sources/Alpha/DegenerateLong.swift", {
        let prose = (0 ..< 43).map { index in
            """
            /// Paragraph \(index) of the reasoning, at the length the doc comments in this codebase run to,
            /// which is what pushes a declaration holding almost no code past the crossover.
            ///
            """
        }.joined(separator: "\n")
        return """
        \(prose)/// The one true spelling of a path.
        struct DegenerateLong {
            static func canonical(_ path: String) -> String {
                let standardized = URL(fileURLWithPath: path).standardizedFileURL
                let trimmed = standardized.path.count > 1 && standardized.path.hasSuffix("/")
                    ? String(standardized.path.dropLast())
                    : standardized.path
                guard let resolved = try? standardized.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath,
                      !resolved.isEmpty
                else {
                    return trimmed
                }
                return resolved.count > 1 && resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
            }
        }
        """
    }())

    /// Two declarations over exactly `codeLines` lines of code, so the code ceiling is the only thing the verdict can turn on.
    ///
    /// Both byte ratios sit well under break-even at either size — the doc prose keeps the whole-source one down and the body lines are wide enough to keep the code-only one down — so a change of verdict between `codeLines` and `codeLines + 1` can only have come from the ceiling.
    static func ceilingFile(codeLines: Int) -> (String, String) {
        let body = (0 ..< (codeLines - 6))
            .map { "        total += input.count * \($0) + (input.hashValue % \($0 + 7))" }
            .joined(separator: "\n")
        return ("Sources/Alpha/Ceiling.swift", """
        /// A type standing over exactly the code the degenerate floor allows.
        ///
        /// Carrying the prose density this codebase runs to, so that the whole-source ratio is nowhere near
        /// break-even and the boundary under test is the only thing deciding.
        struct Ceiling {
            /// Folds the input into a running total, at the width real code runs to.
            static func run(_ input: String) -> Int {
                var total = 0
        \(body)
                return total
            }
        }
        """)
    }

    /// Exactly `lines` lines — a handful of code under enough comment padding to stay clear of the code ceiling — with no trailing newline of its own, so a caller can add one and pin what it does.
    static func paddedSource(lines: Int) -> String {
        let code = (0 ..< 5).map { "let value\($0) = \($0)" }
        let padding = (0 ..< (lines - code.count)).map { "// line \($0)" }
        return (padding + code).joined(separator: "\n")
    }

    /// Enough declarations that the digest is a real summary, and enough prose that the whole-file ratio cannot tell.
    ///
    /// Only the *first* line of each doc comment reaches the digest, so the paragraphs beneath them land wholly in the denominator and nowhere in the numerator — which is exactly how a digest that shortened almost no code comes to read as an excellent compression.
    static let documentedType = ("Sources/Alpha/Documented.swift", """
    /// A short type carrying far more prose than code.
    ///
    /// The norm in this codebase, and not the norm in the app the break-even ratio was measured over, which
    /// is the whole reason the ratio needed a second reading: every one of these lines is in the
    /// denominator and none of them is in the digest, so the digest scores on bytes it never had to spend.
    ///
    /// Stated again from the other side, since a second paragraph is the norm here too: the code beneath
    /// this is nine lines, the digest summarising it is five, and no reading of the whole file can see that.
    struct Documented {
        /// Whether to act on the reading.
        ///
        /// Set at the boundary and never afterwards, because a flag that can change under a reader is a
        /// flag nobody can quote, and every caller here quotes it into an answer it has already begun.
        let flag: Bool

        /// How many readings went in.
        ///
        /// The only guard against a single sample deciding, which is why it is stored rather than derived:
        /// a derived count is a count of whatever survived the last filter, not of what was measured.
        let count: Int

        /// The reading as a whole number.
        ///
        /// Rounded rather than truncated, so a half does not silently vanish on the way to a display that
        /// has no room for it — the direction of that error is always flattering, which is why it is fixed.
        var rounded: Int { Int(Double(count).rounded()) }

        /// The two combined.
        ///
        /// Takes the wider of the two flags, because a doubt anywhere in the pair is a doubt about the pair,
        /// and folding it away here would lose the one thing the flag exists to carry.
        func merged(with other: Documented) -> Documented {
            Documented(flag: flag || other.flag, count: count + other.count)
        }
    }
    """)

    /// Prose does not stop a long declaration being worth summarising: the same density, past the crossover.
    static let documentedLongType = ("Sources/Alpha/DocumentedLong.swift", {
        let members = (0 ..< 6).map { index in
            """
                /// What member \(index) is for, at the length the doc comments in this codebase run to, which is
                /// the whole reason the denominator swells: several lines of prose over a handful of code.
                ///
                /// Stated again from the other side, because a second paragraph is the norm here and one
                /// paragraph would understate how far the file leans towards prose.
                func evaluate\(index)(input: String) -> Int {
                    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        return \(index)
                    }
                    return trimmed.count + \(index)
                }
            """
        }.joined(separator: "\n\n")
        return "struct DocumentedLong {\n\(members)\n}"
    }())
}
