//
// Copyright © Agulhas Labs
//

import Foundation

/// Whether advice naming a symbol — `where X`, `digest Type.member` — is advice some index could make good on.
///
/// The advice hook consults this before denying a lookup on the strength of a symbol name. A grep whose pattern names nothing any index declares is a search for text the index does not record — a string literal, a word in a comment, a config key — and `where` against it answers "no symbol named …": wrong advice, which costs more than none, because every ignored wrong denial burns the credibility the next correct one spends.
///
/// The judgement errs toward advising. Only a *readable local index that definitively lacks the name everywhere this machine knows* suppresses: an unindexed repository stays advisable (the first query indexes it), a repository whose store exists but never finished a build — an in-place answerer that overran its budget, say — stays advisable the same way (``ReadOnlyIndex/hasUsableIndex(atRoot:)``), a directory outside any repository stays advisable (nothing to consult), and a name declared in any registered sibling root stays advisable (`where` answers it with the cross-root pointer). The accepted miss is a symbol written since the last index — the read-only probe cannot reparse dirty files — which costs one absent nudge and heals on the next real query.
public struct AdvisableName {
    /// Whether `name` is declared — or extended — somewhere a query from `directory` could reach.
    ///
    /// A dotted `name` is judged by its type and its member together, through ``couldAnswer(member:of:from:)``, never as the string it is written as: the probe behind the bare case compares a symbol's own name, which never holds a dot, so asked about `TextSearch.isProse` it answers no about a spelling no index could ever record — suppressing every member offer the advisor builds, including the ones the index holds. That is also the check the advisor itself made before offering the member (`IndexSuggestion.forLookup`), so the gate and the builder judge one offer by one rule.
    ///
    /// `siblingRoots` is injectable for tests; `nil` means the machine's registered roots.
    public static func couldAnswer(_ name: String, from directory: String?, siblingRoots: [String]? = nil) -> Bool {
        couldAnswer(name, from: directory, siblingRoots: siblingRoots, in: RunIndexState())
    }

    /// Whether `member` is declared as a member of `type` somewhere a query from `directory` could reach.
    ///
    /// Unlike ``couldAnswer(_:from:siblingRoots:)`` this is asked of a specific member of a specific type rather than a bare name anywhere: `digest HelpTopics.only` and `where HelpTopics.only` are wrong advice the same way a name no index declares is, and the same "err toward advising" rule applies where there is nothing to consult — an unindexed repository or a directory outside any repository answers `true`, since the offer cannot be shown wrong without something to check it against.
    public static func couldAnswer(member: String, of type: String, from directory: String?) -> Bool {
        couldAnswer(member: member, of: type, from: directory, in: RunIndexState())
    }

    /// A `couldAnswer` that answers each name-and-directory pair once, against the indexes as `state` first read them.
    ///
    /// The hook asks this at most once per command and needs nothing; the transcript scan asks it per Swift-flavoured search, and an audit walks a week of transcripts in which the same handful of symbols are grepped over and over. Each answer costs an index open and a query per registered root, so one memo per pass turns hundreds of those into one per distinct question — and because every question about a root goes through the one connection `state` holds to it, and the registered roots are read once through `state` too, one run never counts some lookups against a store and others against its absence.
    public static func memoised(in state: RunIndexState = RunIndexState()) -> @Sendable (String, String?) -> Bool {
        { name, directory in
            // A newline cannot appear in either half, so the joined key cannot collide the way a
            // separator drawn from the path alphabet could.
            state.name("\(directory ?? "")\n\(name)") { couldAnswer(name, from: directory, siblingRoots: nil, in: state) }
        }
    }

    /// A `couldAnswer(member:of:from:)` that answers each type-member-root triple once, against the indexes as `state` first read them.
    ///
    /// Built the same way ``memoised(in:)`` is, for the same reason: `SearchToolAdvice` and `ShellAdvice` each ask this fresh per call, on both search surfaces the hook nudges and inside every transcript a scan walks, so an audit over a window asks it once per distinct member-shaped search across the whole run rather than once per occurrence. Keyed on the resolved root rather than the raw directory, since two calls from different directories of the same checkout are the same question — which is also where the sharing comes from: an audit's transcripts run from many working directories inside the one repository they are about.
    public static func memoisedMember(in state: RunIndexState = RunIndexState()) -> (String, String, String?) -> Bool {
        { member, type, directory in
            // No directory, or one outside any repository, is answered without caching: `couldAnswer`
            // itself always says so with no root to key on, and there is nothing here worth memoising.
            guard let directory, let root = SessionPrimer.enclosingRepository(of: directory) else {
                return couldAnswer(member: member, of: type, from: directory, in: state)
            }
            // A newline cannot appear in any of the three, so the joined key cannot collide the way a
            // separator drawn from the path alphabet could.
            return state.member("\(root)\n\(type)\n\(member)") { couldAnswer(member: member, of: type, from: directory, in: state) }
        }
    }
}

private extension AdvisableName {
    /// The bare-name question, with every root's store and the registered roots read through `state`.
    static func couldAnswer(_ name: String, from directory: String?, siblingRoots: [String]?, in state: RunIndexState) -> Bool {
        if let dot = name.lastIndex(of: ".") {
            return couldAnswer(
                member: String(name[name.index(after: dot)...]),
                of: String(name[..<dot]),
                from: directory,
                in: state
            )
        }
        guard let directory, let root = SessionPrimer.enclosingRepository(of: directory) else {
            return true
        }
        guard state.isUsable(root) else {
            return true
        }
        // A question the run's connection can no longer read errs toward advising, as a store never there does.
        let local = state.probing(root) { database in
            SiblingIndexProbe.declares(name: name, in: database).flatMap { $0 ? true : SiblingIndexProbe.extends(name: name, in: database) }
        }
        if local != false {
            return true
        }
        // `currentRoots`, never `knownRoots`: this runs inside the hook, concurrently with every session on
        // the machine, and the pruning read rewrites the registry — a hook racing a `record` would drop it.
        // The local-root filter is an optimization, not a guard — re-probing it re-asks what the line above
        // answered, so a symlinked spelling slipping past costs one wasted query, nothing more.
        return (siblingRoots ?? state.registeredRoots)
            .filter { $0 != root }
            .contains { sibling in state.probing(sibling) { SiblingIndexProbe.declares(name: name, in: $0) } != false }
    }

    /// The member question, with the root's store read through `state`.
    static func couldAnswer(member: String, of type: String, from directory: String?, in state: RunIndexState) -> Bool {
        guard let directory, let root = SessionPrimer.enclosingRepository(of: directory) else {
            return true
        }
        guard state.isUsable(root) else {
            return true
        }
        // A store that can no longer be read through the run's connection — deleted mid-run, say — cannot show the
        // offer wrong, so it errs toward advising, as a missing store does.
        return state.probing(root) { SiblingIndexProbe.declares(path: "\(type).\(member)", in: $0) } ?? true
    }
}
