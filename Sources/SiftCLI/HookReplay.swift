//
// Copyright © Agulhas Labs
//

import CryptoKit
import Foundation
import SiftCore
import SiftMCP

/// The advice hook's own decision, run in-process over a transcript's calls against state kept in a scratch directory, so a replay neither reads nor moves anything a live session relies on.
///
/// Everything the hook remembers about a context — its ledger, the digests it was answered, the back-off after an overrun — lives under `directory` and is rebuilt from the transcript as it is walked; the back-off is kept per context, so an overrun in one context never withholds another's answers. Suppressions are written nowhere unless the replay is given a file for them (a `replay-hook` child writes `suppressions.jsonl` in its state directory, so a probe can read which rule fired), though the rule each call's is noted under is kept for its verdict (``ReplayVerdict/logged(_:)``); the server is taken as present, and the in-place answerer is the real one: a stub would make the gate lie.
struct HookReplay: ReplayHook {
    let ledger: AdviceLedger
    let usage: UsageLog
    let digested: DigestedFiles
    /// Where each context's back-off is kept, a directory of its own for each context under it.
    let backoffDirectory: URL
    /// The digests the context's own index calls asked for, noted when each call is made, and never an answer the hook gave in place.
    let ownCalls: AdviceLedger
    /// The in-place answerer's size budget, in UTF-8 bytes — the live hook's own default, overridable so a replay-driven test can prove `overSize` on a small answer without constructing one that genuinely runs past ten thousand bytes.
    let sizeBudget: Int
    /// The in-place answerer's time budget, named by whoever builds the replay: `audit --replay` passes the roomy one below, never the live hook's, so a loaded machine cannot judge an answer `overTime` by the clock rather than by the hook — which, through the back-off the overrun notes, withholds every later answer of the shape too.
    let timeBudget: TimeInterval
    /// The repository roots this replay has discovered, bound around every call it judges so each directory is asked of git once in the whole run rather than several times a call.
    let roots: RootDiscovery
    /// The engines this replay's answers keep open per root, bound around every call it judges so each root's engine is opened once in the whole run rather than once an answer.
    let engines: EngineReuse
    /// Whether some index declares a name, asked the way the live hook asks it: `audit --replay` hands in the run's own reading of the indexes (``RunIndexState``), so the replay judges each name against the store the audit judged it against, unless another binary judges beside it (``judgesAfresh``).
    let couldAnswer: @Sendable (String, String?) -> Bool
    private let clock: ReplayClock
    /// Where the suppressions are written, or the null device where the replay keeps none.
    private let suppressionsFile: URL

    /// The name gate a `replay-hook` child judges with: each name asked afresh of the indexes as they stand, the way the live hook asks it.
    static let judgesAfresh: @Sendable (String, String?) -> Bool = { AdvisableName.couldAnswer($0, from: $1) }

    /// The time budget `audit --replay` answers under: sixty seconds, twenty times the live hook's, because a replay counts what the hook would answer for a call's shape and not how busy the machine is while it counts.
    static let timeBudget: TimeInterval = 60

    init(
        directory: URL,
        sizeBudget: Int = InPlaceAnswer.sizeBudget,
        timeBudget: TimeInterval,
        roots: RootDiscovery = RootDiscovery(),
        engines: EngineReuse = EngineReuse(),
        couldAnswer: @escaping @Sendable (String, String?) -> Bool = judgesAfresh,
        writesSuppressions: Bool = false
    ) {
        suppressionsFile = writesSuppressions ? directory.appendingPathComponent("suppressions.jsonl") : URL(fileURLWithPath: "/dev/null")
        self.roots = roots
        self.couldAnswer = couldAnswer
        self.engines = engines
        let clock = ReplayClock()
        self.clock = clock
        ledger = AdviceLedger(directory: directory.appendingPathComponent("advice", isDirectory: true), now: { clock.now })
        let usageFile = directory.appendingPathComponent("usage.jsonl")
        usage = UsageLog(fileURL: usageFile)
        digested = DigestedFiles.following(usageLog: usageFile)
        ownCalls = AdviceLedger(directory: directory.appendingPathComponent("own-advice", isDirectory: true), now: { clock.now })
        backoffDirectory = directory.appendingPathComponent("backoff", isDirectory: true)
        self.sizeBudget = sizeBudget
        self.timeBudget = timeBudget
    }

