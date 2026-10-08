//
// Copyright © Agulhas Labs
//

import Foundation

/// The answers the advice hook may give in place of a refusal, and what each one accounts for — the lines of a file it serves or numbers — so that an answer is given only where it accounts for everything the command would have printed.
///
/// A refusal names a call and costs a round trip; an answer given in its place costs none, but only earns that where it answers the question the command put. So every miss that an ordinary call would answer in words — a candidate list, "no symbol named", a file the index does not hold, a member that resolves to some other declaration — comes back here as `nil`, and the hook refuses as it always has. What a found answer accounts for is read out of the text it serves, never out of what it was asked: a member collapsed into a summary, a listing cut short, a body truncated or a site matched on its name alone accounts for no line.
public struct ExactAnswer {
    /// The file at `path`, spelled out in full, as the index holds it — its path relative to `engine`'s repository, spelled as named — or `nil` where nothing is there, it is not a regular file, or the index holds no file at exactly that path.
    ///
    /// The directory is compared canonically, so a checkout reached through a symlinked parent still places; the file's own name is not resolved, so a link to a file elsewhere is not taken for that file.
    public static func indexedFile(atPath path: String, in engine: SiftEngine) throws -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular
        else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        let directory = CanonicalPath.of(url.deletingLastPathComponent().path)
        let root = CanonicalPath.of(engine.repoRoot.path)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let relative: String
        if directory == root {
            relative = url.lastPathComponent
        } else {
            guard directory.hasPrefix(prefix) else { return nil }
            relative = String(directory.dropFirst(prefix.count)) + "/" + url.lastPathComponent
        }
        return try engine.store.fileRow(path: relative) == nil ? nil : relative
    }

    /// Whether the file at `path` — repository-relative, as ``indexedFile(atPath:in:)`` returns it — was indexed with a parse error, so its digest is what a broken parse produced rather than the file.
    public static func hasParseErrors(in engine: SiftEngine, path: String) throws -> Bool {
        try (engine.store.fileRow(path: path)?.parseErrorCount ?? 0) > 0
    }

    /// The digest options a caller reading in `spelling` asks with, paged at `pageSize` member lines where it names one and at the page every face serves otherwise.
    private static func options(spelling: CallSpelling, pageSize: Int?) -> DigestOptions {
        var options = DigestOptions(spelling: spelling)
        if let pageSize {
            options.pageSize = pageSize
        }
        return options
    }

    /// Whether the first page of the digest of the file at `path` lists every member `ranges` reach — a page that stops short of them accounts for none of their lines — or `false` where the index holds no file there.
    ///
    /// `pageSize` is the member lines a page holds where it is not the one every face serves.
    public static func firstDigestPageReaches(_ ranges: [ClosedRange<Int>], in engine: SiftEngine, path: String, spelling: CallSpelling, pageSize: Int? = nil) throws -> Bool {
        try WindowMembersAnswer(renderer: engine.makeDigestRenderer()).firstPageReaches(ranges, inFile: path, options: options(spelling: spelling, pageSize: pageSize))
    }

    /// Whether the digest of the file at `path` gives every member `ranges` overlap a line of its own, with its line range — a nested type's members, named on their type's line alone, it places nowhere — or `false` where the index holds no file there.
    public static func digestPlacesEveryMember(_ ranges: [ClosedRange<Int>], in engine: SiftEngine, path: String, spelling: CallSpelling) throws -> Bool {
        try WindowMembersAnswer(renderer: engine.makeDigestRenderer()).placesEveryMember(ranges, inFile: path, options: DigestOptions(spelling: spelling))
    }

    /// The digest of the file at `path` — repository-relative, as ``indexedFile(atPath:in:)`` returns it — or `nil` unless it resolved to exactly that file.
    ///
    /// A resolved file digest is the one digest answer that weighs itself against its source, so a miss, a candidate list and a passthrough of nothing carry no measurement; and a digest resolves a bare file name to a file of that name anywhere in the tree, so the file its header names has to be the one asked for. `spelling` is the face whose caller reads the answer, for the paging cursor a long digest ends with, and `pageSize` the member lines a page holds where it is not the one every face serves.
    public static func fileDigest(in engine: SiftEngine, path: String, spelling: CallSpelling = .commandLine, pageSize: Int? = nil) throws -> MeasuredAnswer? {
        let answer = try engine.measuredDigest(target: path, options: options(spelling: spelling, pageSize: pageSize))
        guard answer.bytes != nil, SourcePassthrough.fileVerdict(in: answer.text)?.path == path else { return nil }
        return answer
    }

    /// The heading outline of the Markdown document at `path` — repository-relative — or `nil` where there is no document there to outline, or none it stands in for.
    ///
    /// Not an exactness proof and not offered as one: nothing about a `.md` file is indexed, so there is nothing stored to weigh the answer against. What this rules out is an answer about something else — a target the renderer missed, and one it could neither read nor weigh — *and* an answer that does not stand in for the read: no heading to locate by, or a text no smaller than the document itself. The rule for every doubt is that the read runs, so a document with nothing to show for the round trip is left to it. `DigestRenderer.renderMarkdown` is what renders it, live from disk, and its answer carries both sides of the measurement: the document's bytes against the outline's, in the kept-outline and the passthrough case alike.
    public static func documentOutline(in engine: SiftEngine, path: String) throws -> MeasuredAnswer? {
        let answer = try engine.measuredDigest(target: path, options: DigestOptions())
        guard !answer.missed, let bytes = answer.bytes, answer.text.utf8.count < bytes.source else { return nil }
        guard let source = try? String(contentsOf: engine.repoRoot.appendingPathComponent(path), encoding: .utf8) else { return nil }
        guard !MarkdownOutline.sections(of: SourcePassthrough.lines(of: source)).isEmpty else { return nil }
        return answer
    }

    /// The lines of `file` a digest of it accounts for by their own number: the first line of every declaration it lists with a range, and — where it serves the file's source instead — every line it serves verbatim.
    ///
    /// A declaration's first line is the one its range opens on, which is where an attribute on a line of its own stands rather than the keyword; a member listed inside a collapsed type, or past a truncation, carries no number and accounts for nothing.
    public static func linesLocated(byDigest text: String, of file: String, source: [String], in engine: SiftEngine) throws -> Set<Int> {
        if SourcePassthrough.fileVerdict(in: text)?.servedSource == true {
            return servesVerbatim(source[...], in: text) ? Set(source.indices.map { $0 + 1 }) : []
        }
        let starts = try Set(engine.store.symbols(inFile: file).map(\.line))
        var located = Set<Int>()
        for line in text.split(separator: "\n") {
            if let match = line.firstMatch(of: rangeToken), let start = Int(match.output.1), starts.contains(start) {
                located.insert(start)
            }
        }
        return located
    }

    /// The lines of `file` a digest of it accounts for as its declarations' own lines: every line `linesLocated` locates, and for each declaration whose entry shows its source from its first line through its name, the line its name stands on and every line of that span starting with `@`.
    ///
    /// A declaration grep for its keyword or its attribute prints those lines — `@Test` on one line and `func` on the next — and a digest entry opening on the attribute's line stands for both, but only while it shows them. An entry cut short, as a long attribute's arguments cut it, shows neither the name nor an attribute past the cut, nor a line starting with `@` inside a string among those arguments, and that declaration accounts for its first line alone. A modifier on a line of its own is no line the digest shows, and accounts for nothing.
    public static func declarationLinesLocated(byDigest text: String, of file: String, source: [String], in engine: SiftEngine) throws -> Set<Int> {
        let located = try linesLocated(byDigest: text, of: file, source: source, in: engine)
        guard SourcePassthrough.fileVerdict(in: text)?.servedSource != true else { return located }
        var entries: [Int: [String]] = [:]
        for line in text.split(separator: "\n") {
            if let match = line.firstMatch(of: rangeToken), let start = Int(match.output.1) {
                entries[start, default: []].append(String(line[..<match.range.lowerBound].filter { !$0.isWhitespace }))
            }
        }
        var lines = located
        for row in try engine.store.symbols(inFile: file) where located.contains(row.line) {
            let span = declarationSpan(of: row, in: source)
            guard let head = shownHead(of: row, span: span, in: source),
                  entries[row.line, default: []].contains(where: { $0.contains(head) })
            else { continue }
            lines.insert(span.upperBound)
            lines.formUnion(span.filter { source[$0 - 1].trimmingCharacters(in: .whitespaces).hasPrefix("@") })
        }
        return lines
    }

    /// Every line of `file` that opens on a closing brace, where a digest of it accounts for each by number as the end of a top-level declaration's range, or `nil` where it cannot account for them all.
    ///
    /// A line qualifies only as a lone `}` that is the last line of a declaration with no parent, whose range the digest shows as `:a-b`: the answer to a `^}` grep is that range's end, and a closure closed at column 0, a brace inside a multi-line string, a nested declaration's end written flush left, or a range the digest truncated away is a line it never names — so any one of them withholds the lot. Where the digest serves the file's source instead, every line stands in it verbatim.
    public static func closersLocated(byDigest text: String, of file: String, source: [String], in engine: SiftEngine) throws -> Set<Int>? {
        let closers = Set(source.indices.filter { source[$0].hasPrefix("}") }.map { $0 + 1 })
        if SourcePassthrough.fileVerdict(in: text)?.servedSource == true {
            return servesVerbatim(source[...], in: text) ? closers : nil
        }
        let topLevel = try Set(engine.store.symbols(inFile: file).filter { $0.parentID == nil }.map { "\($0.line)-\($0.endLine)" })
        var ends = Set<Int>()
        for line in text.split(separator: "\n") {
            if let match = line.firstMatch(of: rangeSpan), topLevel.contains("\(match.output.1)-\(match.output.2)"), let end = Int(match.output.2) {
                ends.insert(end)
            }
        }
        guard closers.allSatisfy({ ends.contains($0) && source[$0 - 1] == "}" }) else { return nil }
        return closers
    }

    /// The source of every member of `file` whose declaration spans one of `lines`, each resolved as `digest` resolves it, or `nil` where none does or any resolves to some other declaration.
    ///
    /// A declaration spans its first line through the line its name stands on, so an attribute on a line of its own is part of it. Every member of the file is a candidate, whatever type holds it: a file of two views has two `body` properties, and a grep for one prints both.
    public static func memberSources(in engine: SiftEngine, file: String, declaredOn lines: [Int], source: [String]) throws -> [ServedSource]? {
        let members = try engine.store.symbols(inFile: file).filter { !$0.kind.isContainer }
        var chosen: [SymbolRow] = []
        for line in lines {
            for member in members where declarationSpan(of: member, in: source).contains(line) && !chosen.contains(where: { $0.id == member.id }) {
                chosen.append(member)
            }
        }
        guard !chosen.isEmpty else { return nil }
        let renderer = WhereRenderer(store: engine.store)
        var served: [ServedSource] = []
        for member in chosen.sorted(by: { $0.line < $1.line }) {
            let target = try (engine.store.parentChain(of: member).map(\.name) + [member.name]).joined(separator: ".")
            let resolved = try renderer.declarations(for: target)
            guard resolved.count == 1, resolved[0].id == member.id else { return nil }
            let answer = try engine.measuredDigest(target: target, options: DigestOptions())
            let range = member.line <= member.endLine && member.endLine <= source.count ? member.line ... member.endLine : nil
            let whole = range.map { servesVerbatim(source[($0.lowerBound - 1) ..< $0.upperBound], in: answer.text) } ?? false
            served.append(ServedSource(target: target, answer: answer, declaration: declarationSpan(of: member, in: source), lines: whole ? range : nil))
        }
        return served
    }

    /// `where` for `symbol` with every reference site, or `nil` where the index declares nothing of that name.
    public static func references(in engine: SiftEngine, of symbol: String, freshness: Freshness) async throws -> String? {
        guard try !WhereRenderer(store: engine.store).declarations(for: symbol).isEmpty else { return nil }
        return try await engine.lookup(symbol: symbol, freshness: freshness, options: WhereOptions(includeReferences: true))
    }

    /// `where` for `symbol` with no reference sites, split into the header line it opens with and everything under it — or `nil` where the index declares nothing of that name.
    ///
    /// Split so that several answers from one engine can be served under one header rather than repeating a fact about the tree once per name. The header is taken as the answer's own first line rather than rebuilt from the freshness, because the line an answer opens with is the one it is accountable for. Every owner's uses stay listed for a name several unrelated owners declare, since this answer stands in for a search whose every site's path it must show.
    public static func lookup(in engine: SiftEngine, of symbol: String, freshness: Freshness) async throws -> (header: String, body: String)? {
        guard try !WhereRenderer(store: engine.store).declarations(for: symbol).isEmpty else { return nil }
        let text = try await engine.lookup(symbol: symbol, freshness: freshness, options: WhereOptions(collapsesSeveralOwners: false))
        guard let newline = text.firstIndex(of: "\n") else { return (text, "") }
        return (String(text[..<newline]), String(text[text.index(after: newline)...]))
    }

    /// Every line a `where` answer locates by its own number: each declaration's first line, and each line a reference is listed on.
    ///
    /// Never a site matched on the name alone — those are leads the answer itself says may be something else, so their block is skipped and every resolved section written after it is still read — and never a row the answer marks as changed or deleted since the build.
    public static func locations(inWhereAnswer text: String) -> Set<Location> {
        var located = Set<Location>()
        // The file a store block's rows sit under while they are read: none under a file it marks as changed since the build.
        var heading: String?
        for line in NameMatchedSites.linesOutside(answer: text) {
            if line.hasPrefix("    :") {
                if let heading, let match = line.wholeMatch(of: siteTextRow), let number = Int(match.output.1) {
                    located.insert(Location(path: heading, line: number))
                }
                continue
            }
            heading = nil
            guard !line.contains("since last build") else { continue }
            if let match = line.wholeMatch(of: declarationLine), let start = Int(match.output.2) {
                located.insert(Location(path: String(match.output.1), line: start))
            } else if let match = line.wholeMatch(of: referenceLine) {
                for number in match.output.2.split(separator: ",") {
                    if let value = Int(number.trimmingCharacters(in: .whitespaces)) {
                        located.insert(Location(path: String(match.output.1), line: value))
                    }
                }
            } else if let match = line.wholeMatch(of: siteTextHeading) {
                heading = String(match.output.1)
            }
        }
        return located
    }

    /// Every Swift file a `search` answer lists matches in, by the heading ``SearchRenderer`` opens each file's block with — the path alone at the margin, then a colon.
    ///
    /// Never a path a match's signature happens to spell: those are indented under the heading, and name no file the search found anything in.
    public static func files(inSearchAnswer text: String) -> Set<String> {
        var files = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            if let match = line.wholeMatch(of: searchFileHeading) {
                files.insert(String(match.output.1))
            }
        }
        return files
    }

    /// The files one digest answer locates, sorted: those a module digest lists under headings as a `search` answer does, and the file it served in place of a path it holds no file at.
    ///
    /// A type or file digest prints neither, and is matched by its target instead. The usage line of a single-target digest records these, and each name of a split target records its own answer's.
    public static func files(inDigestAnswer text: String) -> [String] {
        files(inSearchAnswer: text).union(servedFile(inDigestAnswer: text).map { [$0] } ?? []).sorted()
    }

    /// The file a digest answer served in place of a path it holds no file at, the one indexed file of that path's name, which the answer's own notice names; `nil` where it carries no such notice.
    public static func servedFile(inDigestAnswer text: String) -> String? {
        text.split(whereSeparator: \.isNewline).lazy.compactMap { $0.wholeMatch(of: servedNoticeLine).map { String($0.output.1) } }.first
    }

    /// The notice a digest answer opens with where it served the one indexed file sharing a missing path's name instead of that path.
    static func servedNotice(asked path: String, served: String) -> String {
        "no indexed file at \(path) — served \(served), the one indexed file of that name"
    }

    /// Whether a digest answer opens with the notice that it served another file than the one asked for, `path`.
    static func opensWithServedNotice(_ text: String, asked path: String) -> Bool {
        text.hasPrefix("no indexed file at \(path) — served ")
    }

    /// Whether a `where` answer can locate a line of the file at `path` at all: it lists declarations and references in Swift source and nothing else.
    public static func whereAnswerLocates(linesOf path: String) -> Bool {
        path.hasSuffix(".swift")
    }

    /// The fewest bytes any `where` answer spends locating `lines` of the file at `path`, whatever its repository-relative spelling — so a search that prints more than an answer's budget of them can be refused before the answer is asked for.
    ///
    /// A line is located one of the two ways ``referenceLine`` and ``declarationLine`` read. By a reference line, `  path.swift (N): 4, 5, 6`, which spends at least a byte of indent, the path, six bytes on the count and its punctuation, and each line's digits with the two-byte separator between them; or by a declaration entry, `  Name — kind — signature — path.swift:12`, which spends at least a byte of indent, five on one ` — `, the path, a colon and the line's digits for each line it locates. Either way that is at least the path's file name and five bytes, and each line's digits and two bytes more — the floor returned here.
    public static func leastSpentLocating(_ lines: [Int], ofFileAt path: String) -> Int {
        let name = path.split(separator: "/").last.map(\.utf8.count) ?? path.utf8.count
        return name + 5 + lines.reduce(0) { $0 + String($1).utf8.count + 2 }
    }

    /// `path` relative to `engine`'s repository, or `nil` where it lies outside it — compared canonically, so a path spelled through a symlink still places.
    public static func repositoryRelativePath(of path: String, in engine: SiftEngine) -> String? {
        let root = CanonicalPath.of(engine.repoRoot.path)
        let file = CanonicalPath.of(path)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard file.hasPrefix(prefix) else { return nil }
        return String(file.dropFirst(prefix.count))
    }
}

