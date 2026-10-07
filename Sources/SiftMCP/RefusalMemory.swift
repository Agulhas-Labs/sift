import Foundation

/// What the transcript scan remembers of a refusal it reads back: the keys a lookup's identical re-run is recognised by.
struct RefusalMemory {
    /// What a whole read is remembered by once the hook has answered it in place — the key the advice ledger gives it — so its identical re-run is recognised as the escape hatch a search's is.
    static func readKey(_ path: String) -> String {
        "Read \(path)"
    }

    /// Whether `reason` is a lookup held back with a pointer at a call made beside it, and if so what the scan does with it.
    ///
    /// The answer is in the same batch of results, so the lookup is the index serving the context — taken back and counted indexed — but it is not an answer in place and no round trip was spent. The pointer's identical re-run is the same escape hatch a refusal offers, so it is remembered as a refusal's is.
    static func heldBack(_ reason: String, pending: PendingRead, events: inout [TranscriptEvent], in state: inout TranscriptScanState) -> Bool {
        guard reason.contains(IndexSuggestion.heldBackStem) || reason.contains(IndexSuggestion.answeredBesideStem) else { return false }
        if !pending.key.isEmpty {
            state.hookDenied.insert(pending.key)
        } else if !pending.path.isEmpty, !pending.shellWindow {
            state.hookDenied.insert(readKey(pending.path))
        }
        if pending.counted {
            events += [.lookupRetracted(pending.lookup), .lookup(.indexed)]
        }
        return true
    }
}
