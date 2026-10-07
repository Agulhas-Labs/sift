//
// Copyright © Agulhas Labs
//

import Foundation

/// Serves source in place of a digest whose summary would cost as much as the code it summarises — the floor Docs/Design.md §3 puts under the compression.
///
/// A digest is a compression, and compression has a floor: the header, the signature line, the section labels and the per-member `file:line` ranges are a fixed cost that a small type cannot amortise. Measured over 132 types in an app, the digest is a *median 178% of the source* under 20 lines and 69% at 21–40, crossing under half at roughly 60. Measured over this repo's own files, it costs about a quarter between 60 and 100 lines and only roughly 15–20% above ~150 — nearer 13% for the largest files. Below the crossover the call is worse than useless: it spends tokens and the caller reads the file anyway.
///
/// So the renderer measures instead of assuming. Both sides of the comparison are already in hand at answer time — the rendered digest, and the source extents its rows point at — which makes this a decision rather than a heuristic, and keeps it correct if the digest format ever grows or shrinks.
///
/// Public only for what another module needs to draw the same line this one draws: `floorLineCeiling`, the source-alone half of the decision, and `fileVerdict` for reading the decision back out of an answer already given. Everything else here is internal.
public struct SourcePassthrough {
    /// Serve source once the digest reaches this fraction of it.
    ///
    /// At the crossover the two cost about the same and the source is strictly more informative, so the tie goes to source. Set from the measured distribution: it fires for the 40-and-under band almost always, about half the 41–60 band, and essentially never above 100 lines, where the digest earns its keep.
    static let breakEvenRatio = 0.5

    /// The most source this will ever serve, whatever the ratio says.
    ///
    /// A digest call must never turn into a whole-file dump — that is the failure the tool exists to prevent, and it would be a poor trade to fix over-summarising by under-summarising. Nothing in the measured sample came close: no type above 105 lines reached the break-even ratio at all, so this guards a pathological shape (hundreds of one-line members, where the member budget caps the digest while the source keeps growing) rather than a routine one.
    static let lineCeiling = 200

    /// The crossover the two floors below are bounded at — the length above which a digest starts genuinely earning its keep.
    ///
    /// Both floors widen the decision, and the regret is asymmetric: serving source wrongly costs about 2.5×, keeping a digest wrongly about 1.4×. Below 60 lines the digest was already *expected* to lose on the measured distribution (median 178% under 20 lines, 69% at 21–40, 48% at 41–60), so the floors only restore that expectation where something hid it, and the worst either can spend is one short file. Above it the whole-source ratio governs alone, undisturbed: a well-documented 150-line type keeps its digest, as the measurement says it should.
    ///
    /// The one place this number is written. `DigestFloor` draws the same line for the audit — from a path out of a transcript rather than from an index, so it approximates the rest of the decision — and reads the line itself from here, because two spellings of one crossover is a divergence that agrees until it doesn't.
    public static let floorLineCeiling = 60

    /// Below the crossover, a digest naming no more than this many declarations is a signature list rather than a summary.
    ///
    /// The ratio's blind spot. It scales with *digest* lines, so a declaration with almost nothing in it summarises almost nothing and still scores well: `digest CanonicalPath.swift` — 28 lines, one twelve-line function, a digest of one type line and one signature — reads as 18% of the file and 46% of the code inside it, and a caller given it reads the file anyway. Two declarations over fifteen lines of code is not a summary of anything, whatever the arithmetic says about it.
    ///
    /// Counted as declarations the digest *names*, which is why enum cases count: an enum listing twenty of them has told the caller what is in it, and its one member line must not read as degenerate.
    ///
    /// The one half of the degenerate floor a caller holding only the source cannot answer — see `standsOverLittleCode`, which is the other half and the shared one.
    static let degenerateDeclarationCeiling = 2

