//
// Copyright © Agulhas Labs
//

import Foundation

/// Whether a search asks for something no index call would have served — text the index does not record (a version literal, a phrase from a comment, a line count), or an answer the index holds but could only give back for more round trips than the search itself costs.
///
/// **The two halves are one question for the hook, which does one thing with either answer: it withholds. They are not one number.** Most of these rules are about what the index *records* — a count, a merge's markers, a tree no index holds, a fixed string, a literal, prose, a pattern no name could be. Two are about what an index answer is *worth* against the command it would replace: a grep of one file printing context no index answer accounts for, and an alternation of names confined to files it lists. Each was measured costing a turn and buying nothing: the agent read the refusal, learned nothing it could use, and re-ran the identical command. A nudge that is re-run is a nudge that was wrong, whichever half of the question made it so — but a lookup the index lost because its answer was judged not worth winning is not a lookup the index never owed, so ``Reason/withholding`` carries which half a rule belongs to and a report counts the second half on a line of its own.
///
/// **One definition because two ends have to reach the same verdict, and when they do not the number this tool exists to make honest is the thing that breaks.** The hook decides whether to refuse; ``TranscriptScan`` decides whether the search counted against the index. A search the hook silently declines to claim it could serve, still counted as a lookup the index lost, lowers the reported share for commands the tool has just judged unanswerable — saying so in one place while counting it in the other makes the share an argument with itself (`PreToolUseCommand.lookup`). ``AdvisableName`` is the other half of the same rule, and it holds because both ends ask the same predicate; this is that discipline extended to the judgements it does not cover.
///
/// It is asked of both search surfaces, because which one a caller reaches for cannot change the answer: `grep -c` and `Grep(output_mode: "count")` are one question, and a refusal on one surface that is silent on the other teaches a detour rather than a habit.
///
/// Every rule errs the same way, and deliberately. A withheld nudge costs one missed opportunity; a nudge that fires wrongly costs a doubled invocation and the credibility of the next one — and measured, it was not a hypothetical: of 163 refusals standing alone in their turn over four days, 75 were followed by the identical call re-run, each a whole context's round trip bought for nothing, because what the command asked for was prose, a literal, a merge's markers, or a tree no index holds.
public struct TextSearch {
    /// Whether this is such a search, by the two rules this began with.
    ///
    /// **A count** asks how *much* text there is, and volume is the one thing a symbol index does not measure. Where the file's Swift lives inside string literals — a lint rule's fixtures — a `digest` in its place resolves declarations, of which there are fewer, because a declaration in a string literal is characters rather than a declaration: a different number, not the same number more cheaply.
    ///
    /// **A search with no one file behind it and a pattern that names nothing at all** — no identifier anywhere in it, of any kind. `grep -rn "0\.1\.0" Sources --include=*.swift` hunts a version literal and `grep -rn "2026-09"` a date; the index records neither, so the bare `search` offered in their place is a call that cannot answer.
    ///
    /// **The bar is "names nothing", and not "names no *symbol*", which is a much wider net and the wrong one.** `final class`, `@Test func`, `some View` name no symbol either, and they are the patterns `search` serves best — declarations by shape is the whole of what it does. A rule drawn at the symbol would have silenced the tool's own flagship case. What is left once Swift's vocabulary is admitted is text: literals, dates, punctuation, prose.
    ///
    /// **A pattern that does name something is somebody else's judgement, made elsewhere.** Where the advice stands on a symbol, `AdvisableName` asks whether any index this machine knows declares it and withholds when none does — through the same predicate the scan uses, which is why those two agree. A sweep for `revisit this later` is that rule's case and not this one's; adding a second answer to a question already answered is how two ends stop agreeing.
    ///
    /// Where one file *is* named a pattern naming nothing is still refused with the file's digest: `grep -n '1\.0' Depot.swift` asks where in that file a literal stands, and the digest locates the members it could stand in. What one file does not rescue is prose, which ``reason(for:)`` takes.
    public static func describes(patternNamesNothing: Bool, file: String?, counting: Bool) -> Bool {
        if counting {
            return true
        }
        return file == nil && patternNamesNothing
    }

