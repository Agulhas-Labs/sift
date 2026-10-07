//
// Copyright © Agulhas Labs
//

/// A parsed structural query: whitespace-separated `field:value` terms, ANDed, each optionally negated with a leading `!`.
///
/// This is the shape axis the index cannot serve. `where` and `digest` answer questions about *names* — what is this called, who calls it — and the SQLite index stores declarations to match. "Which `@Test` functions wrap a call in an unstructured `Task`" is a question about *form*, and no table of declarations can answer it; grep cannot either, because the pattern spans nesting and line breaks. The parsed trees can, so a query runs over them directly rather than over stored rows.
///
/// Deliberately not a pattern language. A term set reads as one line, an agent can emit it without a grammar reference, and an unknown field answers with the full field list instead of a parse error — the cheapest way to learn what is askable.
public struct StructuralQuery: Sendable {
    public let terms: [Term]
    public let source: String
    /// Each misspelt field or kind word read as the grammar's own, as `given as wanted`, in query order.
    public let readings: [String]
    /// A full-sentence note for each `calls:`/`uses:`/`name:` value read down to a base name that dropped argument labels — carried apart from `readings` because it is not a bare spelling, and must say plainly that the answer now matches every value under that base name.
    public let labelDroppedNotes: [String]
    /// A full-sentence note for each `name:/…/` value that did not compile and was read as the words it plainly spells, quoting the regex engine's reason.
    public let patternNotes: [String]

    /// Parses `text`; throws `EngineError.malformedQuery` naming the valid fields when a term is unusable, the heal that produced an unhealable piece named alongside it.
    public init(_ text: String) throws {
        let spelled = try text.split(whereSeparator: \.isWhitespace).map(Self.readingBareTerms).map { try Self.readingSpellings($0) }
        guard !spelled.isEmpty else {
            throw EngineError.malformedQuery("empty query — \(Self.usage)")
        }
        do {
            terms = try spelled.map { try Term(piece: $0.piece) }
        } catch let EngineError.malformedQuery(detail) {
            if let said = spelled.compactMap(\.note?.reading).first {
                throw EngineError.malformedQuery("\(detail) (read \(said))")
            }
            throw EngineError.malformedQuery(detail)
        }
        source = spelled.map(\.piece).joined(separator: " ")
        readings = spelled.compactMap {
            if case let .plain(reading) = $0.note {
                reading
            } else {
                nil
            }
        }
        labelDroppedNotes = spelled.compactMap {
            if case let .labelDropped(_, sentence) = $0.note {
                sentence
            } else {
                nil
            }
        }
        patternNotes = spelled.compactMap {
            if case let .unreadablePattern(_, sentence) = $0.note {
                sentence
            } else {
                nil
            }
        }
    }