    /// And below the crossover, the most *code* two named declarations may stand over before the digest is taken to be summarising something after all.
    ///
    /// The declaration count alone is not enough, because two declarations can hold either almost nothing or a page of real work, and only the second is a summary worth its bytes. Without this pair, the floor would serve source for every short declaration whatever the arithmetic said — `HookOutput` (34 lines of code in two functions, a digest at 21% of its source), `RunAdvice.swift` (36 lines of code, a digest at **6%**) — which is the regret bound at :25 inverted: serving source wrongly is the expensive direction, and 6% is the ratio the tool exists to deliver.
    ///
    /// Twenty lines because that is the bottom of the measured distribution's worst band — the one where the digest ran a median 178% of the source — read against the *code* rather than the whole extent, since prose in the denominator is the blind spot this floor exists to cover. The cases above sit clear of it either way: `CanonicalPath.swift` is 15 lines of code, and the two dense files are 34 and 36.
    static let degenerateCodeCeiling = 20

    /// The whole of this decision that can be answered from the source alone, with no digest to weigh against it.
    ///
    /// `decide` below is the full predicate; this is the part of it that needs nothing but the file's bytes, and it exists so that `DigestFloor` — which has a path out of a transcript and an index it cannot consult — can ask the same question rather than a similar-looking one. Two spellings of one crossover agree until one of them is recalibrated, and a shared constant alone does not prevent that: a `DigestFloor` that read `floorLineCeiling` from here and then decided on line count alone would let the two files the code ceiling exists for (`HookOutput.swift` at 34 code lines, `RunAdvice.swift` at 36) keep their digests here and be excused as below-floor reads there — the share flattered by exactly the lookups the floor makes worth counting.
    ///
    /// What the caller loses by asking this instead of `decide`, in both directions, because an approximation that does not state its bias is a second predicate wearing the first one's name:
    ///
    /// - **The two byte ratios are not asked at all**, since neither exists without a rendered digest. A short file dense enough to fail the code ceiling and still lose on the ratio — `decide` serves it, this says no — is counted as a lookup that went around the index. That is the conservative direction, and the one every judgement in `DigestFloor` already rounds towards: a share whose whole worth is that it does not flatter.
    /// - **`degenerateDeclarationCeiling` is not asked either**, needing a parse this path cannot afford. That one errs the other way, and it is narrow: a digest naming three or more declarations over twenty lines of code is a digest big enough that the code ratio it would be judged on has usually already fired. The bounded case is a file that is both scant and finely divided, and the worst it costs is one short read excused.
    ///
    /// The first of those is not only *counted* conservatively, and that consequence is the one worth stating plainly: `ReadAdvice` gates its nudge on this same predicate, so a file the byte ratios would have passed through is a file the caller is interrupted over and sent to a digest that then serves the source anyway — the read paid for twice rather than merely recorded twice. The band where the two predicates can differ at all is real and not a corner (at most 60 lines with more than 20 of them code: 60 files in this repo), though most of it is the code ceiling working — that is also the band where a short dense file would otherwise be excused as a free read. Recorded rather than closed, because closing it means the nudge rendering a digest to decide whether to suggest one, on a hook that fires per tool call.
    static func standsOverLittleCode(totalLines: Int, codeLines: Int) -> Bool {
        totalLines <= floorLineCeiling && codeLines <= degenerateCodeCeiling
    }

    /// Whether a digest of this whole file would have been served as the file's own source, judged from the source alone.
    ///
    /// The entry point `standsOverLittleCode` exists for, splitting the source exactly as the whole-file `decide` splits it so the two cannot disagree about what a line is.
    ///
    /// It inherits the misses stated there, and one band widens the first of them: **a test suite of roughly 60 to 200 lines**. Its digest carries each helper's own source beneath its signature (`SuiteAnnotation`), which can lift the byte ratio past `breakEvenRatio`, so `decide` serves such a suite as source while this — asking no ratio, and above `floorLineCeiling` — says its digest is kept. The direction is the same conservative one: a whole read of that suite is counted as having gone around the index, and `ReadAdvice` sends the caller to a digest that serves the source anyway.
    public static func wouldServeSource(source: String) -> Bool {
        let lines = lines(of: source)
        return standsOverLittleCode(totalLines: lines.count, codeLines: code(in: lines).count)
    }

