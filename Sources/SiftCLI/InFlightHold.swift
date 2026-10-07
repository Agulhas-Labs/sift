import Foundation
import SiftCore
import SiftMCP

/// What the hook does with a lookup whose offered index call was made beside it and has not been answered yet.
///
/// **Only a lookup that is the whole of its call can be held back with a pointer.** A denial swallows the whole call, so a lookup beside other statements of a shell line, and a window, are let through as an offer taken up always was; the transcript is not handed over for them, which is what says "cannot tell".
struct InFlightHold {
    let context: AdviceContext
    let payload: [String: Any]
    let directory: String?
    let ledger: AdviceLedger
    let suppressions: SuppressionLog

    /// The ledger's decision on the offer `lookup` carries.
    ///
    /// Pinned to the tree this lookup itself would search — never to cwd alone — so an offer already taken up against a different repository is not read as circular here (``IndexSuggestion/rooted(_:at:)``). `lookup.anchor` names its path the way the command wrote it, resolved against `directory` exactly as `unindexed` resolves the same anchor — a relative `Sources` is the caller's own working directory's `Sources`, never wherever this process happens to have been started.
    ///
    /// A file names no repository itself. Where asked, its directory stands for it, so a whole read of a file whose digest was asked for is offered that digest under the root the digest call was made at.
    func decideOffer(_ lookup: PreToolUseCommand.Lookup, rootingAFileAtItsDirectory: Bool = false) -> AdviceLedger.Decision {
        var named = lookup.anchor.flatMap { SwiftTree.resolve($0, relativeTo: directory) } ?? directory
        var isDirectory: ObjCBool = false
        if rootingAFileAtItsDirectory, let path = named, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
            named = URL(fileURLWithPath: path).deletingLastPathComponent().path
        }
        let offeringRoot = CallerRoot.root(forCallerIn: named)
        let alone = lookup.inPlace.map { $0.isWholeCommand && !$0.runsOtherStatements } ?? false
        let wholeCall = alone && !lookup.isWindow && lookup.windowPaths.isEmpty
        let offered = lookup.suggestion.calls
        let rooted = IndexSuggestion.rooted(offered, at: offeringRoot)
        let decision = ledger.decide(
            session: context.key,
            command: lookup.key,
            offering: rooted,
            transcript: wholeCall ? (payload["transcript_path"] as? String) : nil,
            agent: payload["agent_id"] as? String
        )
        // The ledger names calls under the root they were made at; the pointer names them as they were offered.
        guard case let .pointAt(waiting, hookMade) = decision else { return decision }
        let asOffered = Dictionary(zip(rooted, offered), uniquingKeysWith: { first, _ in first })
        return .pointAt(waiting.map { asOffered[$0] ?? $0 }, hookMade: Set(hookMade.map { asOffered[$0] ?? $0 }))
    }

    /// The pointer `lookup` is held back with, naming `calls`.
    func holdBack(_ lookup: PreToolUseCommand.Lookup, at calls: [String], hookMade: Set<String> = []) -> (json: String?, verdict: PreToolUseCommand.Verdict) {
        // The promise the pointer closes with is the identical re-run, so it is not made where it cannot be kept.
        guard ledger.noteDenial(session: context.key, command: lookup.key) else {
            return (nil, PreToolUseCommand.Verdict(token: "allowed", rule: "ledger"))
        }
        suppressions.note(symbol: lookup.suggestion.symbol, directory: directory, rule: "inFlight", call: payload["tool_use_id"] as? String)
        let reason = IndexSuggestion.heldBackReason(calls: calls, hookMade: hookMade)
        return (
            HookOutput.preToolUseDenial(reason: reason),
            PreToolUseCommand.Verdict(token: "held", call: TerseCall.joining(calls), rule: "inFlight", reason: reason)
        )
    }
}
