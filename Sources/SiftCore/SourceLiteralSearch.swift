//
// Copyright © Agulhas Labs
//

import Foundation

/// Finds the lines of Swift source whose string literals hold a piece of wording, each named by the declaration it sits in.
///
/// The half of `strings` for a repository whose user-facing text was never put in a catalog — a CLI, a tool, a server — where the wording an agent wants to trace lives in a literal like `"refused — \(underlying) did not complete"`. Only text inside a string literal counts, never a comment or an identifier (``SwiftLiteralLexer``), which is what keeps this a trace of wording rather than a grep.
///
/// Reads the working tree, like the catalog half, so nothing here can be stale. The enclosing declaration comes from a fresh parse of the files the listed sites are in, not from the index's stored ranges: `strings` takes no freshness and the file holding the wording is often the one just edited, where a stored range is the thing most likely to be out of date. Which sites are production is known from each file's imports, read line by line beside the literals (``ImportLineReader``), so only the files holding a listed site are parsed.
struct SourceLiteralSearch {
    let repoRoot: URL
    let swiftPaths: () -> [String]

    /// Sites listed per section of the answer, and so the most whose declarations are resolved in each.
    static var siteCap: Int {
        20
    }

    /// Every line holding a literal that contains `query`, or starting the part of a run of literals a `+` joins that holds it (``ConcatenatedLiteralRuns``), or failing that one that matches it around its interpolations, sorted by path then line, the first ``siteCap`` production sites of each kind with their declarations; a site matched around interpolations on one query word only is never resolved, since the answer only counts it.
    ///
    /// A site is a test site when its file imports a test framework, the judgement `where` uses for a type's usage (``TestFileRecognition/isTestFile(imports:)``); a kind matching only test sites resolves the first ``siteCap`` of those instead.
    func run(query: String) -> [Site] {
        guard !query.isEmpty else {
            return []
        }
        let prepared = InterpolationWildcard.Query(query)
        var sites: [Site] = []
        for path in swiftPaths().sorted() {
            guard let data = FileManager.default.contents(atPath: repoRoot.appendingPathComponent(path).path),
                  let source = String(data: data, encoding: .utf8)
            else { continue }
            var lexer = SwiftLiteralLexer()
            var imports: [String] = []
            // Whether the file is a test file is known only once its imports are read, so each site is settled after the scan.
            var found: [Site] = []
            var runs = ConcatenatedLiteralRuns()
            for (number, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if lexer.isInCode, let module = ImportLineReader.module(inLine: line) {
                    imports.append(module)
                }
                let literals = lexer.literals(on: line)
                runs.add(literals, continuing: lexer.continuesRun, line: number + 1)
                if let literal = literals.first(where: { $0.contains(query) }) {
                    found.append(Site(path: path, line: number + 1, literal: literal.text, around: nil, window: nil, declaration: nil, isTest: false))
                } else {
                    let matches = literals.compactMap { literal in literal.match(around: prepared).map { (text: literal.text, match: $0) } }
                    if let chosen = matches.first(where: \.match.isListed) ?? matches.first {
                        found.append(Site(path: path, line: number + 1, literal: chosen.text, around: chosen.match, window: nil, declaration: nil, isTest: false))
                    }
                }
            }
            // A run held whole by none of its pieces is a plain site of its own line, which no other literal of that line holds plainly; it outranks a match around interpolations there, as a plain literal does.
            for run in runs.matches(of: query) where !found.contains(where: { $0.line == run.line && !$0.isAroundInterpolation }) {
                found.removeAll { $0.line == run.line }
                found.append(Site(path: path, line: run.line, literal: run.shown, around: nil, window: run.window, declaration: nil, isTest: false))
            }
            found.sort { $0.line < $1.line }
            guard !found.isEmpty else { continue }
            let isTest = TestFileRecognition.isTestFile(imports: imports)
            sites += found.map { Site(path: path, line: $0.line, literal: $0.literal, around: $0.around, window: $0.window, declaration: nil, isTest: isTest) }
        }
        sites = Self.listingRareOneWordMatches(in: sites)
        // Each section, plain and matched around interpolations, lists its own production sites, or its test sites when it has none; a site matched on one query word is only counted.
        let listable = sites.filter(\.isListable)
        let listsTests = [false, true].filter { around in !listable.contains { !$0.isTest && $0.isAroundInterpolation == around } }
        return resolvingDeclarations(of: sites, listing: { $0.isListable && $0.isTest == listsTests.contains($0.isAroundInterpolation) })
    }