    /// The line(s) an answer carries under its header when a word was read as another, so the next call is spelled right; `nil` when nothing was.
    ///
    /// Plain spellings join onto one line ("the spelling(s) search takes"); a value that dropped argument labels is not a spelling — it widens what the query matches — so it gets its own full sentence, one line per such value.
    public var readingNote: String? {
        var lines: [String] = []
        if !readings.isEmpty {
            lines.append("read \(readings.joined(separator: ", ")) — the spelling\(readings.count == 1 ? "" : "s") search takes.")
        }
        lines.append(contentsOf: labelDroppedNotes)
        lines.append(contentsOf: patternNotes)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Field words a caller has been seen to write for one of the grammar's own fields.
    private static let fieldSpellings: [String: Field] = ["in": .path, "file": .path]

    /// Kind words a caller has been seen to write for one of the kinds `kind:` takes.
    private static let kindSpellings = ["function": "func"]

    /// A misspelt field or kind word read as the one it spells, and the reading said.
    ///
    /// Only the grammar's own words are read this way, each one-to-one: a spelling has one meaning, so the call answers the question it asked. A value never is — a near-miss name read as the nearest one would be believed and wrong. A `calls:`/`uses:`/`name:` value is the one exception, and not really an exception: `rendered()` is a spelling of the callee's own name, parentheses included, not a different value — the index keeps no argument list for a call, only the base name, so it is read down to it. Anything inside the parentheses (`rendered(_:)`, `save(to:)`) is read down the same way, but widens what the query matches — every call named `save`, whatever its arity or labels — so it carries its own plain sentence (``labelDroppedNotes``) rather than joining the one-line spelling note; only a bare `()` keeps that plain note.
    private static func readingSpellings(_ piece: String) throws -> (piece: String, note: Note?) {
        let negation = piece.hasPrefix("!") ? "!" : ""
        let body = piece.dropFirst(negation.count)
        guard let separator = body.firstIndex(of: ":") else { return (piece, nil) }
        let field = String(body[body.startIndex ..< separator])
        let written = String(body[body.index(after: separator)...])
        let namesADeclaration = field == Field.calls.rawValue || field == Field.uses.rawValue || field == Field.name.rawValue
        // A name written in backticks is matched by the name the index holds, which drops them around an ordinary word.
        let value = namesADeclaration ? SymbolNaming.unbackticked(written) : written
        let unwrapped = value == written ? piece : "\(negation)\(field):\(value)"
        if let wanted = fieldSpellings[field] {
            let clarifier = wanted == .path ? " (a path substring, not a type)" : ""
            return ("\(negation)\(wanted.rawValue):\(value)", .plain("\(field): as \(wanted.rawValue):\(clarifier)"))
        }
        if field == Field.kind.rawValue, let wanted = kindSpellings[value] {
            return ("\(negation)kind:\(wanted)", .plain("kind:\(value) as kind:\(wanted)"))
        }
        if Field(rawValue: field)?.readsRegex == true, let pattern = NamePattern.regexBody(value) {
            return try Self.readingRegex(pattern, field: field, negation: negation, value: value, piece: unwrapped)
        }
        if let (joined, reading) = Self.readingAlternatives(field: field, value: value) {
            return ("\(negation)\(field):\(joined)", .plain(reading))
        }
        if namesADeclaration, value.contains("(") || value.contains(")") {
            let (base, hasLabels) = try Self.baseCalleeName(field: field, value: value)
            let reading = "\(field):\(value) as \(field):\(base)"
            guard hasLabels else { return ("\(negation)\(field):\(base)", .plain(reading)) }
            let sentence = "read \(reading) — labels are not indexed, so this matches every \(Self.matchNoun(field)) named \(base), whatever its labels."
            return ("\(negation)\(field):\(base)", .labelDropped(reading: reading, sentence: sentence))
        }
        return (unwrapped, nil)
    }

    /// An alternation read as the one spelling the grammar keeps: the field label repeated on an alternative (`kind:struct|kind:enum`) dropped, and each alternative of a `kind:` value spelt as a kind; `nil` when nothing needed reading.
    ///
    /// Every field's value is read one alternative at a time, so `kind:struct|enum` and `kind:struct|kind:enum` are the same question. A `/…/` value is a regex, never an alternation, and is not read here.
    private static func readingAlternatives(field: String, value: String) -> (value: String, reading: String)? {
        guard value.contains("|"), !NamePattern.isOperatorName(value), Field(rawValue: field) != nil else { return nil }
        let alternatives = value.split(separator: "|").map { alternative -> String in
            let bare = alternative.hasPrefix("\(field):") ? String(alternative.dropFirst(field.count + 1)) : String(alternative)
            return field == Field.kind.rawValue ? kindSpellings[bare] ?? bare : bare
        }
        let joined = alternatives.joined(separator: "|")
        guard joined != value else { return nil }
        return (joined, "\(field):\(value) as \(field):\(joined)")
    }

    /// A `name:/…/`, `path:/…/` or `sig:/…/` value kept as written when it compiles; when it does not, a `name:` one is read as the words it plainly spells, or refused in one line quoting the regex engine's reason when it spells none.
    private static func readingRegex(_ pattern: String, field: String, negation: String, value: String, piece: String) throws -> (piece: String, note: Note?) {
        guard !NamePattern.repeatsAGroup(pattern) else {
            throw EngineError.malformedQuery("\"\(field):\(value)\" is not read as a regex — a repeated group can take unbounded time; write the alternatives out or repeat a character class instead; \(StructuralQuery.usage)")
        }
        do {
            _ = try NamePattern.compiled(pattern)
            return (piece, nil)
        } catch {
            let reason = String(describing: error)
            guard field == Field.name.rawValue, let words = NamePattern.literalAlternatives(pattern) else {
                throw EngineError.malformedQuery("\"\(field):\(value)\" does not compile as a regex — \(reason); \(StructuralQuery.usage)")
            }
            let healed = "name:\(words.joined(separator: "|"))"
            let reading = "name:\(value) as \(healed)"
            let sentence = "read \(reading) — the regex does not compile (\(reason)), so this matches any of those words."
            return ("\(negation)\(healed)", .unreadablePattern(reading: reading, sentence: sentence))
        }
    }

    /// The word a `calls:`/`uses:`/`name:` label-widening note names what it now matches by: a call, a use, or a declaration.
    private static func matchNoun(_ field: String) -> String {
        switch field {
        case Field.calls.rawValue: "call"
        case Field.uses.rawValue: "use"
        default: "declaration"
        }
    }

    /// The base callee name a `calls:`/`uses:`/`name:` value spells — `rendered()`, or a full argument-list spelling such as `rendered(at:into:)` or `rendered(_:)` — and whether the parentheses carried anything at all.
    ///
    /// Read down to what `BodyFacts` actually records, which is the base name alone; no argument list is stored to match against instead — not the labels, and not even the arity, so `rendered(_:)` matches a two-argument `rendered(_:_:)` too. Only a bare `()` is answered as a plain spelling fix; anything inside the parentheses means the answer now matches more than the value named, and the caller is told so. Any other parenthesized shape (unbalanced parentheses, a nested call, a qualified callee) refuses rather than silently matching nothing.
    private static func baseCalleeName(field: String, value: String) throws -> (base: String, hasLabels: Bool) {
        func isIdentifier(_ piece: some StringProtocol) -> Bool {
            guard let first = piece.first, first.isLetter || first == "_" else { return false }
            return piece.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }
        let noun = field == Field.name.rawValue ? "name" : "call"
        func malformed(_ detail: String) -> EngineError {
            .malformedQuery("\"\(field):\(value)\" \(detail); \(StructuralQuery.usage)")
        }
        let notASpelling = malformed("is not a \(noun) \(field): can read — parentheses spell a \(noun)'s name, and \"\(value)\" does not spell one")
        guard value.hasSuffix(")"), let open = value.firstIndex(of: "(") else { throw notASpelling }
        let base = value[value.startIndex ..< open]
        let inner = value[value.index(after: open) ..< value.index(before: value.endIndex)]
        guard !inner.contains("("), !inner.contains(")") else { throw notASpelling }
        guard isIdentifier(base) else {
            if base.contains(".") {
                throw malformed(
                    "is not a \(noun) \(field): can read — a qualified callee isn't indexed (only base names are); try \(field):\(base.split(separator: ".").last ?? "")"
                )
            }
            throw notASpelling
        }
        guard !inner.isEmpty else { return (String(base), false) }
        guard inner.hasSuffix(":") else { throw notASpelling }
        let labels = inner.dropLast().split(separator: ":", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ $0 == "_" || isIdentifier($0) }) else { throw notASpelling }
        return (String(base), true)
    }

