//
// Copyright © Agulhas Labs
//

import Foundation
import RegexBuilder

/// What a sweep — a search with no one file behind it — asks the index for, read off its pattern alone.
///
/// **The rule it serves is that a sweep is withheld and scored as a text search only when no index call answers it.** That the advisor could not build one neat call is not the same claim, and treating it as one moves the share in the direction it may never round: `": UsageWindow"`, `@Observable` and `try!` are all questions the index answers, and scoring them as text inflates the share by exactly the lookups that went around it.
///
/// So the reading is generous about what an index call answers and strict only about which *name* it stands on. One name in Swift-shaped company is that name. A pattern of Swift's declaration vocabulary is the `search` query that asks it. An alternation is one `where` per name in it, and where a branch of prose stands beside the names it is those calls with the prose branches kept as written, so an answer standing on the names can say what it does not cover. What is left is a phrase of ordinary words — `stale index`, `revisit this later` — which names no symbol however its longest word is chosen, and guessing one would refuse the search wherever an index happens to declare that word.
enum SweepPattern: Equatable {
    /// One or more names, each answered by `where`.
    case names([String])
    /// A shape `search` answers, as its query.
    case shape(String)
    /// Nothing one index call answers.
    case text
    /// An alternation of names beside branches of prose: one `where` per name, and the prose branches as the caller wrote them, which no index call answers and an answer standing on the names has to name.
    case partial(names: [String], prose: [String])

    /// Whether this reading answers only some of the branches its pattern alternates between — the names — and leaves the prose beside them to a search.
    var isPartial: Bool {
        if case .partial = self {
            return true
        }
        return false
    }

    /// Whether this is a shape asking for Swift's own declaration vocabulary — an attribute, a kind, a modifier, an effect, a fact or a signature — rather than only a fragment of a name.
    ///
    /// **The bar an unmarked sweep's shape has to clear**, and it is a different bar from a name's. A name is withheld downstream when no index declares it (`AdvisableName`), and a shape has no such check — `search kind:class modifier:final` is always answerable — so whatever the classification lets through is what gets said. The bar therefore sits here: the pattern must spell words of Swift's own, which is what `search` is for and what `grep` genuinely cannot express.
    ///
    /// A `name:` fragment alone does not clear it, and that is the whole of the difference. `Transcript[A-Z][a-z]+` reads as `name:Transcript`, which is a real offer once the tree is known to be Swift — but read off the pattern alone it is indistinguishable from a wildcard over any token, and prose is full of those: measured over 10,000 real searches, 61 unmarked sweeps read as a shape and 52 of them were markdown (`T[0-9]{3}` as `name:T`, `^- \*\*T23[12]` as `name:T23`). The nine that spelled vocabulary were all Swift — `final class`, `@Test func`, `static func`, `@MainActor`, `@Suite`.
    ///
    /// Read off the query's own terms because this type builds them: every term but `name:` stands for a word the pattern carried.
    var asksDeclarationVocabulary: Bool {
        guard case let .shape(query) = self else { return false }
        return query.split(separator: " ").contains { !$0.hasPrefix("name:") }
    }