public extension ExactAnswer {
    /// One member's source, and the lines of its file the answer serves verbatim.
    struct ServedSource: Sendable {
        /// The call that answered, `Type.member` as `digest` takes it.
        public let target: String
        public let answer: MeasuredAnswer
        /// The member's declaration: its first line through the line its name stands on.
        public let declaration: ClosedRange<Int>
        /// The lines of the file served verbatim — the member's whole range — or `nil` where the answer serves them cut.
        public let lines: ClosedRange<Int>?
    }

    /// One line of one file, repository-relative.
    struct Location: Hashable, Sendable {
        public let path: String
        public let line: Int

        public init(path: String, line: Int) {
            self.path = path
            self.line = line
        }
    }
}

extension ExactAnswer {
    /// A declaration's range at the end of a digest entry, `  :12` or `  :12-40`, before any `#if` condition (`  [#if DEBUG]`) and doc summary.
    nonisolated(unsafe) static let rangeToken = #/ {2}:(\d+)(?:-\d+)?(?: {2}\[[^\n]*?\])?(?: {2}\/\/\/.*)?$/#

    /// A declaration's range of more than one line at the end of a digest entry, `  :12-40`, before any `#if` condition and doc summary.
    nonisolated(unsafe) static let rangeSpan = #/ {2}:(\d+)-(\d+)(?: {2}\[[^\n]*?\])?(?: {2}\/\/\/.*)?$/#