    /// A term with no field is read as `name:` rather than refused.
    ///
    /// `search worktree` and `search module resolver` are how the question actually arrives — a bare identifier, sometimes two words of one — and each is a name lookup by any reading (ANDed substrings find `ModuleResolver` from the two-word form). The reading is visible, not silent: `source` keeps the normalized spelling, and the answer's echo line repeats it, so the caller sees `name:worktree` for what they typed.
    private static func readingBareTerms(_ piece: Substring) -> String {
        let body = piece.hasPrefix("!") ? piece.dropFirst() : piece
        guard !body.isEmpty, !body.contains(":") else { return String(piece) }
        return piece.hasPrefix("!") ? "!name:\(body)" : "name:\(body)"
    }

    /// The one-line teaching string, repeated by every rejection so a wrong guess costs one call rather than a documentation hunt.
    public static var usage: String {
        "terms are field:value, ANDed, negated with a leading ! (a bare term is read as name:) — fields: " + Field.allCases.map(\.rawValue).joined(separator: " ")
    }

    /// `true` when any term needs the declaration's subtree walked, which is the expensive half and is skipped when no term asks for it.
    var needsBodyScan: Bool {
        terms.contains { $0.field.isBodyScoped }
    }

    /// `true` when any term matches against the declaration's signature slice, which is then computed before matching instead of only for matches.
    var needsSignature: Bool {
        terms.contains { $0.field == .sig }
    }

    /// The terms in the order the scan applies them — declaration terms in query order, then body terms in query order — which is the order a miss names the term that emptied it by.
    var appliedOrder: [Term] {
        terms.filter { !$0.field.isBodyScoped } + terms.filter(\.field.isBodyScoped)
    }