    /// The reading of `pattern` — shell text as a search tool receives it, quotes already removed or not.
    static func reading(of pattern: String) -> SweepPattern {
        let raw = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let branches = raw.split(separator: alternation, omittingEmptySubsequences: false).map(String.init)
        guard branches.count == 1 else {
            // Two names at once are two questions, each of which `where` answers. **A branch of prose beside
            // them is kept, not dropped**, because what the advice replaces is the whole command: the caller asked
            // for either branch, and an answer standing only on the names covers fewer branches than were written.
            // It may still be given, but only saying so — which branches it leaves to a search — and this is the
            // one place that can say it: past the reading the declaredness gate (`PreToolUseCommand.lookup`) and
            // the answerer hold only what the reading handed on, never the branches the caller wrote. Dropping the
            // prose here is how the narrowing once went out silently.
            //
            // A branch that is only declaration syntax — `final class`, `@Test func`, `class .*Store` — has no
            // name of its own, but it is not prose either, and alone beside a name it never empties the
            // alternation: prose is a branch with no name that does not open on a declaration's form
            // (``opensADeclaration(_:)``), read as ``InPlaceShape/opensADeclaration(_:)`` reads it but for one
            // word — `open` before anything but a declaration's word, `open question`, is still an English
            // phrase here, where a one-file grep instead lets a digest answer for it either way.
            //
            // Every other branch with no name of its own is uncovered and is named in the caveat — not only a
            // branch with a space in it: `--verdict`, an issue reference, or an escaped path name no symbol as
            // much as a sentence does, and an answer that drops them from its caveat as silently as from its
            // calls is claiming to cover more than it does. A declaration-syntax branch is never named there
            // itself — it stands on no symbol to omit — but it is not a free pass either: beside real prose it
            // withholds the whole alternation, as any prose did before this reading could narrow to a caveat at
            // all, rather than being answered on the names with a caveat that could never say what the
            // declaration branch was.
            // Two spellings of one name — `Depot.pending\|Depot\.pending` — are one question, asked once.
            let named = branches.compactMap { name(of: $0) }.reduce(into: [String]()) {
                if !$0.contains($1) {
                    $0.append($1)
                }
            }
            guard !named.isEmpty else { return .text }
            let uncovered = branches.filter { name(of: $0) == nil && !opensADeclaration($0) }
            guard !uncovered.isEmpty else { return .names(named) }
            guard !branches.contains(where: opensADeclaration) else { return .text }
            return .partial(names: named, prose: uncovered.map(asWritten))
        }
        // A file's name is text written about a file, and a capitalised stem would otherwise carry the pattern as a
        // type's name in any company — `README.md` read as `where README`.
        // **A comma list is not an alternation, and is deliberately not read as one** — `UsageWindow,
        // CatalogueStore` is the literal text a search tool looks for, two names side by side on one line, which
        // no index call answers: `where UsageWindow` and `where CatalogueStore` answer about each name wherever
        // it stands, and neither is the adjacency being hunted. `|` is the spelling that genuinely asks for
        // either name, and it keeps its offer. A comma list was read as several names on the arithmetic that it
        // is the same several questions; it is not, and nobody writes it — over 10,000 real search segments
        // from this machine's transcripts, the comma spelling appears once, in a line of prose about this very
        // shape quoted into a session. So the reading narrows rather than the classifier widening, and the two
        // spellings of that sweep agree: unmarked and `--include=*.swift` alike, it is text.
        guard !PatternReading.spellsAFile(raw) else { return .text }
        if let name = PatternReading.identifier(in: raw, certain: true) {
            return .names([name])
        }
        return reading(ofWords: raw)
    }

    /// The name an alternation branch is, once its anchors and grouping are set aside, or `nil` when it is anything more.
    private static func name(of branch: String) -> String? {
        let bare = branch.replacing(anchor, with: "").trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
        guard !bare.isEmpty else { return nil }
        if let name = PatternReading.identifier(in: bare, certain: true) {
            return name
        }
        guard bare.wholeMatch(of: IndexSuggestion.identifier) != nil, !keywords.contains(bare) else { return nil }
        guard bare.count >= 3 || branch.contains(PatternReading.wordBoundary) else { return nil }
        return bare
    }

    /// A prose branch as the caller wrote it, less the whitespace and grouping parentheses around the alternation rather than inside the branch.
    ///
    /// Only an unbalanced leading `(` or trailing `)` is a grouping mark — `\(foo\|bar\)` splits into branches each carrying one half of the group's own parentheses — so a branch whose own parentheses balance, like `call it()`, keeps them: trimming on the character alone would drop the `()` the caller wrote as part of the name.
    private static func asWritten(_ branch: String) -> String {
        var text = branch.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("("), text.filter({ $0 == "(" }).count > text.filter({ $0 == ")" }).count {
            text.removeFirst()
        }
        if text.hasSuffix(")"), text.filter({ $0 == ")" }).count > text.filter({ $0 == "(" }).count {
            text.removeLast()
        }
        return text
    }