    /// The rule that declares `search` one the index could not have served, or `nil` where none does.
    ///
    /// **Each rule is a shape whose output no index answer could stand in for, whatever the call is pointed at**, and each was a shape refusals were measured buying nothing on — the identical call re-run straight after. They are checked in the order this rule needs, which is not the order `TranscriptScan.classify` names a refusal's shape for `sift audit` in: that one puts `anotherRevision` second, has no string-literal shape of its own, does not read `=======` as a conflict marker at all, and calls any pattern holding a space a phrase outright. The two orders answer different questions and are not obliged to agree:
    ///
    /// - **A merge's markers** — no index records an unresolved conflict.
    /// - **A tree no index holds** — build output, a dependency's checkout, a scratch file under `/tmp` (``SwiftTree/isOutsideIndexedSources(_:)``). Every path must be one: a sweep of `Sources` and `.build` beside it still searches source the index holds.
    /// - **A fixed string that is not a name** — `grep -F 'stock('` is those characters, where the pattern readers here would take a regex, and read `.cache` as the name `cache`. A fixed string that *is* a name is the same search as the name's own, and is left to be refused as one, since its answer is the same `where`.
    /// - **A string literal** — any pattern holding a `"`. `grep -rn -e '"\.cache'` was refused with `where cache`, a declaration nobody asked about, and re-run. Judged over every `-e` pattern rather than the first, because several patterns are one search and the literal can stand anywhere among them.
    /// - **Prose on one file** — the rule that overturns the one this began with, which said that where one file is named "the file is the answer whatever the pattern turns out to be". For declarations that holds, and a grep of one file for its declarations is still that file's digest, answered in place where the shape is proven (``InPlaceShape``). But a digest records neither comments, nor string literals, nor the text of a call site, so for `grep -n "stale gate is open" Depot.swift`, `grep -n "MARK: - Loading"`, a search for a `//` comment's marker, or `grep -n "stock: stock(item, level:"` the digest it offered was never the answer. A pattern is prose where any alternative holds a comment marker, or whitespace between words without opening on a declaration's form (``InPlaceShape/opensADeclaration(_:)``) — the form being what tells `func save(_ value: Int)` from `return save(value)`. Across a tree the same phrase is ``SweepPattern``'s to read, which answers the names of an alternation carrying a prose branch and names the prose as left to a search.
    /// - **A pattern that could not be a name** (``cannotBeAName(_:)``), which is the rest of the space prose leaves: flag text, a quoted fragment, a regex wildcard between two words. The advisor reads a name out of any of them and offers `digest <File>.<word>` for a word the pattern never asked about on its own.
    /// - **A reading stage whose output a later stage filters** — `grep -rn InPlaceShape Sources | sort -u`, `cat View.swift | grep -n stock | head -5`, `grep -rn conflictMarker Sources | cut -d: -f1`. What reaches the terminal is what the filter kept of the lines the read printed, and no index answer prints those lines: a `where`'s resolved sites and a digest's declarations are neither the text the filter cut nor the order it sorted. A stage that only passes the lines on is the exception and not a filter at all (``ShellQuery/passesOnWhatItIsHanded``) — `| head -20` prints the first lines of the very answer the refusal offers, which is why ``InPlaceShape`` answers that pipeline in place instead (`ShellGrep.Cut`), and `| cat`, `| less` and `| head -20 > out.txt` print that answer whole or window it into a file. This rule is last, so it takes only what the rules above it left and never relabels one of their withholdings as its own; a search whose pattern is a literal is logged as the literal it hunts, piped or not.
    /// - **Context lines around the matches in one named file, where the pattern is not a member's declaration** — `grep -n "matchedLines" -A8 ShellGrep.swift` is the ranged read this tool's own guidance asks for *after* a digest, spelled at the shell. `where` gives the location and `digest` the shape; neither gives the eight lines, so the digest offered here only ever arrives a turn before the identical re-run. **A member's declaration is the one context grep with a better outcome available than silence**, and the rule stands aside for it: ``InPlaceShape/grepCall(_:cut:literal:)`` runs `grep -n "func matchedLines" -A8 ShellGrep.swift` and hands the member's source back in the refusal's place, one round trip, because the member's source accounts for every line the context prints. Withholding there would delete an answer rather than a useless nudge.
    /// - **An alternation of two or more names, confined to files the search names** — `grep -n "waitForExit\|temporaryLog" RunLauncher.swift`. Naming one file draws that file's shape, a bare `digest <File>`, which locates neither branch's sites: strictly weaker than the per-name `where` a tree-wide sweep would offer, and weaker than the `digest <File>.<member>` a one-name grep of that file already gets. Withholding an answer poorer than the one measured as buying nothing is this hook's own error bias. A recursive sweep of the same alternation keeps its nudge: there the names' resolved sites genuinely beat a raw sweep of the tree, which is the case `where` exists for. A name beside a prose branch is withheld here by the same rule: the answer that sweep is given, the names' sites and a line naming the prose it leaves out, is an answer for a tree and not for the files named.
    /// - **A search printing only the names of the files it matches**, asked last of all, so it takes only what every rule above left a lookup — `grep -rlw InPlaceShape Sources`, or a `Grep` in its default `files_with_matches` mode. The list is the smallest answer to "which files", and it holds the files whose only mention is a comment or a string, which no index records; a `where` in its place is neither what the search prints nor smaller than it.
    static func reason(for search: Search) -> Reason? {
        if search.counting {
            return .textSearch
        }
        let patterns = search.patterns ?? []
        if patterns.contains(where: { $0.contains(conflictMarker) }) {
            return .conflictMarkers
        }
        if search.outsideIndexedSources {
            return .outsideSources
        }
        if search.fixedStrings, !patterns.allSatisfy(IndexSuggestion.isName) {
            return .fixedString
        }
        if patterns.contains(where: { $0.contains("\"") }) {
            return .stringLiteral
        }
        if search.file != nil, patterns.contains(where: isProse) {
            return .phrase
        }
        if search.file != nil, patterns.contains(where: cannotBeAName) {
            return .notAName
        }
        if search.file != nil, search.printsContext, !patterns.contains(where: declaresAMember) {
            return .contextLines
        }
        if search.confinedToNamedFiles, patterns.contains(where: { alternatesBetweenNames($0) || SweepPattern.reading(of: $0).isPartial }) {
            return .severalNames
        }
        if search.outputIsFiltered {
            return .filteredOutput
        }
        guard let patterns = search.patterns else { return nil }
        let namesNothing = patterns.first.map(PatternReading.namesNothing) ?? true
        if describes(patternNamesNothing: namesNothing, file: search.file, counting: false) {
            return .textSearch
        }
        return search.listsFiles ? .filesOnly : nil
    }