    /// Path terms, applied to the file list *before* parsing — the only filter that can save the parse rather than merely fail it afterwards.
    var pathTerms: [Term] {
        terms.filter { $0.field == .path }
    }

    /// Whether `path` survives the query's path terms, checked before the file is read.
    func admitsPath(_ path: String) -> Bool {
        pathTerms.allSatisfy { $0.negated != $0.textMatches(path) }
    }

    /// `true` when any term asks about the file's imports, which are collected once per file after parsing.
    var hasImportTerms: Bool {
        terms.contains { $0.field == .imports }
    }

    /// The name a rootless query can be resolved by, or `nil` when it asks about shape alone.
    ///
    /// `search` takes a query rather than a name, but `name:` is a field and a bare term is read as one, so most searches arrive carrying the very name the probe wants. Without this, `search name:Logger` from a folder above several repositories refuses while `digest Logger` resolves, which is the same question answered two ways. A negated term names what the caller does *not* want and is no evidence of anything.
    ///
    /// Only a plain substring is a name to probe by: an alternation or a regex spells no one declaration's name.
    public var probeName: String? {
        terms.first {
            guard $0.field == .name, !$0.negated, case .substring = $0.namePattern else { return false }
            return true
        }?.value
    }

    /// The answer's echo line: the query as parsed, then how each alternation or pattern was read, so an alternation is told apart from a literal name holding a `|`.
    var echo: String {
        let readings = terms.compactMap { term in
            term.reading.map { "\(term.negated ? "!" : "")\(term.field.rawValue): \($0)" }
        }
        return (["search \(source)"] + readings).joined(separator: " — ")
    }

    /// Whether a `name:` pattern matches the whole of a declaration's own name — `qualifiedName` less its enclosing types — rather than part of it; such declarations lead the answer.
    func matchesNameWhole(_ qualifiedName: String) -> Bool {
        let head = qualifiedName.prefix { $0 != "(" }
        let own = head.lastIndex(of: ".").map { String(qualifiedName[qualifiedName.index(after: $0)...]) } ?? qualifiedName
        return terms.contains { $0.field == .name && !$0.negated && $0.namePattern?.matchesWhole(own) == true }
    }

    /// Whether a file with `imports` survives the query's import terms — a failing file contributes no declarations at all, mirroring `path`.
    func admitsImports(_ imports: Set<String>) -> Bool {
        terms.filter { $0.field == .imports }.allSatisfy { $0.negated != $0.anyAlternative(imports.contains) }
    }
}

private extension StructuralQuery {
    /// A reading a piece was healed under: a plain spelling that joins the shared "spelling(s) search takes" line, or a full sentence for a value healed down to a base name that dropped its argument list — which widens what the answer matches and must say so on its own line.
    enum Note {
        case plain(String)
        case labelDropped(reading: String, sentence: String)
        case unreadablePattern(reading: String, sentence: String)

        /// The bare `given as wanted` reading, the same for either case — what a refusal beside the healed piece names, without the widening explanation a label-dropped note also carries.
        var reading: String {
            switch self {
            case let .plain(reading): reading
            case let .labelDropped(reading, _): reading
            case let .unreadablePattern(reading, _): reading
            }
        }
    }
}

public extension StructuralQuery {
    /// One `field:value` predicate.
    struct Term: Sendable {
        public let field: Field
        public let value: String
        public let negated: Bool
        /// How a `name:` value matches a declaration's name; `nil` for every other field.
        public let namePattern: NamePattern?
        /// How a `path:` or `sig:` value written as a `/regex/` matches; `nil` for every other value.
        public let textPattern: NamePattern?
        /// The values a term matches when any one does: a field's `a|b` read one alternative at a time, a single value as itself; empty for `name:` and for a regex, which carry their own pattern.
        public let alternatives: [String]