    /// A `where` entry that locates one line — a declaration, `  Module.Name — kind — signature — path.swift:12-40` with any doc summary after, or a listed row, `  caller — path.swift:12` with the access or a conformer's mark (`— direct`, `— indirect`, `— direct; the index store does not have it`, `— direct; the index store has it through another type`, `— writes <Name>, which the index store resolves to <Declaration>`, `— through typealias <alias>`, `— inherited through <Name>`), unit count and folded sites a row may close on (`— read via $flag`, `  ×2 units`, `(3 sites)`).
    nonisolated(unsafe) static let declarationLine =
        /\s+.* — (.+\.swift):(\d+)(?:-\d+)?(?: — (?:read and write|read|write|used|referenced|direct; the index store does not have it|direct; the index store has it through another type|writes \S+, which the index store resolves to \S+|through typealias \S+|inherited through \S+|direct|indirect)(?: via \S+)?)?(?:  ×\d+ units)?(?: \(\d+ sites\))?(?:  \/\/\/.*)?/

    /// A `where` reference line, `  path.swift (3): 4, 5, 6`, whole or capped, `  path.swift (60): 4, 10, +58 more`, whose listed lines are the only ones it locates.
    nonisolated(unsafe) static let referenceLine = /\s+(.+\.swift) \(\d+\): (\d+(?:, \d+)*)(?:, \+\d+ more)?/