    /// Whether `search`, confined to one named file, asks for text no declaration or name could be: the tree form's own last rule (``describes(patternNamesNothing:file:counting:)``) asked of every pattern as if no file were named.
    ///
    /// **Asked by `sift audit` alone, and never by the hook**, which still puts such a grep to its in-place answerer and lets it through where no answer is exact. What changes is the accounting: `grep -n "0\.1\.0" Depot.swift` hunts a literal no digest records, exactly as `grep -rn "0\.1\.0" Sources` does, and counting the one-file form as a lookup the index lost made the share an argument with the rule the tree form is scored by.
    ///
    /// A pattern with a declaration's reading (``InPlaceShape/declarationReading(of:patternWasQuoted:)``) is left a lookup, however little it names: a column-0 `^}` is the ends of the file's top-level declarations, which the hook answers in place from the digest, and a lookup the hook can answer is never one the index did not owe. Every pattern has to name nothing, so one name among several `-e` patterns keeps the search a lookup.
    ///
    /// **A pattern that matches every line is a whole read wearing a search's clothes.** `grep -n '^' F`, `grep -n . F`, `grep -n '$' F`, `grep -n '^.*' F` and a bare `''` all print the file's every line, exactly as `cat -n F` does — the hook proves that shape and answers it in place — so counting it as a text search this rule scores out of the denominator would drop a whole read the index served from the population it is served against. **An inverted search is left alone entirely**, whatever its pattern, since what a `-v` prints depends on the file's own lines and not on the pattern read in isolation: `grep -vn '^$' F` prints every non-blank line, a whole read in the same clothes, and a pattern this rule would otherwise wave through — a name, a declaration's shape — inverted still selects by what the file holds rather than by what the pattern names.
    static func namesNothingInOneFile(_ search: Search) -> Bool {
        guard search.file != nil, !search.counting, !search.inverted, let patterns = search.patterns, !patterns.isEmpty else { return false }
        return patterns.allSatisfy { pattern in
            describes(patternNamesNothing: PatternReading.namesNothing(in: pattern), file: nil, counting: false)
                && InPlaceShape.declarationReading(of: pattern, patternWasQuoted: true) == nil
                && !matchesEveryLine(pattern)
        }
    }