    /// The same question asked of a Markdown document: whether an outline of it would have been served as the document's own text.
    ///
    /// One predicate, read in the subject's own units — a document has no code for the comment-and-string scan to find, so what the floor is measured against is its non-blank lines (``Subject/markdown``), exactly as the whole-document `decide` measures it. The misses above hold here too and in the same direction: the two byte ratios need a rendered outline, so a short document dense enough to clear the content ceiling and still lose on the ratio is judged not below the floor, which is the conservative reading of "did this read cost anything".
    ///
    /// The heading count `degenerateDeclarationCeiling` would ask is the one miss that errs the other way, and it is narrower here than for source: a document of under sixty lines carrying three or more headings over twenty-odd non-blank lines is a table of contents that locates something, and the worst the omission costs is one short document read without a nudge.
    public static func wouldServeDocument(source: String) -> Bool {
        let lines = lines(of: source)
        return standsOverLittleCode(totalLines: lines.count, codeLines: Subject.markdown.content(in: lines).count)
    }

    /// A file's source as lines, with a trailing newline read as ending the last line rather than starting another.
    static func lines(of source: String) -> [String] {
        var lines = source.components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    /// Whether to serve source instead of `digest`, and what the comparison measured.
    ///
    /// `sites` are the declaration extents the digest drew on — the primary declaration and every extension — because that, not the enclosing file, is the source the caller would otherwise have to read. Judging against the file instead would misread a small type sharing a large file, and a three-line protocol whose members all live in extensions elsewhere.
    ///
    /// `named` is how many declarations the digest actually spells out, which the digest's byte count cannot stand in for: it grows with digest lines, so a declaration holding almost nothing summarises almost nothing and still scores well.
    static func decide(
        insteadOf digest: String,
        header: String,
        named: Int,
        sites: [SymbolRow],
        read: (_ path: String) -> String?,
        preamble: [String]
    ) -> Decision {
        guard !sites.isEmpty else { return .unmeasured }

        var extents: [Extent] = []
        for row in sites {
            // An unreadable or empty extent means the comparison cannot be made honestly — one missing
            // site would understate the source and pass through something incomplete. Keep the digest,
            // and record nothing: a half-read type is a missing measurement, not a small one.
            guard case let .lines(lines, _) = SourceSlicer.slice(of: row, in: read(row.path)) else {
                return .unmeasured
            }
            extents.append(Extent(label: "\(row.path)\(row.rangeDescription)", lines: lines))
        }
        return decide(insteadOf: digest, header: header, named: named, extents: extents, preamble: preamble)
    }

    /// The whole-file variant, for a `digest <path>` whose summary costs as much as the file.
    ///
    /// `subject` names what is being weighed, so the note's arithmetic is stated in that subject's own units: a Markdown outline is judged over the document's non-blank lines, never over "lines of code" a scanner written for Swift would find in prose.
    static func decide(
        insteadOf digest: String,
        header: String,
        named: Int,
        filePath: String,
        read: (_ path: String) -> String?,
        preamble: [String],
        subject: Subject = .swift
    ) -> Decision {
        guard let source = read(filePath) else {
            return .unmeasured
        }
        let extent = Extent(label: filePath, lines: lines(of: source))
        return decide(insteadOf: digest, header: header, named: named, extents: [extent], preamble: preamble, subject: subject)
    }

    private static func decide(
        insteadOf digest: String,
        header: String,
        named: Int,
        extents: [Extent],
        preamble: [String],
        subject: Subject = .swift
    ) -> Decision {
        // Counted before the ceiling, not after: a type too long to pass through is exactly the type whose
        // digest compresses best, and stopping short of the arithmetic would leave the biggest savings the
        // tool makes unrecorded while the marginal ones were reported.
        let sourceBytes = extents.reduce(0) { $0 + $1.lines.joined(separator: "\n").utf8.count }
        guard sourceBytes > 0 else { return .unmeasured }
        let ratio = Double(digest.utf8.count) / Double(sourceBytes)

        let totalLines = extents.reduce(0) { $0 + $1.lines.count }
        let keepingDigest = Decision(
            source: nil,
            bytes: MeasuredAnswer.Bytes(answer: digest.utf8.count, source: sourceBytes)
        )
        // Two floors below the crossover, each answering a different way the whole-source ratio misreads a
        // short declaration. The prose one re-runs the same arithmetic against the code alone, because the
        // measured distribution came from types that carry little of it; the degenerate one asks a different
        // question — whether a digest naming two declarations over almost no code summarised anything at all.
        let codeExtents = extents.map { subject.content(in: $0.lines) }
        let codeBytes = codeExtents.reduce(0) { $0 + $1.joined(separator: "\n").utf8.count }
        let codeLines = codeExtents.reduce(0) { $0 + $1.count }
        let codeRatio = codeBytes > 0 ? Double(digest.utf8.count) / Double(codeBytes) : 0
        let underCrossover = totalLines <= floorLineCeiling
        let prose = underCrossover && codeRatio >= breakEvenRatio
        // Through the shared predicate rather than restated, because `DigestFloor` asks this same question
        // from a transcript and the two must move together — a scan counting a read as a miss that a
        // digest would have served as source is the exact misreading that floor exists to stop.
        let degenerate = named <= degenerateDeclarationCeiling
            && standsOverLittleCode(totalLines: totalLines, codeLines: codeLines)
        guard totalLines <= lineCeiling, ratio >= breakEvenRatio || prose || degenerate else { return keepingDigest }

        // The caller asked for a digest and is getting source, so the answer says so and shows the
        // arithmetic that decided it — including *which* comparison did, since 18% of a file and 46% of the
        // code inside it are the same digest and a reader checking the number must not have to guess which.
        var lines = preamble
        lines.append(header)
        lines.append(note(totalLines: totalLines, siteCount: extents.count, reason: {
            if ratio >= breakEvenRatio {
                return "\(subject.summary) would cost \(percentage(ratio)) of the \(subject.whole)"
            }
            if prose {
                return "\(subject.summary) would cost \(percentage(codeRatio)) of the \(subject.inside)"
            }
            let declarations = "\(named) \(subject.unit)\(named == 1 ? "" : "s")"
            let span = subject.contentLines(codeLines)
            return "\(subject.summary) of \(declarations) over \(span) summarises little the \(subject.whole) does not say"
        }()))
        for extent in extents {
            lines.append("")
            if extents.count > 1 {
                lines.append("// \(extent.label)")
            }
            lines.append(contentsOf: extent.lines)
        }
        let served = lines.joined(separator: "\n")
        // Measured on what is actually served, so a passed-through answer reports the ~100% it cost rather
        // than the digest's ratio it never charged for. Leaving these out would report only the calls where
        // the tool won, which is how a savings number stops being a measurement.
        return Decision(
            source: served,
            bytes: MeasuredAnswer.Bytes(answer: served.utf8.count, source: sourceBytes)
        )
    }

    private static func note(totalLines: Int, siteCount: Int, reason: String) -> String {
        let counted = "\(totalLines) line\(totalLines == 1 ? "" : "s")"
        let span = siteCount == 1 ? counted : "\(counted) across \(siteCount) sites"
        return "(\(span); \(reason)\(servedSourceSuffix)"
    }

    private static func percentage(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    /// The lines that are code — everything a comment or a blank line is not.
    ///
    /// Not a lexer, but it carries the two pieces of state a size question actually turns on, because reading delimiters alone breaks the bias this whole file rounds one way. **A delimiter inside a string literal opens a comment that is not there**: `let pattern = "/*"` would discard the rest of the extent, under-counting code — which serves source and excuses reads, the flattering direction :25 and :52 both promise everything here rounds away from. And **Swift's block comments nest**: `/* outer /* inner */ still comment */` closes at the outer `*/`, so a single inside-or-not flag would read the tail of that line as code. So the scan tracks whether the cursor sits in a string literal (toggling on an unescaped `"`, where a `//`, `/*` or `*/` is inert) and how deep it sits in block comments, ending the comment when the depth returns to zero — Swift's own rule.
    ///
    /// What genuinely remains, each bounded to the line it appears on, because string state is rebuilt per line while only the comment depth carries across:
    ///
    /// - **A multi-line string literal's body reads as code.** `"""` opens, closes and opens again on one line, and the next line starts fresh — so the body counts, which is the conservative direction, except for any line inside it spelling a delimiter, which is not.
    /// - **A raw literal is an ordinary literal to this scan.** `#"…"#` opens and closes on its quotes, and a backslash inside it is read as an escape it is not.
    ///
    /// Neither is worth a Swift parse run to answer a size question the parser was not asked, and neither can run past the end of its line.
    ///
    /// It is not a *line* filter either, and that distinction is load-bearing. A line filter leaves the scanner inside a block comment that closes part-way along its line until some line happens to end in `*/`, which discards the rest of the file: `/* legacy spelling, kept */ let x = …` takes a 27-line count down to 1. Being wrong about the delimiters is a ratio moved by bytes, but being wrong about where the comment *ends* is the whole remainder of the extent, and it decides a hard verdict — `codeLines <= degenerateCodeCeiling` — so it is a 2.5× wrong passthrough rather than a rounding error.
    ///
    /// Blank lines go with the comments. They are layout, not content, and leaving them in the denominator would hand a prose-heavy file back the padding this exists to discount.
    static func code(in lines: [String]) -> [String] {
        var blockDepth = 0
        return lines.filter { hasCode($0, blockDepth: &blockDepth) }
    }

    /// Whether `line` carries anything outside a comment, advancing the block-comment nesting depth across it.
    ///
    /// Scans the line rather than testing its ends, so a comment that opens and closes inside one line leaves the scanner where it found it, and code on either side of it counts. String state is deliberately *not* carried across, since a plain literal cannot span a line; the depth is, since a block comment can.
    private static func hasCode(_ line: String, blockDepth: inout Int) -> Bool {
        var sawCode = false
        var insideString = false
        var escaped = false
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if blockDepth > 0 {
                index += advanceThroughComment(character, next, depth: &blockDepth)
                continue
            }
            if insideString {
                advanceThroughString(character, insideString: &insideString, escaped: &escaped)
                index += 1
                continue
            }
            if character == "\"" {
                insideString = true
                sawCode = true
            } else if character == "/", next == "/" {
                // The rest of the line is a comment, so nothing after it can change the answer.
                return sawCode
            } else if character == "/", next == "*" {
                blockDepth += 1
                index += 2
                continue
            } else {
                sawCode = sawCode || !character.isWhitespace
            }
            index += 1
        }
        return sawCode
    }

    /// How far to step, having consumed any nesting delimiter at the cursor.
    private static func advanceThroughComment(_ character: Character, _ next: Character?, depth: inout Int) -> Int {
        if character == "/", next == "*" {
            depth += 1
            return 2
        }
        if character == "*", next == "/" {
            depth -= 1
            return 2
        }
        return 1
    }

    /// One character of a string literal's interior, closing it on an unescaped quote.
    private static func advanceThroughString(_ character: Character, insideString: inout Bool, escaped: inout Bool) {
        if escaped {
            escaped = false
        } else if character == "\\" {
            escaped = true
        } else if character == "\"" {
            insideString = false
        }
    }
}

extension SourcePassthrough {
    /// What a passthrough weighs a summary against, which decides the words its arithmetic is stated in.
    ///
    /// The suffix the note ends in is the same for both, because ``fileVerdict(in:)`` recognises a served-source line by it and a document served whole is one.
    enum Subject {
        /// Swift source: declarations over lines of code, the code found by the comment-and-string scan.
        case swift
        /// A Markdown document: headings over non-blank lines, since prose has no code for that scan to find and a `/*` inside it would open a comment that never closes.
        case markdown