    func verdict(payload: [String: Any], cwd: String, at instant: Date?, decides: Bool) -> ReplayVerdict? {
        RootDiscovery.$current.withValue(roots) {
            EngineReuse.$current.withValue(engines) { judged(payload: payload, cwd: cwd, at: instant, decides: decides) }
        }
    }

    func answered(payload: [String: Any], cwd: String, at instant: Date?) {
        RootDiscovery.$current.withValue(roots) { noteAnswered(payload: payload, cwd: cwd, at: instant) }
    }

    private func judged(payload: [String: Any], cwd: String, at instant: Date?, decides: Bool) -> ReplayVerdict? {
        clock.advance(to: instant)
        let context = Self.context(of: payload)
        if PreToolUseCommand.takesTheAdvice(command: nil, payload: payload) {
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            let tool = payload["tool_name"] as? String
            let calls = IndexSuggestion.callsMade(
                toolName: tool,
                input: input,
                command: input["command"] as? String,
                root: CallerRoot.statedRoot(toolName: tool, input: input) ?? CallerRoot.root(forCallerIn: cwd)
            )
            let digests = PreToolUseCommand.digestsAsked(toolName: tool, input: input, cwd: cwd)
            for book in [ledger, ownCalls] {
                book.noteIndexCall(session: context.key, calls: calls, digests: digests)
            }
            return ReplayVerdict(token: "allowed", rule: ReplayVerdict.indexCallRule)
        }
        // Noted as the live hook notes it, and handed back unhooked: a write is no lookup to judge, and a verdict
        // for it would list every write as a change against a binary that never saw one.
        if PreToolUseCommand.notesWrite(context: context, payload: payload, cwd: cwd, ledger: ledger) {
            return nil
        }
        guard Self.judgesLookups(of: payload["tool_name"] as? String ?? "") else { return nil }
        // Judged whether or not it counts: a call before the window still moves the ledger, the usage log and
        // the back-off exactly as the live hook would, so a call inside the window that depends on that state —
        // a denial already on record, a digest already served — reads it real rather than empty. Only the
        // verdict handed back for counting is gated on `decides`, after the judgment has run, never instead of it.
        // A call let through as `noLookup` after a gate logged it withheld is reported under the rule logged, as
        // the live hook's suppression log records it, rather than as no lookup at all.
        let noted = NotedRule()
        let suppressions = SuppressionLog(fileURL: suppressionsFile, noted: noted.record)
        let letThrough = { noted.last.map(ReplayVerdict.logged) ?? "noLookup" }
        guard let lookup = PreToolUseCommand.lookup(
            command: nil,
            payload: payload,
            in: cwd,
            noting: suppressions,
            digested: digested,
            couldAnswer: couldAnswer,
            allowed: { ledger.rerunsAllowed(session: context.key, among: $0) }
        ) else {
            return ReplayVerdict(token: "allowed", rule: decides ? letThrough() : "outsideWindow")
        }
        let backoff = backoff(for: context)
        let measured = MeasuredAnswerSize()
        let verdict = PreToolUseCommand.outcome(
            to: lookup,
            session: payload["session_id"] as? String,
            context: context,
            payload: payload,
            cwd: cwd,
            ledger: ledger,
            usage: usage,
            suppressions: suppressions,
            timeBudget: timeBudget,
            answerer: { InPlaceAnswerer.answer($0, serverGone: $1, timeBudget: $2, sizeBudget: sizeBudget, backoff: backoff, oversized: measured.record) },
            serverPresence: { _, _ in false },
            couldAnswer: couldAnswer
        ).verdict
        guard decides else { return ReplayVerdict(token: "allowed", rule: "outsideWindow") }
        let rule = verdict.rule == "noLookup" ? letThrough() : verdict.rule ?? "unnamed"
        let answerBytes = rule == InPlaceAnswerer.Withholding.overSize.rawValue ? measured.value : nil
        return ReplayVerdict(token: verdict.token, rule: rule, call: verdict.call, answerBytes: answerBytes, reason: verdict.reason)
    }