    /// Whether `pattern` matches every line of any file it is run on: `''`, `^`, `$`, `.`, `.*`, `^.*` — the shapes a whole read is spelled as a search, whatever the file holds.
    private static func matchesEveryLine(_ pattern: String) -> Bool {
        let raw = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return ["", "^", "$", ".", ".*", "^.*"].contains(raw)
    }

    /// The rule that declares a whole read of `path` one the index could not have served: outside the indexed sources, or `nil`.
    ///
    /// Asked by the hook of a whole-file `Read` and by the scan of the same read, so a read the hook lets through is never counted as a miss for it. `cwd` is the call's own working directory — the hook's payload carries one, and the scan reads it off the transcript entry for the same call — and narrows ``SwiftTree/isOutsideIndexedSources(_:)`` the same way it does there.
    public static func reason(forWholeRead path: String, cwd: String? = nil) -> Reason? {
        SwiftTree.isOutsideIndexedSources(path, relativeTo: cwd) ? .outsideSources : nil
    }

    /// Whether `pattern` could not be the name a lookup stands on, whatever else it is.
    ///
    /// Four marks, each of which no Swift name carries, and each measured on a refusal the agent answered by re-running the identical command:
    ///
    /// - **It opens on a `-`** — `grep -n -e "--only" HelpTopics.swift` hunts the flag's text, and was refused with `digest HelpTopics.only`, a member of nothing.
    /// - **It holds a quote** — `'` here, since a `"` is the string literal ``Reason/stringLiteral`` already claims, and a word carrying an apostrophe is prose in any language.
    /// - **It holds *literal* whitespace no declaration's form explains, wherever that whitespace falls.** ``isProse(_:)`` asks for whitespace *between two words*, which `"  --only "` does not have and `grep -n -- "  --only "` was refused for; `func save` and `^\s*static let` still open on a declaration and stay the lookups they are (``InPlaceShape/opensADeclaration(_:)``). An *escaped* spelling of whitespace is left standing as a name: `grep -n "isProse\s*("` is the canonical way to grep for one function, and reading that `\s` as the space it matches disqualified the very shape the rule exists to leave alone. The case this mark was drawn from is flag text padded with spaces, and padding is a literal space or nothing. `[[:space:]]` is the exception among the spellings and stays in, because it is itself a word: the offer built from `save[[:space:]]*(` is `digest <File>.space`, the member nobody asked about that this whole rule is about.
    /// - **An unescaped `.` between two lowercase words** — `tab.about` is a regex, and the advisor read `about` out of it as the member to digest. A capitalised left side is a member's dotted path (`Depot.pending`) and an escaped `\.` a literal dot; both are left alone. Whether the name a *genuine* dotted path stands on is one any index declares is asked downstream, of the name itself (`AdvisableName`), and is not this rule's to repeat.
    ///
    /// **Asked of a search confined to one file and never of a sweep**, which is the rule and not an oversight: across a tree the offer is a `where` for the name the pattern carries, and punctuation around a name is how code is written — `: order`, `order {`, `Überblick.größe` are the sweeps that offer resolves (``SweepPattern/codePunctuation``), where on one file the same marks make `digest <File>.order` a member nobody asked about.
    private static func cannotBeAName(_ pattern: String) -> Bool {
        let raw = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if raw.hasPrefix("-") || raw.contains("'") || raw.contains(wildcardDot) {
            return true
        }
        let spaced = raw.replacing(spaceClassWord, with: " ")
        return spaced.contains(where: \.isWhitespace) && !InPlaceShape.opensADeclaration(raw)
    }