    /// Whether `branch` opens on a declaration's form — `final class`, `^\s*static let`, `mutating func`, `required init`, `@Test func` — read off `InPlaceShape`'s words and vocabulary, so the two readers of a declaration's form cannot disagree about one.
    ///
    /// Save for one word: `open` is an English word before it is a modifier, and opens a declaration here only where a declaration's word follows it — `open class`, never `open question`. Any other difference leans the wrong way: a branch taken for prose drops the lowercase name beside it, and the hook withholds a lookup `where` would have answered.
    private static func opensADeclaration(_ branch: String) -> Bool {
        let words = InPlaceShape.formWords(of: branch)
        guard let first = words.first, InPlaceShape.isVocabulary(first) else { return false }
        return first != "open" || words.dropFirst().first.map(InPlaceShape.isVocabulary) == true
    }

    /// The reading of a pattern with no alternation in it, word by word.
    private static func reading(ofWords raw: String) -> SweepPattern {
        // A wildcard beside a word makes the word part of a name rather than the whole of one, so it is marked
        // before the other escapes are blanked: `class .*Store` is every class whose name holds `Store`.
        let text = raw.replacing(wildcard, with: "\u{1}").replacing(PatternReading.escapeSequence, with: " ")
        var shape = Shape()
        var names: [String] = []
        var shortNames: [String] = []
        var context = false
        for match in text.matches(of: word) {
            let (_, attribute, name) = match.output
            let term = String(name)
            let before = match.range.lowerBound == text.startIndex ? nil : text[text.index(before: match.range.lowerBound)]
            let after = match.range.upperBound == text.endIndex ? nil : text[match.range.upperBound]
            if attribute != nil {
                shape.attributes.append(term)
            } else if before == "\u{1}" || after == "\u{1}" {
                shape.fragments.append(term)
            } else if let kind = kinds[term] {
                shape.kinds.append(kind)
                // The index files a `let` under `kind:var`; its signature is what tells it from a `var`.
                if term == "let" {
                    shape.signatures.append(term)
                }
            } else if modifiers.contains(term) {
                shape.modifiers.append(term)
            } else if term == "async" || term == "throws" {
                shape.effects.append(term)
            } else if let fact = facts[term + (after.map(String.init) ?? "")] ?? facts[term] {
                shape.facts.append(fact)
            } else if keywords.contains(term) {
                context = true
            } else if term.count >= 3 {
                names.append(term)
            } else {
                shortNames.append(term)
            }
        }
        if names.isEmpty, shortNames.isEmpty, !context, let query = shape.query {
            return .shape(query)
        }
        if let name = names.first, names.count == 1 {
            return carries(name, shape: shape, text: text, english: context || !shortNames.isEmpty) ? .names(names) : .text
        }
        // A short name alone is a name only word-anchored: unanchored, `x` matches inside every word holding it.
        if names.isEmpty, shortNames.count == 1, shape.isEmpty, !context, raw.contains(PatternReading.wordBoundary) {
            return .names(shortNames)
        }
        return .text
    }

    /// Whether the words and punctuation around a pattern's one name make it a lookup of that name rather than a phrase.
    ///
    /// **Only Swift-shaped context carries a lowercase name**: an attribute, a declaration keyword, or code punctuation — `: order`, `.order`, `order:`, `order?`, `order {`. A control-flow or English word beside it makes a phrase, and these are the same phrases ``ShellQuery/identifier(in:certain:)`` already refuses to read as a name: `for now`, `in progress`, `is empty`, `by default`, `import order`, `set up`, `try again`, `return early`. A capitalised name is a type's name in any company — `some View`, `import Foundation` — as it is standing alone.
    private static func carries(_ name: String, shape: Shape, text: String, english: Bool) -> Bool {
        if name.first?.isUppercase == true {
            return true
        }
        let englishContext = english || !shape.modifiers.isEmpty || !shape.effects.isEmpty || !shape.facts.isEmpty
        let swiftContext = !shape.attributes.isEmpty || !shape.kinds.isEmpty || text.contains(codePunctuation)
        return swiftContext && !englishContext
    }