    private func noteAnswered(payload: [String: Any], cwd: String, at instant: Date?) {
        clock.advance(to: instant)
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        // The line the server writes for an answered digest is what a later whole read is excused by.
        // A lone path digest answered with another file's is recorded with the file it served, as the server records it.
        let answer = payload[TranscriptReplay.answerKey] as? String
        let asked = PreToolUseCommand.digestsAsked(toolName: payload["tool_name"] as? String, input: input, cwd: cwd)
        // Read off the answer's text as the server reads it, so a digest that resolved nothing is recorded as one.
        let missed = asked.values.joined().count == 1 && answer.map { DigestMiss.isMiss(inAnswer: $0) } == true
        // And taken back from the ledgers the judged call noted it in before any answer existed, as the live hook's
        // post-tool-use does: a digest that resolved nothing excuses no later window.
        if answer.map({ DigestMiss.isMiss(inAnswer: $0) }) == true {
            for book in [ledger, ownCalls] {
                book.forgetDigests(session: Self.context(of: payload).key, digests: asked)
            }
        }
        let served = asked.values.joined().count == 1 ? answer.map { DigestedFiles.locatedFiles(inAnswer: $0, tool: "digest") } ?? [] : []
        for (root, targets) in asked {
            for target in targets {
                usage.record(
                    tool: "digest",
                    target: target,
                    root: root,
                    milliseconds: 0,
                    succeeded: true,
                    answer: AnswerBytes(served: 0, source: 0),
                    agent: payload["agent_id"] as? String,
                    session: payload["session_id"] as? String,
                    located: served,
                    miss: missed
                )
            }
        }
        // And the line it writes for an answered `where` or `search`, which locates what the answer listed for a
        // later window. The context's own call, so its own-calls ledger holds the same files: a window they
        // excuse was not located only by an answer the hook gave in place.
        guard let answer else { return }
        let located = PreToolUseCommand.locatedByAnswer(answer, toolName: payload["tool_name"] as? String, input: input, cwd: cwd)
        for (root, files) in located {
            usage.record(
                tool: "where",
                target: nil,
                root: root,
                milliseconds: 0,
                succeeded: true,
                answer: AnswerBytes(served: 0),
                agent: payload["agent_id"] as? String,
                session: payload["session_id"] as? String,
                located: files
            )
        }
        if !located.isEmpty {
            ownCalls.noteIndexCall(session: Self.context(of: payload).key, calls: [], digests: located)
        }
    }

    func locatedOnlyByAnswers(_ path: String, payload: [String: Any]) -> Bool {
        guard let session = payload["session_id"] as? String else { return false }
        let agent = payload["agent_id"] as? String
        let key = Self.context(of: payload).key
        // Asked by the hook's own two tests, over everything it holds and then over the context's own calls
        // alone — with the rule the hook let the window through on, `isLocated`, so a bounded answer's
        // line-range target excuses a later window exactly as a whole digest does.
        let located = digested.locates(path, session: session, agent: agent)
            || DigestedFiles.isLocated(path, among: ledger.digests(session: key))
        guard located else { return false }
        return !DigestedFiles.isLocated(path, among: ownCalls.digests(session: key))
    }

    /// Whether the live hook is registered for `tool` and judges it as a lookup, so the Xcode server's reads and searches are put to it as the built-in ones are.
    static func judgesLookups(of tool: String) -> Bool {
        guard LookupTool.rule(for: tool) != nil else { return false }
        // Matched whole, as the harness matches a registration: a matcher of `Read` never fires for `NotebookRead`.
        return HookRegistration.events.filter { $0.name == "PreToolUse" }.flatMap(\.matchers).contains { matcher in
            (try? Regex(matcher)).map { tool.wholeMatch(of: $0) != nil } ?? false
        }
    }

    /// `context`'s own back-off on the transcript's clock: an overrun is stamped with the instant of the call that ran out of time and read against the instant of each later call of that context alone.
    func backoff(for context: AdviceContext) -> InPlaceBackoff {
        let digest = SHA256.hash(data: Data(context.key.utf8))
        let name = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        let clock = clock
        return InPlaceBackoff(directory: backoffDirectory.appendingPathComponent(name, isDirectory: true), now: { clock.now })
    }

    /// The ledger's context for a payload, exactly as the live hook resolves it.
    private static func context(of payload: [String: Any]) -> AdviceContext {
        AdviceContext.resolve(
            sessionID: payload["session_id"] as? String ?? "unknown",
            transcriptPath: payload["transcript_path"] as? String,
            agentID: payload["agent_id"] as? String
        )
    }
}