    /// Whether `pattern` reads as a member's declaration, whose source the hook hands back in the refusal's place even with context printed around it.
    ///
    /// Asked of the pattern alone rather than of the whole call, because the answer has to hold on both search surfaces and only one of them has a shell command to read. ``InPlaceShape/grepCall(_:cut:literal:)`` decides the rest — one Swift file named outright, no flag that leaves the shape — and where it declines there is nothing for this rule to stand aside for.
    private static func declaresAMember(_ pattern: String) -> Bool {
        if case .member = InPlaceShape.declarationReading(of: pattern) {
            return true
        }
        return false
    }

    /// Whether `pattern` alternates between two or more names, each of which `where` would be asked for on its own.
    ///
    /// Read through ``SweepPattern``, which is what builds the offer this rule is about, so the count the rule turns on is the count the refusal would have listed. A comma list of the same names is not an alternation and is not read as one: `UsageWindow, CatalogueStore` is a literal adjacency a search tool looks for, which no `where` answers, and the alternation is what a shell search actually carries.
    ///
    /// Asked by the classifier too (``PatternReading/namesOnly(_:)``, through ``PatternReading/answeredByOneCall(_:)``), where it decides the opposite thing: that a sweep of a directory *is* a lookup. The two uses are one question — "is this pattern several names?" — and answering it in one place is what keeps a shape from being classified by one reading and withheld by another.
    static func alternatesBetweenNames(_ pattern: String) -> Bool {
        let raw = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard raw.contains(alternation), case let .names(names) = SweepPattern.reading(of: raw) else { return false }
        return names.count >= 2
    }

    /// Whether any alternative of `pattern` is prose: a comment marker, or whitespace between words that does not open on a declaration's form.
    private static func isProse(_ pattern: String) -> Bool {
        let raw = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return raw.split(separator: alternation, omittingEmptySubsequences: false).contains { alternative in
            let text = String(alternative)
            if text.contains(commentMarker) {
                return true
            }
            return text.replacing(whitespaceClass, with: " ").contains(wordsApart) && !InPlaceShape.opensADeclaration(text)
        }
    }

    /// Seven of a merge's marker characters in a row — `<<<<<<<`, `=======`, `>>>>>>>`.
    nonisolated(unsafe) private static let conflictMarker = /<{7}|={7}|>{7}/

    /// A comment's opening, or one of the markers written inside one.
    nonisolated(unsafe) private static let commentMarker = /\/\/|\/\*|\b(?:MARK|TODO|FIXME)\b/

    /// A regex's spelling of whitespace — `\s`, `[[:space:]]`, `\t` — which separates words as a space does.
    ///
    /// Read that way by ``isProse(_:)``, which is asking what the pattern *matches*.
    nonisolated(unsafe) private static let whitespaceClass = /\\[st]|\[\[:space:\]\]/

    /// The one of those spellings that is itself a word, which is a different question and the one ``cannotBeAName(_:)`` asks.
    ///
    /// `[[:space:]]` puts `space` in the pattern where a name reader looks for one, and the offer built from `save[[:space:]]*(` is `digest <File>.space` — a member nobody asked about, which is what that rule exists to catch. `\s` and `\t` carry no word at all, so they are left standing as part of the name beside them.
    nonisolated(unsafe) private static let spaceClassWord = /\[\[:space:\]\]/

    /// A word, then whitespace, then another word, with anything between.
    nonisolated(unsafe) private static let wordsApart = /[\p{L}\p{N}_].*\s.*[\p{L}\p{N}_]/

    /// `|` in an extended pattern, `\|` in a basic one — the alternation ``SweepPattern`` splits a sweep on.
    nonisolated(unsafe) private static let alternation = /\\?\|/