        /// The lines the summary is judged against once layout is discounted.
        func content(in lines: [String]) -> [String] {
            switch self {
            case .swift: SourcePassthrough.code(in: lines)
            case .markdown: lines.filter { !$0.allSatisfy(\.isWhitespace) }
            }
        }

        var summary: String {
            self == .swift ? "a digest" : "an outline"
        }

        var unit: String {
            self == .swift ? "declaration" : "heading"
        }

        func contentLines(_ count: Int) -> String {
            let lines = "\(count) line\(count == 1 ? "" : "s")"
            return self == .swift ? "\(lines) of code" : "\(count) non-blank line\(count == 1 ? "" : "s")"
        }

        var whole: String {
            self == .swift ? "source" : "document"
        }

        var inside: String {
            self == .swift ? "code inside it" : "text inside it"
        }
    }
}

public extension SourcePassthrough {
    /// How the note announcing served source ends, which is what a reader of a finished answer recognises it by.
    ///
    /// Written once and read by both ends — the note above and ``fileVerdict(in:)`` — so the sentence and the thing that recognises it cannot drift apart.
    static var servedSourceSuffix: String {
        ", so the source itself follows)"
    }

    /// What a whole-file digest answer decided about its file: which file, and whether its source was served in place of a summary.
    struct FileVerdict: Sendable, Equatable {
        /// The file as the answer named it: relative to the repository the digest ran in.
        public let path: String
        /// Whether the answer was the file's own source — the floor decided in the file's favour.
        public let servedSource: Bool