    /// Production sites a word matched on in one-word matches around interpolations, at most, for those matches to be listed when nothing else lists.
    static var fallbackSiteLimit: Int {
        8
    }

    /// `sites` with the production one-word matches listed whose word has at most ``fallbackSiteLimit`` of them, when no plain production site and no match on two query words lists; otherwise `sites` unchanged.
    ///
    /// A word that rare is the query's distinctive one, where a common word names more sites than a listing helps with; the limit is a threshold, and the sites keep their path order.
    private static func listingRareOneWordMatches(in sites: [Site]) -> [Site] {
        guard !sites.contains(where: { $0.around == nil ? !$0.isTest : $0.isListable }) else {
            return sites
        }
        var production: [String: Int] = [:]
        for site in sites where !site.isTest {
            if let word = site.around?.word {
                production[word, default: 0] += 1
            }
        }
        return sites.map { site in
            guard !site.isTest, let around = site.around, let word = around.word, production[word, default: 0] <= fallbackSiteLimit else {
                return site
            }
            return Site(path: site.path, line: site.line, literal: site.literal, around: around.listed(), window: site.window, declaration: nil, isTest: false)
        }
    }

    /// `sites` with the listed ones named by their enclosing declaration, the first ``siteCap`` sites `listing` accepts.
    ///
    /// Each file holding a listed site is parsed once, here, and no other file is.
    private func resolvingDeclarations(of sites: [Site], listing: (Site) -> Bool) -> [Site] {
        var resolved: [Bool: Int] = [:]
        var parsed: [String: ParsedFile] = [:]
        return sites.map { site in
            guard listing(site), resolved[site.isAroundInterpolation, default: 0] < Self.siteCap else {
                return site
            }
            resolved[site.isAroundInterpolation, default: 0] += 1
            if parsed[site.path] == nil {
                parsed[site.path] = FileParser.parse(absoluteURL: repoRoot.appendingPathComponent(site.path), repoRelativePath: site.path)
            }
            guard let file = parsed[site.path],
                  let declaration = RunFailureSites.Declaration(enclosing: site.line, in: file)
            else {
                return site
            }
            return Site(path: site.path, line: site.line, literal: site.literal, around: site.around, window: site.window, declaration: declaration.name, isTest: site.isTest)
        }
    }
}

extension SourceLiteralSearch {
    /// One line of Swift source holding a literal that contains the query.
    struct Site: Equatable {
        let path: String
        let line: Int
        /// The first matching literal's text as written, interpolations included; for a run of literals joined by `+`, the pieces the match touches joined by `" + "` (``ConcatenatedLiteralRuns``).
        let literal: String
        /// How the query matched around the literal's interpolations (``InterpolationWildcard``), `nil` for a literal that holds the query itself.
        let around: InterpolationWildcard.Match?
        /// The characters of `literal` the query matched, for a run of joined literals whose shown text does not spell the query; `nil` where the display finds the query itself.
        let window: Range<Int>?
        /// The innermost declaration enclosing the line, `nil` outside every declaration or past the listed sites.
        let declaration: String?
        /// Whether the file holding the line imports a test framework.
        let isTest: Bool

        /// Whether the query was matched around the literal's interpolations rather than found whole in one segment.
        var isAroundInterpolation: Bool {
            around != nil
        }

        /// Whether the site is listed in its section, rather than only counted as a match around interpolations on one query word.
        var isListable: Bool {
            around?.isListed ?? true
        }
    }
}