    /// A store block's file heading where its sites are listed one row per line with their text, `  path.swift (3):`, with any mark or typealias spelling after the colon.
    nonisolated(unsafe) static let siteTextHeading = #/ {2}(\S.*\.swift) \(\d+\):.*/#

    /// A site row under a ``siteTextHeading``, `    :12  caller  | text`, which locates its one line.
    nonisolated(unsafe) static let siteTextRow = #/ {4}:(\d+)(?:  .*)?/#

    /// The heading a `search` answer opens one file's matches with, `Sources/App/Depot.swift:`, at the margin and nothing after the colon.
    nonisolated(unsafe) static let searchFileHeading = /(\S[^:]*\.swift):/

    /// The notice ``servedNotice(asked:served:)`` writes, capturing the file served.
    nonisolated(unsafe) static let servedNoticeLine = /no indexed file at .+ — served (.+?\.swift), the one indexed file of that name/

    /// Whether `block` stands in `text` as consecutive lines, exactly as written.
    static func servesVerbatim(_ block: ArraySlice<String>, in text: String) -> Bool {
        guard let first = block.first else { return false }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for start in lines.indices where lines[start] == first && start + block.count <= lines.count {
            if zip(lines[start ..< start + block.count], block).allSatisfy({ $0 == $1 }) {
                return true
            }
        }
        return false
    }