        public init(path: String, servedSource: Bool) {
            self.path = path
            self.servedSource = servedSource
        }
    }

    /// The verdict a rendered whole-file digest carries, read back out of its text; `nil` for any other answer.
    ///
    /// **Only a whole-file digest decides the floor for a file.** A type's digest weighs the type's own extents, and a small type can sit in a large file, so its note says nothing about what reading the whole file costs — taking one as a verdict on the file would excuse a whole read of the large file, which raises the share. A member, a module and the repo overview weigh no file at all.
    ///
    /// The header is the first line shaped like one, near the top: what stands above it — a freshness line, a notice, a note about which root answered — has taken several shapes across versions, and a verdict read off an old transcript has to survive all of them. The search stops well short of any body, which is the only place a line of that shape could otherwise turn up.
    ///
    /// A digest that was paged or asked for signatures only never weighs its source, so its answer is a summary that decided nothing; the caller has the arguments and must set those aside itself.
    static func fileVerdict(in answer: String) -> FileVerdict? {
        let lines = Array(answer.split(separator: "\n", omittingEmptySubsequences: false).prefix(headerSearchDepth + 1))
        for (index, line) in lines.enumerated().prefix(headerSearchDepth) {
            guard let match = line.wholeMatch(of: fileHeader) else { continue }
            let next = index + 1 < lines.count ? lines[index + 1] : ""
            return FileVerdict(
                path: String(match.output.1),
                servedSource: next.hasPrefix("(") && next.hasSuffix(servedSourceSuffix)
            )
        }
        return nil
    }