    /// Punctuation only code puts beside a name: a type annotation's colon, optional and force marks, braces, brackets, generics, parentheses, and a dot that opens a member.
    nonisolated(unsafe) private static let codePunctuation = Regex {
        ChoiceOf {
            /[:?!{}\[\]<>()=]/
            Regex {
                "."
                Lookahead { IndexSuggestion.identifier }
            }
        }
    }

    /// `|` in an extended pattern, `\|` in a basic one.
    nonisolated(unsafe) private static let alternation = /\\?\|/

    /// The anchors and boundaries a branch may carry around its name.
    nonisolated(unsafe) private static let anchor = /\\[b<>]|[\^$]/

    /// A run of any characters or of word characters, or a character class, which makes the word beside it a fragment of a name.
    ///
    /// A class counts with or without a quantifier: `for[A-Z]` is every name that goes on past `for` with a capital, as `Transcript[A-Za-z]+` is every name that starts with `Transcript`. Read as whole words, both offered `where` for a prefix — the regex quoted as though it were a name.
    nonisolated(unsafe) private static let wildcard = /\.[*+]|\\w[*+]|\[[^\]]*\][*+?]?/

    /// A word, and the `@` that makes it an attribute — the word a Swift identifier in any script (``IndexSuggestion/identifier``).
    nonisolated(unsafe) private static let word = Regex {
        Optionally { Capture { "@" } }
        Capture { IndexSuggestion.identifier }
    }

    /// Declaration keywords and the `kind:` each is filed under; a `let` is a `var` to the index.
    private static let kinds: [String: String] = [
        "func": "func", "struct": "struct", "class": "class", "enum": "enum", "protocol": "protocol", "actor": "actor",
        "extension": "extension", "init": "init", "var": "var", "let": "var",
    ]

    /// Declaration modifiers `search` filters on with `modifier:`.
    private static let modifiers: Set<String> = [
        "public", "private", "internal", "fileprivate", "package", "static", "final", "override",
    ]

    /// Expressions `search` finds with `has:`, keyed by how a pattern spells them.
    private static let facts: [String: String] = ["try!": "forceTry", "as!": "forceCast", "try": "try", "await": "await"]

    /// Swift's own words, which a pattern may carry as context around the name it is after.
    private static let keywords: Set<String> = [
        "func", "struct", "class", "enum", "protocol", "actor", "extension", "typealias", "var", "let",
        "case", "self", "Self", "init", "deinit", "subscript", "some", "any", "async", "await", "throws", "rethrows",
        "public", "private", "internal", "fileprivate", "package", "static", "final", "override", "where", "for",
        "while", "in", "do", "try", "catch", "switch", "guard", "return", "import", "if", "else", "nil", "true",
        "false", "as", "is", "defer", "throw", "inout", "mutating", "nonisolated", "lazy", "weak", "unowned",
    ]
}

private extension SweepPattern {
    /// The terms a pattern's Swift vocabulary contributes to a `search` query.
    struct Shape {
        var attributes: [String] = []
        var kinds: [String] = []
        var fragments: [String] = []
        var modifiers: [String] = []
        var effects: [String] = []
        var facts: [String] = []
        var signatures: [String] = []

        var isEmpty: Bool {
            attributes.isEmpty && kinds.isEmpty && fragments.isEmpty && modifiers.isEmpty && effects.isEmpty && facts.isEmpty
        }

        /// The query, or `nil` where there is nothing to ask or it would ask for two kinds at once.
        ///
        /// A query is a conjunction, and `class func` is a class method rather than a class and a function.
        var query: String? {
            guard !isEmpty, kinds.count <= 1 else { return nil }
            let terms = attributes.map { "attr:\($0)" } + kinds.map { "kind:\($0)" } + fragments.map { "name:\($0)" }
                + modifiers.map { "modifier:\($0)" } + effects.map { "effect:\($0)" } + facts.map { "has:\($0)" }
                + signatures.map { "sig:\($0)" }
            return terms.joined(separator: " ")
        }
    }
}