        init(piece: String) throws {
            let negated = piece.hasPrefix("!")
            let body = negated ? String(piece.dropFirst()) : piece
            guard let separator = body.firstIndex(of: ":") else {
                throw EngineError.malformedQuery("\"\(piece)\" is not field:value — \(StructuralQuery.usage)")
            }
            let rawField = String(body[body.startIndex ..< separator])
            let rawValue = String(body[body.index(after: separator)...])
            guard let field = Field(rawValue: rawField) else {
                throw EngineError.malformedQuery("unknown field \"\(rawField)\" — \(StructuralQuery.usage)")
            }
            guard !rawValue.isEmpty else {
                throw EngineError.malformedQuery("\"\(piece)\" has no value — \(StructuralQuery.usage)")
            }
            if !field.readsRegex, rawValue.count > 1, rawValue.hasPrefix("/"), rawValue.hasSuffix("/"), !NamePattern.isOperatorName(rawValue) {
                // Refused whole, before any `|` splits the regex into pieces that each look like a plain value.
                try field.validate(value: rawValue)
            }
            let isRegex = field.readsRegex && NamePattern.regexBody(rawValue) != nil
            let written = field == .name || isRegex ? [rawValue] : Self.alternatives(in: rawValue)
            for alternative in written {
                try field.validate(value: alternative)
            }
            namePattern = field == .name ? try NamePattern(rawValue) : nil
            textPattern = isRegex && field != .name ? try NamePattern(rawValue, field: field.rawValue) : nil
            alternatives = field == .name || isRegex ? [] : written
            self.field = field
            value = rawValue
            self.negated = negated
        }

        /// The alternatives a value spells: its `|`-separated pieces, or the value itself when it is a lone operator name such as `||`.
        private static func alternatives(in value: String) -> [String] {
            guard value.contains("|"), !NamePattern.isOperatorName(value) else { return [value] }
            return value.split(separator: "|").map(String.init)
        }

        /// How the echo line says this term was read, or `nil` for a single plain value.
        var reading: String? {
            if let pattern = namePattern ?? textPattern {
                return pattern.reading
            }
            return alternatives.count > 1 ? "any of \(alternatives.joined(separator: ", "))" : nil
        }

        /// Whether any alternative satisfies `test`.
        func anyAlternative(_ test: (String) -> Bool) -> Bool {
            alternatives.contains(where: test)
        }

        /// Whether `text`, a file path or a signature, holds a `path:`/`sig:` term's substring or matches its regex.
        func textMatches(_ text: String) -> Bool {
            if let textPattern {
                return textPattern.found(in: text)
            }
            return anyAlternative { text.contains($0) }
        }

        /// The term as parsed, `!` kept — how a miss names it.
        var spelled: String {
            "\(negated ? "!" : "")\(field.rawValue):\(value)"
        }

        /// Applies this term's polarity to a raw match result.
        func accepts(_ matched: Bool) -> Bool {
            negated != matched
        }
    }

    /// The askable axes.
    enum Field: String, Sendable, CaseIterable {
        /// Declaration kind, as `SymbolKind` spells it — `func`, `struct`, `class`, `enum`, `case`, `init`, `var`, `deinit`; the full list is `StructuralMatcher.supportedKinds`.
        case kind
        /// An attribute written on the declaration, without the `@`: `Test`, `MainActor`, `Observable`.
        case attr
        /// Substring of the declaration's name, case-insensitive — bare terms land here, and they arrive as lowercase words (`worktree`, `statusline`) aimed at capitalized declarations.
        case name
        /// A call in the declaration's subtree, matched on the callee's base name.
        case calls
        /// Any identifier in the declaration's subtree — a superset of `calls` that also catches type references and property access.
        case uses
        /// A written conformance or superclass on a type or extension.
        case inherits
        /// A declaration modifier: `static`, `private`, `public`, `final`, `override`, `nonisolated`.
        case modifier
        /// A function effect: `async` or `throws`.
        case effect
        /// A shape present in the declaration's subtree — see `Shape`.
        case has
        /// Substring of the declaration's signature as written (attributes included, whitespace collapsed) — covers return types and parameter types without a body walk.
        case sig
        /// An exact module name the file imports (`HealthKit`, or a dotted submodule path as written); file-scoped, so it gates every declaration in the file.
        case imports
        /// Substring of the file path, applied before the file is parsed.
        case path
        /// The type a member is declared in: the innermost enclosing type or extension, by name or qualified path, generic arguments dropped — so a type's extensions answer too.
        case owner

        /// `true` when answering the term requires walking the declaration's subtree.
        var isBodyScoped: Bool {
            switch self {
            case .calls, .uses, .has: true
            case .kind, .attr, .name, .inherits, .modifier, .effect, .sig, .imports, .path, .owner: false
            }
        }

        /// `true` when a value written `/…/` is read as a regex rather than refused: the fields that match a piece of text.
        var readsRegex: Bool {
            self == .name || self == .sig || self == .path
        }