    /// The verdict for one named file inside an answer that shares several whole-file digests under one header, or `nil` where that file's own header does not appear.
    ///
    /// The single-file reading above stops at ``headerSearchDepth`` because a header past it is read as body text of the file before it; a shared answer's second file and every one after it sit past that depth, so this reads the whole answer instead and matches the header naming `path` rather than the first one found — a specific miss where the general search above finds only the top file's verdict for every file behind it. A blank line alone is not proof a part starts there — a served-raw body can spell one itself, right before a line that happens to be shaped like another file's header — so a candidate only counts on the line the first part opens on (``firstPartLine(of:)``), or directly after a blank line that also carries ``partMarker``: the one mark `DigestRenderer.joinedAnswers` writes on the first character of every part after the first, which a served body's own text is never mistaken for.
    static func fileVerdict(in answer: String, of path: String) -> FileVerdict? {
        let lines = Array(answer.split(separator: "\n", omittingEmptySubsequences: false))
        let opening = firstPartLine(of: lines)
        for (index, rawLine) in lines.enumerated() {
            let marked = rawLine.first == partMarker
            guard index == opening || (index > 0 && lines[index - 1].isEmpty && marked) else { continue }
            let line = marked ? rawLine.dropFirst() : rawLine
            guard let match = line.wholeMatch(of: fileHeader), match.output.1 == path else { continue }
            let next = index + 1 < lines.count ? lines[index + 1] : ""
            return FileVerdict(
                path: String(match.output.1),
                servedSource: next.hasPrefix("(") && next.hasSuffix(servedSourceSuffix)
            )
        }
        return nil
    }
}

extension SourcePassthrough {
    /// How many lines from the top of an answer its header can sit, past every notice a version has put above it.
    static let headerSearchDepth = 12