    /// A `.` standing between two lowercase letters — `tab.about` — which is a regex's any-character rather than a member's dot; an escaped `\.` has the backslash in that place and never matches.
    nonisolated(unsafe) private static let wildcardDot = /\p{Ll}\.\p{Ll}/
}

public extension TextSearch {
    /// Which rule declared a search one the index could not have served: the name the hook logs its withholding under (`SuppressionLog`), and one verdict whichever it is to the scan, which scores every one of them out of the share.
    enum Reason: String, Sendable, Equatable, CaseIterable {
        /// A count, or a search over no one file whose pattern names nothing at all — the two rules this began with, logged under their first name.
        case textSearch
        /// A pattern hunting an unresolved merge's `<<<<<<<`, `=======` or `>>>>>>>`.
        case conflictMarkers
        /// Every path the call names lies outside the indexed sources (``SwiftTree/isOutsideIndexedSources(_:)``).
        case outsideSources
        /// A fixed-string search for anything but a name.
        case fixedString
        /// A pattern holding a `"`, which is a string literal's text.
        case stringLiteral
        /// A search of one file for prose, a comment marker or a call site.
        case phrase
        /// A search of one file for a pattern no Swift name could be — flag text, a quote, literal whitespace no declaration explains, a regex's wildcard dot.
        case notAName
        /// A search of one named file printing context around its matches, where the pattern is not a member's declaration: the ranged read a digest is meant to lead to.
        ///
        /// The index does answer, with the file's digest — but a digest gives declaration ranges, never the lines around an arbitrary match, so the answer does not settle what was asked and is not worth the round trip it costs.
        case contextLines
        /// A search of the files it names for an alternation of two or more names, or of names beside prose.
        ///
        /// The index does answer, with the named file's own shape — but that shape locates no individual branch's sites, so the answer is too weak to be worth the round trip it costs.
        case severalNames

        /// A read or search whose output a later stage of the same pipeline filters — a `sort`, a `cut`, a second `grep` — rather than windowing it.
        ///
        /// The pattern here is often a name the index does declare — `grep -rn InPlaceShape Sources | sort -u` is `InPlaceShape`'s own sites, which `where` resolves — so this is not a search the index fails to record. What defeats it is the pipeline: a `sort`, a `cut`, a second `grep` asks for exactly which lines a downstream stage kept and in what order, and no index answer prints those lines for it to keep. That is the same shape as ``contextLines`` — an answer the index could give, weaker than the one the command asks for — and the same half. A stage that passes the lines on unchanged is not this (``ShellQuery/passesOnWhatItIsHanded``): a window prints the opening of the very answer the refusal offers, which ``InPlaceShape`` hands back in place, and a `cat`, a pager or a redirect to a file prints that answer whole.
        case filteredOutput

        /// A search printing only the names of the files it matches, or of those it does not — `grep -l`, `rg --files-with-matches`, a `Grep` in `files_with_matches` mode.
        ///
        /// The index records the name and could answer with its sites, but those are neither the list the search prints nor smaller than it, and they leave out every file whose only mention is a comment or a string.
        case filesOnly

        /// What, in this rule, the index does not record — or `nil` where the index does record it and the rule is the other half's.
        ///
        /// Exhaustive rather than defaulted, and the one switch: ``withholding`` is read off it, so a rule added later cannot join either half, or either cause, by omission.
        var cause: Cause? {
            switch self {
            case .textSearch, .conflictMarkers, .fixedString, .stringLiteral, .phrase, .notAName:
                .patternNamesNothing
            case .outsideSources:
                .unnameableFile
            case .contextLines, .severalNames, .filteredOutput, .filesOnly:
                nil
            }
        }

        /// Which half of the question this rule belongs to: a rule naming a cause is one the index does not record, and a rule naming none is one it records and could answer.
        var withholding: Withholding {
            cause == nil ? .notWorthTheRoundTrips : .notRecorded
        }

