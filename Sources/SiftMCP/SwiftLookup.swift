//
// Copyright © Agulhas Labs
//

import Foundation

/// How one Swift lookup in a transcript was served.
///
/// The distinction that matters is between a read that went *around* the index and a read the index *sent you to*. Counting them together scores the loop working as designed as evidence against itself: a ranged read of exactly the members a digest has just located is the index doing its job, not a lookup it lost.
///
/// The cases below split that correction in both directions, because it can be wrong twice over: scoring a read the index could not have improved on as a miss, and scoring a *whole-file* read after a digest as a success when the file was read in full all the same.
public enum SwiftLookup: Sendable, Equatable, Codable {
    /// A sift MCP call.
    case indexed

    /// A ranged read of a file an earlier index call located: digest-then-ranged-Read, the loop working.
    case guided(file: String)

    /// A *whole-file* read of a file this context had already digested.
    ///
    /// The whole cost the digest exists to save, paid anyway. Not a verdict on the digest: the reason is not in the transcript, and a whole read is as often after a comment or a string literal the index does not record as after anything the digest left out. The call itself is already counted as `indexed`; this is the read beside it.
    case readWholeAfterDigest(file: String)

    /// A re-read of a file this context had already opened.
    ///
    /// No index call could have saved it — the file is in context already.
    case revisited(file: String)

    /// A first touch of a file small enough that `digest` would have served its source anyway.
    ///
    /// The session paid exactly what the index would have charged, so nothing was avoided and nothing was lost. See `DigestFloor` for where the line sits and why it is drawn conservatively.
    case belowFloor(file: String)

    /// A search for text the index does not record, declared so by the tool itself.
    ///
    /// The index could not have answered this: the symbol the advice would have stood on is declared by no index this machine knows, so `where` would answer "no symbol named …". That is the index saying, in its own voice, that this is not a lookup it could have served, and counting it against the share would score the tool's own honesty as a miss.
    ///
    /// That is a fact about the *name*, not about whether the hook was awake: it excuses such a grep during a quiet spell, with advice switched off, and on a machine where the hook was never installed. That is intended — a grep for a word that lives only in string literals is a legitimate grep either way, and making the excuse depend on the hook's mood would score the same search two different ways for reasons that have nothing to do with it.
    ///
    /// Excluded from `total` and so from the share, and from the share alone: the search still happened, and the audit gives it its own row rather than folding it into the ones that measure the loop working.
    ///
    /// This is the ``TextSearch/Withholding/notRecorded`` half of a withholding, and only that half; the other half is ``withheldOnWorth``, and ``init(withheld:)`` is the one place either is chosen.
    ///
    /// `cause` is what was missing — a pattern naming nothing recorded, a name no index declares, a file no call can name, a pipeline that filters what the read printed. The four argue for four different things, so a report gives each its own line (``TextSearch/Cause``) and the decision is carried here from the place that already made it rather than re-derived at the counting end.
    case textSearch(cause: TextSearch.Cause)

    /// A lookup the index records and could have answered, withheld because the answer would have cost more round trips than the command it replaces.
    ///
    /// The ``TextSearch/Withholding/notWorthTheRoundTrips`` half: an alternation the index answers one `where` per name, a context grep of one file, a lookup the hook refused whose identical re-run it then allowed. Excluded from `total` exactly as ``textSearch`` is, and counted apart from it because the two say opposite things about the index's reach — one is a lookup the index never owed, this is one it owned and lost on a judgement of worth. Pooling them lets the share improve by redefinition, the number keeping its name and its report line while its meaning changes underneath, which is why the audit gives this its own row and prints the share a reader would get without it.
    ///
    /// `rule` is which of ``TextSearch/Rule``'s cases this is — the four arguing for different fixes that the row would otherwise pool, carried from the place that already told them apart (``init(withheld:)`` for the three read off a ``TextSearch/Reason``, ``TranscriptScan`` directly for `retryAllowed`, which names no `Reason` at all).
    case withheldOnWorth(rule: TextSearch.Rule)

    /// A first touch, of a file a digest would genuinely have compressed, with nothing to guide it: the lookup the index could have served and did not.
    ///
    /// `file` is nil for a Swift-flavoured search, which names no single file.
    ///
    /// `missed` names the index call that would have answered it, and is populated for searches only. For a miss that names a file the answer is always `digest`, so recording it would be a constant standing where a finding should be — and the report already names those files. A search is where the answer genuinely varies, and where the count alone says nothing about what to do: see ``MissedCall``. It is nil too when the advisors decline to name a call, which is honest rather than absent — that miss was counted, and nothing claims to know what would have served it.
    case cold(file: String?, missed: MissedCall?)

    /// A cold lookup on a compound line the hook let run whole because another statement on it prints what no answer reproduces: still a miss, counted in `cold`, and on a row of its own under it.
    ///
    /// Letting the line run is right, since a hook cannot run half a line, but the agent chose to batch the Swift read with other reads when the index call could have gone on the line in its place, so the share counts it as the voluntary bypass it is. `file` and `missed` are the read's, as ``cold(file:missed:)`` carries them, so a batched search still names the call that would have answered it.
    case batched(file: String?, missed: MissedCall? = nil)
}

public extension SwiftLookup {
    /// This lookup as scored where the hook's suppression log records letting its call run under `why`: a cold one becomes ``batched(file:)`` for a line run whole, and ``withheldOnWorth(rule:)`` under the rule a judgement of worth names; any other lookup, or any other withholding, is left as it is.
    func scored(letThroughAs why: InPlaceAnswerer.Withholding) -> SwiftLookup {
        guard case let .cold(file, missed) = self else { return self }
        if why == .otherStatementsRun {
            return .batched(file: file, missed: missed)
        }
        return TextSearch.Rule(loggedAs: why).map { .withheldOnWorth(rule: $0) } ?? self
    }

    /// The lookup a withheld search is: each half of ``TextSearch/Withholding`` and never the other, and for the first half the cause the rule already named.
    ///
    /// The one crossing between the two vocabularies, so a rule added to ``TextSearch/Reason`` reaches the count its own half names — and its own cause within that half — without any call site restating either mapping.
    init(withheld reason: TextSearch.Reason) {
        if let cause = reason.cause {
            self = .textSearch(cause: cause)
        } else {
            // Exhaustive by construction: every reason `cause` leaves nil is one `rule` names (TextSearch.Reason.rule).
            self = .withheldOnWorth(rule: reason.rule ?? .retryAllowed)
        }
    }
}
