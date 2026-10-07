//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// A read counted on the strength of its call, held until the result says whether it happened.
public struct PendingRead: Sendable, Equatable {
    /// How the read was scored when it was counted.
    var lookup: SwiftLookup

    /// The file the read named.
    var path: String

    /// Whether counting this read is what put `path` into `opened`, or for a shell window into `windowed`.
    ///
    /// Only the read that *first* opened a path may take it back out. A second read of an already-open file was scored `revisited` and found the path there already, so undoing it would erase the earlier, real read and rescore every read after it.
    var openedPath: Bool

    /// Whether the read was a shell window, so the set it opened `path` in is `windowed` and not `opened`.
    var shellWindow = false

    /// Whether the read was actually emitted, and so is there to be taken back.
    ///
    /// A call outside a `--since` window is classified — the state still has to advance — but never counted. Retracting one anyway would subtract a lookup the tally never added, which is the same error in the opposite direction.
    var counted: Bool

    /// What the advice hook would have remembered this search by, so a refusal of it can be recognised when the same search comes back.
    ///
    /// Computed the way `PreToolUseCommand.classified` keys the ledger, because the two have to agree about what "the same search" is: the hook allows the re-run on the strength of its own key, and the scan has to excuse exactly the calls the hook let through. Empty for a `Read` and for a windowed shell read, neither of which the sanctioned re-run applies to.
    var key: String = ""

    /// The readings the hook could answer this shell line as, in the order it tries them, so an answer is remembered under exactly the lookups the served one stands for (``ServedReading``) — empty wherever `key` alone is what an answer is remembered by.
    var readings: [ServedReading] = []

    /// How this call is scored and remembered where an earlier call of its turn, taken as answered when it was scored, turns out to have been let through — `nil` where no such call decided anything about it.
    var fallback: LetThroughFallback?

    /// The assistant turn the call was made in, so a refusal of it can be priced by the turn after (``TranscriptEvent/refusalRoundTrip(cost:)``).
    var turn: String?

    /// The directory the call was made in, which is what places a digest the hook answered in the call's place (``FloorVerdict``).
    var directory: String?

    /// What this call looked like, captured on the way out so a refusal of it can be classified — its shape, and whether whatever follows it is the identical call re-run.
    var shape = RefusedCallShape(tool: "", text: "", kind: .other)
}

extension PendingRead {
    /// The directory the call's lookups ran in, which an answer the hook gave in its place names its files relative to: where a Bash line's literal `cd`s move its lookups (``TranscriptScanState/digestDirectory(of:from:)``, as a shell digest is placed), `nil` behind a move that cannot be followed, else ``directory``.
    var answeredFrom: String? {
        guard let directory, shape.tool == "Bash", shape.text.hasPrefix("Bash: ") else { return directory }
        return TranscriptScanState.digestDirectory(of: String(shape.text.dropFirst("Bash: ".count)), from: directory)
    }

    /// Whether the hook's answer to this call can be placed anywhere: false only for a call made from a known directory whose Bash line moved where ``answeredFrom`` cannot follow, whose answer names its files relative to a checkout nothing here can tell.
    var answerIsPlaced: Bool {
        directory == nil || answeredFrom != nil
    }

    /// The file a refused shell line named in full for the path `target` asks for, where one of its words is that path spelled out from the root.
    ///
    /// Nil for a type target and for a line naming the file relative to where it ran, which ``answeredFrom`` spells.
    func pathInFull(of target: String) -> String? {
        let asked = DigestLineRange.parse(target)?.path ?? target
        guard asked.contains("/") || asked.hasSuffix(".swift"), shape.tool == "Bash", shape.text.hasPrefix("Bash: ") else { return nil }
        let command = String(shape.text.dropFirst("Bash: ".count))
        return ShellSyntax.executedSegments(of: command).lazy.flatMap { ShellSyntax.tokens(of: $0) }.first {
            $0.hasPrefix("/") && ($0 == asked || $0.hasSuffix("/" + asked))
        }
    }
}
