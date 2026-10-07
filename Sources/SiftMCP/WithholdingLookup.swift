//
// Copyright © Agulhas Labs
//

import Foundation

/// How the transcript scan scores a search the tool itself has already said it could not serve, rather than as cold.
struct WithholdingLookup {
    /// The withheld lookup this is, if the tool itself has already said it could not serve the search — otherwise `nil`, and the caller scores it cold.
    ///
    /// **Which of the two counts it may be added to is settled here and never by the caller** (``TextSearch/Withholding``), and so is which cause within the first of them (``TextSearch/Cause``) — the three ways below already tell the causes apart in order to withhold, so the report reads the split off this decision rather than making it a second time. A rule of ``TextSearch/Reason`` carries its own half and its own cause already. A lookup the advisor could name no call for is the first half — a withholding on worth weighs an answer's round trips against the command, and where no call can be named there is no answer to weigh. The refusal whose re-run the hook allowed, and the alternation only part of whose names the index declares, are both the second: a call was named, the index records what they ask for, and what was weighed was the cost of asking it.
    ///
    /// Three ways the tool says so, and they are one rule seen from either end. **The advisor declared the question unanswerable** — a count, or a search over no one file whose pattern is not a name (``TextSearch``), or a lookup it could name no call for at all (``IndexSuggestion/namesATarget``), asked here through the same predicates the hook gates on, because a search silenced in one place and counted in the other makes the share an argument with itself. Or the hook **refused this exact search before**, which by `AdviceLedger.decide` means it allowed this one: the refusal named the re-run as the way through, and scoring the offer being taken as defiance is the mistake the ledger is built not to make. Or **no index this machine knows declares the name** the advice would have stood on (`AdvisableName`) — `where` would answer "no symbol named …", so this is a search for text the index does not record, which is what a text search is.
    ///
    /// The first of the three consults no index — it reads the command, and the tree the command points at, exactly as the classification beside it does. So, like the second, it holds during a quiet spell and with advice switched off entirely; and outside a `--since` window it narrows with everything else, because the directory is withheld there and the reading falls back to the command's own text.
    ///
    /// The second test is about the name and not about the hook: it holds during a quiet spell and with advice switched off entirely, which is deliberate — a grep for a word that lives only in string literals is a legitimate grep whether or not anything was awake to say so.
    ///
    /// It is also answered *now* rather than when the transcript was written, and the index moves in between: a symbol deleted since rescores an old cold search as a text search, one added since rounds the other way. Accepted rather than fixed — the transcript records no index state, so the alternative is not a better answer but no answer — and it is bounded by being a question about names, which change far more slowly than the lines around them.
    ///
    /// The filesystem half is skipped outside a `--since` window, along with every other probe: the classification is discarded there and an audit would otherwise open an index per search across a week of transcripts to throw the answer away.
    ///
    /// Where the advice is one `where` per name of an alternation (``IndexSuggestion/isOneCallPerName``) it is withheld unless every one of those names is declared, which is exactly when the hook offers it: an ask of N names the index can speak for fewer of is withheld there rather than narrowed, so counting it here as a lookup the index lost would make the share an argument with the hook again.
    ///
    /// Any other advice standing on several names is one file's digest, which answers for the file whatever the names are, so one declared name among them keeps it at both ends.
    static func lookup(
        key: String,
        suggestion: IndexSuggestion?,
        search: TextSearch.Search?,
        denied: Set<String>,
        couldAnswerHere: (String) -> Bool,
        consultFilesystem: Bool
    ) -> SwiftLookup? {
        if let reason = search.flatMap(TextSearch.reason(for:)) {
            return SwiftLookup(withheld: reason)
        }
        // An advisor that can name no call at all names no answer either, and a withholding on worth
        // weighs an answer's round trips against the command it would replace. There is nothing here to
        // weigh: the reach is empty, so this is a lookup the index never owed rather than one it lost.
        // Counted with the patterns: what leaves no call to name is what the pattern turned out to be —
        // a regex where a target belongs — and never a name the index was asked about and lacked.
        if suggestion?.namesATarget == false {
            return .textSearch(cause: .patternNamesNothing)
        }
        // Reached only where the advisor did name a call and withheld nothing, so the index records this
        // and could have answered it — the hook refused it on exactly that ground, and the refusal named
        // the re-run as the way through. A lookup the index owned and lost, which is the second half.
        if denied.contains(key) {
            return .withheldOnWorth(rule: .retryAllowed)
        }
        guard consultFilesystem, let suggestion, !suggestion.symbols.isEmpty else { return oneFileText(search) }
        let declared = suggestion.symbols.filter(couldAnswerHere)
        if declared.isEmpty {
            // The pattern did name something, and no index on this machine declares it: a miss of reach
            // rather than of what an index records, which is why it is counted apart from the patterns.
            return .textSearch(cause: .undeclaredName)
        }
        // The names the index does declare it would answer, one call apiece, and the ask is one command:
        // the same arithmetic ``TextSearch/Reason/severalNames`` is withheld on, and so the same half.
        guard suggestion.isOneCallPerName, declared.count < suggestion.symbols.count else { return oneFileText(search) }
        return .withheldOnWorth(rule: .severalNames)
    }

    /// A search nothing withheld, as a text search where it is confined to one file and its pattern names nothing a declaration could be (``TextSearch/namesNothingInOneFile(_:)``), which the tree form of the same search already is, and `nil`, the cold lookup it always was, otherwise.
    ///
    /// Asked last, of what would otherwise be cold, so the lookups it moves are exactly the ones the share counted as misses before, and the report can state that share beside the new one.
    private static func oneFileText(_ search: TextSearch.Search?) -> SwiftLookup? {
        guard let search, TextSearch.namesNothingInOneFile(search) else { return nil }
        return .textSearch(cause: .patternInOneFile)
    }

    /// A name search of several Swift files it names outright that the hook declined to answer, scored as the hook treats it: no answer stands in for it, since a `where` lists the name's sites across the whole tree and not the files the caller scoped the search to.
    ///
    /// Asked of what would otherwise be cold, with the hook's own predicate (``InPlaceShape/namesOnlySwiftFiles(_:)``); `unanswered` is that the hook found no in-place reading of the line, so a member grep it does answer stays a lookup.
    static func namedFiles(of command: String, unanswered: Bool, holdsSource: ((String) -> Bool)?, skipping sanctioned: Set<String>) -> SwiftLookup? {
        guard unanswered, ShellAdvice.searchesNamedSwiftFiles(command, holdsSource: holdsSource, skipping: sanctioned) else { return nil }
        return .withheldOnWorth(rule: .namedFiles)
    }
}