        /// Which rule of the not-worth-the-round-trips half this is, for the reasons that carry one — `nil` for every reason `cause` already claims.
        ///
        /// The complement of ``cause``, read off the same switch for the same reason: a rule added to this half later must be added here too, or it silently loses its own line and folds into no report at all.
        var rule: Rule? {
            switch self {
            case .textSearch, .conflictMarkers, .fixedString, .stringLiteral, .phrase, .notAName, .outsideSources:
                nil
            case .contextLines:
                .contextLines
            case .severalNames:
                .severalNames
            case .filteredOutput:
                .filteredOutput
            case .filesOnly:
                .filesOnly
            }
        }
    }

    /// Why a withheld lookup was one the index never recorded — the first half of ``Withholding``, split by what was missing.
    ///
    /// **One row saying how many lookups the index could not serve cannot answer what to do about them**, because the three causes argue for three different things and only one of them is about the tool's own scope. A pattern naming nothing the index records — a count, a literal, a merge's markers, the text of a comment — is the case for recording more than declarations; a name no index declares is a miss of *reach*, an index that does not cover the tree the lookup was about; a file no call can name is a path problem and neither. Pooled, they read as one number that could be argued down by whichever cause the reader had in mind.
    ///
    /// ``TextSearch/Reason/filteredOutput`` names no cause here at all (``Reason/cause``): its pattern is often a perfectly good name the index does declare — `grep -rn InPlaceShape Sources | sort -u` withholds on a pipeline whose output `sort -u` filters, and the index does record `InPlaceShape`, whose sites `where` resolves. What defeats it is not a gap in what the index records but the pipeline asking for lines no index answer prints, which is why it stands with ``contextLines`` and ``severalNames`` in the other half instead of taking a fourth cause here.
    enum Cause: String, Sendable, Equatable, Codable, CaseIterable {
        /// The pattern names nothing the index records: a count, a merge's markers, a fixed string, a string literal, prose, a pattern no Swift name could be, or a sweep the advisor could name no call for.
        case patternNamesNothing
        /// The name the advice would have stood on is declared by no index this machine knows, so `where` would answer "no symbol named …".
        case undeclaredName
        /// No index call can name the file: a tree no index holds, or a path `digest` takes no argument for.
        case unnameableFile
        /// A search of one named file whose pattern names nothing a declaration could be — counted by `sift audit` alone (``TextSearch/namesNothingInOneFile(_:)``), and apart from ``patternNamesNothing`` so the report can say what the share read before it was.
        case patternInOneFile
    }

    /// Which half of the question a rule belongs to — and so which count it may be added to.
    ///
    /// The hook does one thing with either answer, so this changes nothing about what is withheld. It changes what may be *pooled*. A search the index never recorded is a lookup the index never owed, and scoring it out of the share is the tool being honest about its own reach. A search the index could have answered, withheld because the answer would cost more round trips than the command it replaces, is a lookup the index lost on a judgement of worth — and folding that into the same total lets the share improve by redefinition, the number keeping its name and its report line while its meaning changes underneath.
    ///
    /// Read off ``Reason/cause``, which is exhaustive rather than defaulted, so a rule added later cannot join the first half by omission: which half it belongs to is the decision worth stopping on, and naming the cause is how that decision is written down.
    enum Withholding: String, Sendable, Equatable, CaseIterable {
        /// The index does not record what the search asks for, so no index call could have served it.
        case notRecorded
        /// The index records it, and could answer — for more round trips than the command it would replace.
        case notWorthTheRoundTrips
    }