    /// A declaration's first line through the line its name stands on, bounded by its range.
    static func declarationSpan(of row: SymbolRow, in source: [String]) -> ClosedRange<Int> {
        let last = min(row.endLine, source.count)
        guard row.line >= 1, row.line <= last else { return row.line ... row.line }
        for number in row.line ... last where containsWord(row.baseName, in: source[number - 1]) {
            return row.line ... number
        }
        return row.line ... row.line
    }

    /// A declaration's source from its first line through the end of its name, every whitespace character dropped — the text its digest entry has to hold for the span's lines to count as shown — or `nil` where the span's last line holds no name.
    static func shownHead(of row: SymbolRow, span: ClosedRange<Int>, in source: [String]) -> String? {
        guard span.upperBound <= source.count, let nameEnd = wordRange(of: row.baseName, in: source[span.upperBound - 1])?.upperBound else { return nil }
        let head = source[(span.lowerBound - 1) ..< (span.upperBound - 1)].joined() + source[span.upperBound - 1][..<nameEnd]
        return head.filter { !$0.isWhitespace }
    }

    /// Whether `line` holds `name` with no identifier character against either end of it.
    static func containsWord(_ name: String, in line: String) -> Bool {
        wordRange(of: name, in: line) != nil
    }

    /// Where `line` first holds `name` with no identifier character against either end of it.
    static func wordRange(of name: String, in line: String) -> Range<String.Index>? {
        guard !name.isEmpty else { return nil }
        let isIdentifier: (Character?) -> Bool = { $0.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false }
        var searchStart = line.startIndex
        while let found = line.range(of: name, range: searchStart ..< line.endIndex) {
            let before = found.lowerBound > line.startIndex ? line[line.index(before: found.lowerBound)] : nil
            let after = found.upperBound < line.endIndex ? line[found.upperBound] : nil
            if !isIdentifier(before), !isIdentifier(after) {
                return found
            }
            searchStart = line.index(after: found.lowerBound)
        }
        return nil
    }
}