    /// The line an answer's first part opens on: past the freshness line the hook's in-place answer leads with, past the in-memory note a tree that cannot be written adds under it, and past the guessed-module banner and the blank line under it that such an answer can carry above its parts.
    ///
    /// The two shapes `InPlaceAnswerer` writes above a body — its freshness header, then `CompoundAnswerBody` or the file's own digest with any banner — and no others, so a line past them is never taken for the top of an answer. An answer with neither, as an index call's own answer is read here, opens its first part on line 0.
    static func firstPartLine(of lines: [Substring]) -> Int {
        var index = lines.first?.hasPrefix(WorkingTree.fieldOpening) == true ? 1 : 0
        if index < lines.count, lines[index].hasPrefix(SiftEngine.inMemoryIndexNoteOpening) {
            index += 1
        }
        if index + 1 < lines.count, lines[index].hasPrefix(GuessedModuleNotice.bannerOpening), lines[index + 1].isEmpty {
            index += 2
        }
        return index
    }

    /// The character `DigestRenderer.joinedAnswers` writes as the first character of every part after the first — invisible once rendered, and not a character real Swift source or a served body's own text would ever open a line with on its own, so ``fileVerdict(in:of:)`` can tell the boundary the join actually made from a blank line and header-shaped line a served body merely happens to contain.
    public static var partMarker: Character {
        "\u{2063}"
    }

    /// `answer` with the ``partMarker`` that opens a part removed — at index 0, or right after the `\n\n` separator ``DigestRenderer/joinedAnswers(_:)`` writes before it — and every other occurrence left alone.
    ///
    /// For the one reader that has no use for the boundary it marks and would otherwise print its raw bytes: a terminal. The hook's transcript scan is not that reader, and keeps the marker. Filtering out every occurrence, as this once did, took a marker character out of source a digest serves verbatim too, wherever a served body happened to contain one — silently corrupting exactly the bytes passthrough exists to hand back untouched.
    public static func strippingPartMarker(from answer: String) -> String {
        var stripped = answer
        if stripped.first == partMarker {
            stripped.removeFirst()
        }
        let boundary = "\n\n\(partMarker)"
        return stripped.replacingOccurrences(of: boundary, with: "\n\n")
    }

    /// A whole-file digest's header, `<path>.swift — module: <module>`, capturing the path.
    ///
    /// The shape `DigestRenderer` writes for a file digest; the two are pinned together by a test that reads a rendered answer back through ``fileVerdict(in:)``.
    static var fileHeader: Regex<(Substring, Substring)> {
        /^(\S.*\.swift) — module: \S+$/
    }

    /// One contiguous run of source under consideration, and the label it is announced with when there are several.
    struct Extent {
        let label: String
        let lines: [String]
    }

    /// What the comparison decided, and what it measured on the way.
    ///
    /// The two are independent: a digest that is kept was still weighed against real source, and that weighing is the saving worth recording. Only a comparison that could not be made at all — an unreadable site, a file that isn't there — leaves `bytes` empty.
    struct Decision {
        /// The source to serve instead of the digest, or `nil` to keep the digest.
        let source: String?

        /// Both sides of the comparison, or `nil` when it could not be made.
        let bytes: MeasuredAnswer.Bytes?

        /// Nothing served, nothing counted.
        static let unmeasured = Decision(source: nil, bytes: nil)

        /// This decision as the answer it produces, given the digest it was weighed against.
        func answer(keeping digest: String) -> MeasuredAnswer {
            MeasuredAnswer(text: source ?? digest, bytes: bytes)
        }
    }
}