    /// Why a withheld lookup was one the index owned and lost on a judgement of worth — the second half of ``Withholding``, split by what made the answer not worth asking for.
    ///
    /// **The same reasoning ``Cause`` gives the other half.** A pooled row saying how many lookups cost more round trips than they were worth cannot say what to fix, because the rules argue for different things: `contextLines` and `severalNames` are both the index giving a weaker answer than was asked for, `filteredOutput` is a pipeline asking for lines no index answer prints, and `retryAllowed` is neither — it is a call the hook already refused once, and whose identical re-run it then let through, so there is no in-place answer to weigh at all. Pooled, they read as one number a reader could argue down by whichever fix they had in mind, exactly as an unsplit `textSearches` once could.
    ///
    /// `contextLines`, `severalNames`, `filteredOutput` and `filesOnly` mirror ``Reason``'s own cases of the same name and are read off them (``Reason/rule``). `retryAllowed` names no ``Reason`` at all: it is decided from the advice ledger — whether the hook refused this exact call before and let its re-run stand — which a rule over one search's shape has no way to see, so it is chosen at the point that ledger is consulted (`WithholdingLookup.lookup(key:suggestion:search:denied:couldAnswerHere:consultFilesystem:)`) rather than read off a `Reason`.
    enum Rule: String, Sendable, Equatable, Codable, CaseIterable {
        /// A search of one named file printing context around its matches, where the pattern is not a member's declaration.
        case contextLines
        /// A search of the files it names for an alternation of two or more names — including one where the index declares some but not all of them, and answering it is still the one command the alternation itself is.
        case severalNames
        /// A read or search whose output a later stage of the same pipeline filters.
        case filteredOutput
        /// A search printing only the names of the files it matches, whose list no index answer is or undercuts.
        case filesOnly
        /// A name search of the Swift files it names outright, which the hook lets run: a `where` lists the name's sites across the whole tree, and no answer scoped to the files the search named stands in for what it prints.
        case namedFiles
        /// A lookup the hook refused, whose identical re-run it then allowed — the refusal already named the way through, so taking it is no miss.
        case retryAllowed
        /// A read the hook let run — a line window or a whole file — because no index answer was smaller than what it prints, read off the hook's own logged verdict for that call.
        case notSmaller
        /// A window the hook let run because its answer would not show the lines asked for — a declaration's leading doc comment, or a saving under the floor — read off the hook's own logged verdict for that call.
        case linesNotShown
        /// A whole read of a Swift file the hook let run because its digest spares less than the turn after it costs (``WholeReadWorth``), read off the hook's own logged verdict for that call.
        case notWorthTheTurn

        /// The rule a withholding the hook logs is a judgement of worth under, or `nil` for one that is not.
        init?(loggedAs why: InPlaceAnswerer.Withholding) {
            switch why {
            case .notSmaller: self = .notSmaller
            case .linesNotShown: self = .linesNotShown
            case .notWorthTheTurn: self = .notWorthTheTurn
            default: return nil
            }
        }
    }
}

extension TextSearch {
    /// A search as either surface carries it, read into the facts these rules decide on.
    struct Search {
        /// Whether it asks how many rather than which.
        var counting: Bool
        /// The one Swift file it is confined to, or `nil` where it sweeps.
        var file: String?
        /// Every pattern it applies — each `-e` of a shell search, or the one it was handed — and `nil` for a read that takes none, such as `cat`.
        var patterns: [String]?
        /// Whether its patterns are literal strings rather than expressions (`grep -F`, `fgrep`).
        var fixedStrings = false
        /// Whether every path it names lies outside the indexed sources.
        var outsideIndexedSources = false
        /// Whether it prints the lines around each match — `-A`, `-B`, `-C`.
        var printsContext = false
        /// Whether it is pointed at the Swift files or globs it names outright rather than walking a tree.
        ///
        /// Wider than ``file``, which is the *one* file a search is confined to: two files named on the command line, or a `Sources/Kit/*.swift` the shell expands, are just as much a search the caller has already narrowed by hand.
        var confinedToNamedFiles = false
        /// Whether a later stage of the pipeline the read sits in filters what it printed, rather than windowing it (``ShellQuery/windowsWhatItIsHanded``).
        ///
        /// Only the shell can carry one: a `Grep` or `Read` call is a call and has nothing downstream of it, so that surface leaves this alone and the two still agree about every search either of them can express.
        var outputIsFiltered = false
        /// Whether the search inverts its match, printing the lines that do not hold the pattern — `-v`, `--invert-match`.
        ///
        /// Only the shell can carry one: the `Grep` tool has no such flag, so that surface leaves this at its default and a search of one named file that inverts its match is never mistaken there for a lookup this rule owes nothing to.
        var inverted = false
        /// Whether it prints only the names of the files it matches, or of those it does not, rather than any line of them — `-l`, `-L`, `--files-with-matches`, a `Grep` in `files_with_matches` mode.
        var listsFiles = false
    }
}