        /// What this field's value matches, named in the refusal of a pattern form it does not read.
        private var matchingSyntax: String {
            switch self {
            case .name: "name: matches a case-insensitive substring — write name:Fresh for names containing \"fresh\", name:a|b for any of several, name:/regex/ for a pattern (a repeated group such as (ab)+ is refused)"
            case .sig, .path: "\(rawValue): matches a substring, case-sensitively — write \(rawValue):a|b for any of several, \(rawValue):/regex/ for a case-insensitive pattern (a repeated group such as (ab)+ is refused)"
            default: "\(rawValue): matches the value exactly"
            }
        }

        /// Refuses a value written as a pattern — `~x`, `/x/`, `*` globs, `^x`, `x$` — which no field reads: it would be taken as a literal and answer "no declarations match", which reads as "no such symbol".
        ///
        /// A value made only of operator characters is an operator's name (`==`, `~=`, `*`) and stays literal, as does a leading `~` where it is Swift (`sig:~Copyable`, `inherits:~Copyable`).
        private func refuseOperatorSyntax(in value: String) throws {
            let operatorCharacters = Set("/=-+!*<>&|^~%.?")
            guard !value.allSatisfy(operatorCharacters.contains) else { return }
            // A `/…/` value on a field that reads a regex is read by `NamePattern`, so what reads as glob or anchor syntax here is the pattern's own.
            guard !readsRegex || NamePattern.regexBody(value) == nil else { return }
            let tildeIsSwift = self == .sig || self == .inherits
            let globAnywhere = self == .sig ? value.hasPrefix("*") || value.hasSuffix("*") : value.contains("*")
            let form: String? = if value.hasPrefix("~"), !tildeIsSwift {
                "a leading ~"
            } else if value.count > 1, value.hasPrefix("/"), value.hasSuffix("/") {
                "a /regex/"
            } else if globAnywhere {
                "a * wildcard"
            } else if value.hasPrefix("^") {
                "a leading ^"
            } else if value.hasSuffix("$") {
                "a trailing $"
            } else {
                nil
            }
            guard let form else { return }
            throw EngineError.malformedQuery("\"\(rawValue):\(value)\" uses \(form), which search does not read as a pattern — \(matchingSyntax); \(StructuralQuery.usage)")
        }

        /// Rejects values that could never match, so a typo fails at parse time rather than returning a confident zero.
        func validate(value: String) throws {
            try refuseOperatorSyntax(in: value)
            switch self {
            case .kind:
                // Not every `SymbolKind` the store holds is one `StructuralMatcher` walks — validating against the narrower list it actually supports keeps a wrong or not-yet-covered spelling from silently answering "no declarations match".
                guard StructuralMatcher.supportedKinds.contains(value) else {
                    if StructuralQuery.statementKeywords.contains(value) {
                        throw EngineError.malformedQuery("unknown kind \"\(value)\" — \(value) is a statement, not a declaration, so no kind: finds one; for a name used inside a body, search uses:<name> (any identifier) or calls:<name> (a call)")
                    }
                    throw EngineError.malformedQuery("unknown kind \"\(value)\" — kinds: " + StructuralMatcher.supportedKinds.joined(separator: " "))
                }
            case .has:
                guard StructuralQuery.Shape(rawValue: value) != nil else {
                    throw EngineError.malformedQuery("unknown shape \"\(value)\" — shapes: " + StructuralQuery.Shape.allCases.map(\.rawValue).joined(separator: " "))
                }
            case .effect:
                guard value == "async" || value == "throws" else {
                    throw EngineError.malformedQuery("unknown effect \"\(value)\" — effects: async throws")
                }
            case .attr, .name, .calls, .uses, .inherits, .modifier, .sig, .imports, .path, .owner:
                break
            }
        }
    }

    /// Swift's statement keywords: asked for under `kind:`, each is refused with the reason rather than the kinds list, since no declaration kind is one.
    internal static let statementKeywords: Set<String> = ["switch", "if", "guard", "for", "while", "repeat", "do", "catch", "defer", "return", "throw"]

    /// The shapes `has:` can ask about — a curated set, because an open-ended node vocabulary would be a grammar to learn rather than a line to write.
    enum Shape: String, Sendable, CaseIterable {
        case closure
        case `await`
        case `try`
        case forceUnwrap
        case forceTry
        case forceCast
        case optionalChain
    }
}
