//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore
import SiftMCP

/// `sift pre-tool-use` — the body of the Claude Code `PreToolUse` hook, registered for every tool that can read Swift source.
///
/// The primer and the path-scoped rule both land *before* a lookup and both are easily passed over; this lands *at* one. It is also the only delivery that reaches the shell at all: a `grep` or `sed` in Bash never opens a file as far as the harness is concerned, so `paths: ["**/*.swift"]` never fires for it — and the shell is where most of the misses are.
///
/// Three invariants, each because a misbehaving hook degrades every session on the machine: it always exits 0; it prints nothing unless it is refusing something; and a refusal is always retryable (`AdviceLedger`), so nothing it does can make a command unavailable.
///
/// It carries the *output* side of the same problem too: a bare `swift test` or `xcodebuild` in Bash is offered `sift run --` by `RunAdvice`. Same ledger, same budget, same retry — a session that has waved the advice off stays unpestered, and one that takes it converts a thousand-line build log into its failures.
struct PreToolUseCommand: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "pre-tool-use",
            abstract: "Offer the index call that answers a shell lookup of Swift source (run by Claude Code's PreToolUse hook; silent otherwise)."
        )
    }

    @Option(name: .customLong("command"), help: "Shell command to judge. Passing it skips the stdin payload entirely.")
    var command: String?

    @Option(name: .customLong("session"), help: "Session identifier the retry ledger is keyed on (defaults to the payload's session_id).")
    var session: String?

    @Option(name: .customLong("cwd"), help: "Directory to resolve the command's paths against (defaults to the payload's cwd).")
    var cwd: String?

    @Option(name: .customLong("permission-mode"), help: "Permission mode to judge the call in, as Claude Code's payload names it (defaults to the payload's permission_mode).")
    var permissionMode: String?

    @Flag(name: .customLong("verdict"), help: "For probing the hook, not for the hook itself: print one tab-separated line — the verdict, the call it offered, the rule that decided it — instead of the JSON the PreToolUse hook reads. See Docs/Design.md.")
    var verdict = false

    @Option(name: .customLong("agent"), help: "The harness whose hook protocol to read and answer in: claude or cursor (default claude). Set by the registration, never guessed from the payload.")
    var agent: HookAgent = .claude

    func run() {
        // An off switch rather than a mode: one environment variable turns the hook inert without touching
        // settings.json, which matters on a machine where the registration is shared with hooks this
        // project does not own. Empty counts as unset, so `SIFT_NO_ADVICE=` in a wrapper script
        // reads as "not disabled" rather than silently disabling it.
        let disabled = ProcessInfo.processInfo.environment["SIFT_NO_ADVICE"] ?? ""
        guard disabled.isEmpty else {
            if verdict {
                StandardStreams.emit(Verdict(token: "allowed", rule: "disabled").line)
            }
            return
        }

        guard var payload = read(command == nil ? hookPayload() : [:]) else { return }
        payload["permission_mode"] = permissionMode ?? payload["permission_mode"]
        let directory = cwd ?? (payload["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        let sessionID = session ?? payload["session_id"] as? String ?? "unknown"
        // A subagent reports its parent's session id — and its parent's transcript path too, so `agent_id`
        // is the field that scopes the ledger; otherwise a subagent inherits a budget it never spent, and
        // a parent that silenced the hook mutes every subagent it spawns (see `AdviceContext`).
        let context = AdviceContext.resolve(
            sessionID: sessionID,
            transcriptPath: payload["transcript_path"] as? String,
            agentID: payload["agent_id"] as? String
        )

        // Resolved before the classification, because this is the one call shape the hook is registered
        // for that it has nothing to say about and something to *learn* from. An index call is the advice
        // being taken, and this is the only place on the machine where one and the conversation that made
        // it are visible at the same moment — the logs carry no conversation
        // identity at all (`AdviceLedger.noteIndexCall`).
        if Self.takesTheAdvice(command: command, payload: payload) {
            // Where the server answering this caller is running, as the server itself recorded it in the lifecycle
            // log, under every harness alike: the live server spawned by this hook's closest ancestor, since the
            // harness that spawned it runs this hook too, a subagent's included. The payload's own session id
            // only reaches a start line too old to name its parent. A miss of any kind is nil, and the call is
            // amended as before.
            let serverDirectory = CallerRoot.serverDirectory(session: session ?? payload["session_id"] as? String)
            let output = Self.adviceTaken(
                session: sessionID, context: context, payload: payload, command: command, cwd: directory, serverDirectory: serverDirectory
            )
            if verdict {
                let token = output == nil ? "allowed" : "amended"
                StandardStreams.emit(Verdict(token: token, rule: "adviceTaken").line)
            } else if let output {
                answer(output, toolName: payload["tool_name"] as? String)
            }
            return
        }

        let ledger = AdviceLedger.standard()
        if Self.notesWrite(context: context, payload: payload, cwd: directory, ledger: ledger) {
            if verdict {
                StandardStreams.emit(Verdict(token: "allowed", rule: "written").line)
            }
            return
        }
        let outcome = Self.decided(
            command: command,
            payload: payload,
            cwd: directory,
            session: session ?? payload["session_id"] as? String,
            context: context,
            ledger: ledger,
            usage: UsageLog.forHookAnswer(transcriptPath: payload["transcript_path"] as? String),
            runPermission: runPermission
        )
        if verdict {
            StandardStreams.emit(outcome.verdict.line)
        } else if let json = PrintedAnswer.recorded(outcome, payload: payload) {
            answer(json, toolName: payload["tool_name"] as? String)
        }
    }

    /// What the hook prints for a lookup worth interrupting, or `nil` where the call is let through: the answer where the lookup is one of the answered shapes and the budgets hold, a build's wrapping, and nothing at all otherwise.
    ///
    /// **It answers in place or it allows: a refusal that only names a call is no longer an outcome.** Such a refusal costs a whole round trip — the context re-sent to be told one sentence — against a saving of roughly a quarter of that, so a shape with no answer in it, and every attempt withheld or overrun, goes through instead. The lookup is still counted, by the transcript scan through the same predicates that classified it here, so the audit goes on showing the miss.
    ///
    /// The ledger decides first and the answer never overrides it: an answer still denies the command, so it is given only where a refusal would have been, and the identical re-run it promises is allowed on the ledger's record like any other. What it may not do is spend the budget on a call it let through, so the record of a denial is written by ``SiftMCP/AdviceLedger/noteDenial(session:command:)`` at the one outcome that prints one.
    ///
    /// **An answer is the index serving this context, and is recorded as one.** The ledger notes it as an index call, which is what keeps the advice coming to a context that takes it, and the usage log gets the line the server would have written for the call — this session, this agent, what was served and the source it stood in for — marked as the hook's (`via`). That line is what `usage` and the report page price the saving from, and what excuses a whole read of the file afterwards (`DigestedFiles`).
    ///
    /// One function rather than statements inside `run`, so that what a test exercises is what the hook does.
    static func respond(
        to lookup: Lookup,
        session: String?,
        context: AdviceContext,
        payload: [String: Any],
        command: String? = nil,
        cwd directory: String?,
        ledger: AdviceLedger = .standard(),
        usage: UsageLog? = .standard(),
        suppressions: SuppressionLog = .standard(),
        timeBudget: TimeInterval = InPlaceAnswer.timeBudget,
        answerer: (InPlaceShape.Match, Bool, TimeInterval) -> InPlaceAnswerer.Outcome = { InPlaceAnswerer.answer($0, serverGone: $1, timeBudget: $2) },
        serverPresence: (_ transcript: String?, _ agent: String?) -> Bool = ServerPresence.isGone(ofSession:agent:)
    ) -> String? {
        outcome(
            to: lookup,
            session: session,
            context: context,
            payload: payload,
            command: command,
            cwd: directory,
            ledger: ledger,
            usage: usage,
            suppressions: suppressions,
            timeBudget: timeBudget,
            answerer: answerer,
            serverPresence: serverPresence
        ).json
    }

    /// `respond`'s decision, and the terse fact a probe wants about the same decision (`--verdict`) — computed once, since the ledger's decision has side effects a second call would double.
    static func outcome(
        to lookup: Lookup,
        session: String?,
        context: AdviceContext,
        payload: [String: Any],
        command: String? = nil,
        cwd directory: String?,
        ledger: AdviceLedger = .standard(),
        usage: UsageLog? = .standard(),
        suppressions: SuppressionLog = .standard(),
        timeBudget: TimeInterval = InPlaceAnswer.timeBudget,
        answerer: (InPlaceShape.Match, Bool, TimeInterval) -> InPlaceAnswerer.Outcome = { InPlaceAnswerer.answer($0, serverGone: $1, timeBudget: $2) },
        serverPresence: (_ transcript: String?, _ agent: String?) -> Bool = ServerPresence.isGone(ofSession:agent:),
        runPermission: (_ directory: String?) -> WrappedRunPermission = WrappedRunPermission.standard(in:),
        couldAnswer: (String, String?) -> Bool = { AdvisableName.couldAnswer($0, from: $1) }
    ) -> (json: String?, verdict: Verdict) {
        if let rewritten = rewrite(lookup, command: command, payload: payload, in: directory, suppressions: suppressions, permission: { runPermission(directory) }) {
            return rewritten
        }
        // A whole read of files this context has been served the digest of, by any route, would be answered with
        // the digest it holds; the only reason it asks for source is that the digest was not enough. Asked
        // before the ledger decides, so an allow here spends nothing of the budget. A window of such files is
        // the loop working, and no lookup at all: dropped from a line of several reads, whose rest is marked as
        // leaving other statements to print, since the window prints lines no answer to the rest reproduces, so
        // the line runs with the note naming the call for the rest; let through where nothing else is left. A
        // whole read the hook would let through alone is dropped the same way.
        let hold = InFlightHold(context: context, payload: payload, directory: directory, ledger: ledger, suppressions: suppressions)
        var lookup = lookup
        if lookup.inPlace != nil || lookup.readPath != nil || !lookup.windowPaths.isEmpty {
            // A file this context wrote or edited is text it already holds, so a read of it, whole or through a
            // window, is a revisit and no lookup: let through with nothing noted, as the scan files it revisited.
            var reads = lookup.readPaths(from: directory)
            let digests = ledger.digests(session: context.key)
            // A digest the ledger noted as asked locates a window no wider than `ListedWindow.widestExcused`, as an
            // answer on the usage log does; a wider one needs the file's whole digest.
            let located = { (path: String, windows: [LineWindow]) in
                ListedWindow.isWide(windows, ofFileAt: path) ? DigestedFiles.isDigested(path, among: digests) : DigestedFiles.isLocated(path, among: digests)
            }
            let held = { (path: String, windows: [LineWindow]) in located(path, windows) || ledger.holds(path, session: context.key) }
            // A read the hook lets through standing alone — a held file's window, or a whole read of a file whose
            // whole digest this context holds or that it wrote — still prints its source beside the others, so it
            // is dropped as a held window is, and the rest runs: no answer replaces it with a digest already held.
            let alone = { (path: String, windows: [LineWindow], windowed: Bool) in windowed ? held(path, windows) : DigestedFiles.isDigested(path, among: digests) || ledger.holds(path, session: context.key) }
            var setAside: (reading: InPlaceShape.Match, rule: String)?
            var everyReadLetThrough = false
            // Whether every whole read on a line let through for its reads is of a file whose whole digest this
            // context holds: one let through only because the context wrote the file holds its text, not its
            // digest, so the line is noted as the line of written reads below is, as nothing.
            var everyWholeReadDigested = true
            if !reads.isEmpty, reads.allSatisfy({ ledger.holds($0, session: context.key) }) {
                guard let inPlace = lookup.inPlace else { return (nil, Verdict(token: "allowed", rule: "written")) }
                setAside = (inPlace, "written")
            } else if let inPlace = lookup.inPlace, inPlace.windowed.contains(true) || inPlace.calls.count > 1 {
                // Where every read is let through alone: a line of windows is no lookup, one with a whole read is let
                // through below as that read alone would be.
                let rest = inPlace.droppingReads(where: alone)
                lookup.inPlace = rest ?? inPlace
                everyReadLetThrough = rest == nil && inPlace.windowed.contains(false)
                everyWholeReadDigested = inPlace.wholeReadPaths.allSatisfy { DigestedFiles.isDigested($0, among: digests) }
                setAside = rest == nil && !everyReadLetThrough ? (inPlace, "noLookup") : nil
            }
            // An in-place reading set aside may sit beside a lookup no answer covers — a grep whose output is
            // filtered — and the line is judged by that one, as though the reads were allowed re-runs, which ride
            // beside it and so never let an answer to it deny the line; it is let through with nothing noted only
            // where the reads were all there was.
            if let setAside {
                let keys = Set(setAside.reading.statements.joined().compactMap { lookup.statementKeys[$0] }).union(lookup.usageLogHeldKeys)
                guard let beside = Self.lookup(besideReads: keys, command: command, payload: payload, in: directory, context: context, ledger: ledger) else {
                    return (nil, Verdict(token: "allowed", rule: setAside.rule))
                }
                guard let asked = worthAsking(beside, in: directory, noting: suppressions, call: payload["tool_use_id"] as? String, couldAnswer: couldAnswer) else {
                    return (nil, Verdict(token: "allowed", rule: "noLookup"))
                }
                lookup = asked
                lookup.inPlace = asked.inPlace?.droppingReads(where: alone)
                reads = lookup.readPaths(from: directory)
            }
            // A window (a ranged `Read`, or a shell line of windows no answered shape covers) is excused by a digest
            // that only locates the file, line-range target included; a whole read needs the file's own digest.
            let window = lookup.isWindow && (lookup.readPath != nil || lookup.inPlace == nil)
            let windows = lookup.readPath == nil ? [] : lookup.inPlace?.calls.first?.windows ?? []
            if everyReadLetThrough || !reads.isEmpty && reads.allSatisfy({ window ? located($0, windows) : DigestedFiles.isDigested($0, among: digests) }) {
                guard everyReadLetThrough || !window else { return (nil, Verdict(token: "allowed", rule: "noLookup")) }
                // A whole read of a file whose digest was asked for beside it has not been handed that digest yet.
                if !window, !everyReadLetThrough, case let .pointAt(calls, hookMade) = hold.decideOffer(lookup, rootingAFileAtItsDirectory: true) {
                    return hold.holdBack(lookup, at: calls, hookMade: hookMade)
                }
                // The line is still let through for the read, but a lookup beside it — a grep whose output is filtered —
                // goes through the gates it would meet alone and is logged under the rule that withholds it, so its miss
                // is not hidden behind the read's. Its answer is never asked for: that would deny the read as well.
                if let beside = Self.lookup(besideReadsOf: lookup, command: command, payload: payload, in: directory, allowed: { ledger.rerunsAllowed(session: context.key, among: $0) }) {
                    _ = worthAsking(beside, in: directory, noting: suppressions, call: payload["tool_use_id"] as? String, couldAnswer: couldAnswer)
                }
                guard everyWholeReadDigested else { return (nil, Verdict(token: "allowed", rule: "written")) }
                suppressions.note(symbol: nil, directory: directory, rule: "alreadyDigested", call: payload["tool_use_id"] as? String)
                return (nil, Verdict(token: "allowed", rule: "alreadyDigested"))
            }
        }
        let decision = hold.decideOffer(lookup)
        if case let .pointAt(calls, hookMade) = decision {
            return hold.holdBack(lookup, at: calls, hookMade: hookMade)
        }
        // `ledger` rather than a bare `allowed`: this is the one allow a probe can be *surprised* by — the
        // same command refused a moment ago is allowed now, because the nudge for it was already spent. A
        // gate that greps `allowed` without it cannot tell that from "never a lookup at all", which is how
        // an unsessioned probe reads a spent allowance as a withheld nudge.
        guard decision != .allow else { return (nil, Verdict(token: "allowed", rule: "ledger")) }
        // A pass over the transcript, so it is read only by the two outcomes that spell something for the face
        // the context still holds — the answer in place and the wrapping — and never by an allow.
        func serverGone() -> Bool {
            serverPresence(payload["transcript_path"] as? String, payload["agent_id"] as? String)
        }
        // Set only where an in-place answer was attempted and withheld — the more specific fact of the two
        // that could end this in an allow, and the one `--verdict` names when it has it.
        var withheldReason: InPlaceAnswerer.Withholding?
        // The note a line let run whole for its other statements is handed, where its Swift leg would have been answered alone.
        var batchedNote: String?
        if let asked = lookup.inPlace {
            let gone = serverGone()
            let started = Date()
            // A compound line whose own answer is withheld is answered as the line always was, and everything
            // below speaks for the reading that was answered.
            let (inPlace, outcome) = InPlaceAnswerer.firstAnswered(asked, timeBudget: timeBudget) { answerer($0, gone, $1) }
            switch WholeReadWorth.weighing(outcome, of: inPlace, payload: payload) {
            case let .answered(answered):
                // **The ledger records a denial only where one is printed, and this is the one outcome that
                // prints one.** The record is what keeps the promise the answer closes with — that the
                // identical re-run passes — so where it does not land the answer is not given either: the
                // call goes through and the context reads what it asked for, which is the one failure this
                // mechanism can absorb (``SiftMCP/AdviceLedger/noteDenial(session:command:)``).
                // Recorded under exactly the lookups whose answers were served — every statement the answer stands
                // for, and no lookup it dropped — so the identical re-run finds every one of them sanctioned.
                guard lookup.keys(answeredBy: inPlace).allSatisfy({ ledger.noteDenial(session: context.key, command: $0) }) else {
                    return (nil, Verdict(token: "allowed", rule: "ledger"))
                }
                // An answer leaving an alternation's prose to a search is logged under a rule of its own, so how
                // often it fires can be counted beside what followed it.
                if case let .symbols(names, _, uncovered, _, _) = inPlace.call, !uncovered.isEmpty {
                    suppressions.note(symbol: names.joined(separator: " "), directory: directory, rule: "partialAlternation", call: payload["tool_use_id"] as? String)
                }
                // Recorded like any other call taken, so rule 1 does not go on offering this context the very
                // digest it was just handed in place: spelled the same way ``callsMade`` spells one, and
                // pinned to the tree it actually answered from.
                // A digest the answer showed to have resolved nothing locates no file, so the ledger does not hold it
                // as one (``DigestMiss``): the answer is the one place this ledger can see what a digest served.
                let resolvedNothing = answered.calls.count == 1 && DigestMiss.isMiss(inAnswer: answered.reason)
                ledger.noteIndexCall(
                    session: context.key,
                    calls: IndexSuggestion.rooted(answered.calls.map { "\($0.tool) \($0.target)" }, at: answered.root),
                    digests: [answered.root: resolvedNothing ? [] : answered.calls.filter { $0.tool == "digest" }.map(\.target)],
                    toolUseID: payload["tool_use_id"] as? String,
                    madeByHook: true
                )
                for call in answered.calls {
                    usage?.record(
                        tool: call.tool,
                        target: call.target,
                        root: answered.root,
                        milliseconds: answered.milliseconds,
                        succeeded: true,
                        answer: call.bytes,
                        agent: payload["agent_id"] as? String,
                        session: session,
                        via: "hook",
                        // A `where` answered in place locates what it listed, as the server's own answer does.
                        located: DigestedFiles.locatedFiles(inAnswer: answered.reason, tool: call.tool),
                        miss: call.tool == "digest" && resolvedNothing
                    )
                }
                // Several reads answered together are named as the calls that answered them: the suggestion
                // names the first read alone, and a probe would read that as the others left unanswered. Read
                // back off the reason's own opening line rather than rebuilt from `answered.calls`, so the
                // verdict line never disagrees with the calls the reason itself names — already spelled for
                // Bash where the server is gone, exactly as the single-call line is.
                // A names answer for a search of named files is its `where`s, whatever the offer made of one file
                // was, so it is named the same way.
                var answeredAsNames = false
                if case .symbols = inPlace.call {
                    answeredAsNames = true
                }
                // A single lookup names the call the answer itself names (the file path, with `--root` where
                // one is needed), not the suggestion's shorter spelling of it; the suggestion stands only where
                // the reason carries no opening line to read.
                let named = InPlaceAnswer.calls(inOpeningLine: answered.reason.prefix { $0 != "\n" })
                let terse = inPlace.lookups > 1 || answeredAsNames
                    ? TerseCall.joining(named ?? answered.calls.map { "\($0.tool) \($0.target)" })
                    : TerseCall.call(
                        naming: named.map { TerseCall.joining($0) } ?? TerseCall.call(for: lookup.suggestion, serverGone: gone),
                        moreCalls: answered.calls.count - (named?.count ?? 1)
                    )
                return (
                    HookOutput.preToolUseDenial(reason: answered.reason),
                    Verdict(token: "in-place", call: terse, rule: lookup.rule, reason: answered.reason)
                )
            case var .withheld(why):
                // A line let run whole for its other statements is judged by what its Swift leg would have met alone:
                // a leg that would have been answered is the batched miss, and handed its call; one withheld alone —
                // on worth or for any other reason — is logged under that rule instead, as it would have been alone.
                if why == .otherStatementsRun, let alone = inPlace.alone {
                    (why, batchedNote) = judgedAlone(alone, payload: payload, remaining: timeBudget - Date().timeIntervalSince(started)) { answerer($0, true, $1) }
                }
                // Logged beside every other withholding, so a budget that bites too often shows in a rate.
                suppressions.note(symbol: why.rawValue, directory: directory, rule: "answerWithheld", call: payload["tool_use_id"] as? String)
                withheldReason = why
            }
        }
        // **The one bare refusal left.** A `sift run --` wrapping is not a Swift lookup the economics above were
        // measured on: nothing here can be answered in place — there is no digest of a build — and what the
        // refusal spares is not a resolved answer but a whole build or test log, priced in the tens of
        // thousands of tokens against the round trip's few thousand. The wrapping keeps its one-shot refusal.
        if lookup.rule == "RunAdvice" {
            guard ledger.noteDenial(session: context.key, command: lookup.key) else {
                return (nil, Verdict(token: "allowed", rule: "ledger"))
            }
            let reason = Self.reason(for: lookup.suggestion)
            return (
                HookOutput.preToolUseDenial(reason: reason),
                Verdict(token: "deny", call: TerseCall.call(for: lookup.suggestion, serverGone: serverGone()), rule: lookup.rule, reason: reason)
            )
        }
        // **Answer in place, or allow.** A refusal that only names a call costs a whole round trip — the
        // context re-sent to be told one sentence — against a saving of about a quarter of that, so the shape
        // with no answer in it is let through rather than charged for. What is left is the record: the rule
        // that decided goes in the suppression log, so a gate that never answers shows as a rate, and the
        // transcript scan goes on counting the lookup as one that went around the index, so the audit keeps
        // showing the miss.
        let rule = withheldReason?.rawValue ?? "notAnswerable"
        if withheldReason == nil {
            suppressions.note(symbol: lookup.suggestion.symbol, directory: directory, rule: rule, call: payload["tool_use_id"] as? String)
        }
        // A line let run whole for its other statements still names the call that answers its Swift leg.
        return (withheldReason == .otherStatementsRun ? batchedNote : nil, Verdict(token: "allowed", rule: rule))
    }

    /// What this call is asking for, or `nil` when it is not a lookup the index could have served.
    ///
    /// The two tools are judged by different rules and share only the ledger. `key` is what the ledger remembers, so a re-run of the same read or the same command is recognised as the same request coming back.
    ///
    /// Advice standing on a symbol is only worth a denial when an index this machine knows could answer for it — `where SubagentStart` against a name that lives only in string literals answers "no symbol named", and a wrong denial costs more than none. The check sits here, not in the advisors: `SearchToolAdvice` pins classification and advice as one question.
    ///
    /// The measurement reaches the same verdict independently rather than counting these greps anyway. ``TranscriptScan`` asks the same question of a finished transcript and scores such a search as a *text search*, which ``TranscriptTally/total`` leaves out of the share and `sift audit` reports on a row of its own. A search this declined to claim it could have served is not a lookup the index lost, and saying so in one place while counting it in the other would make the share an argument with itself.
    ///
    /// The last gate is the only one here about the *tree* rather than the question (``SiftMCP/RepositoryIndex``). A repository with no index of its own is not one of them, and deliberately: whatever answers builds the index it needs, and the hook's own time budget and back-off are what bound that, not a rule about the tree. `Docs/Design.md` has the measurements and what the rule cost while it stood.
    ///
    /// `allowed` answers which of a shell line's lookup keys the ledger already allows a re-run of (``SiftMCP/AdviceLedger/rerunsAllowed(session:among:)``), asked only of a line with more than one lookup on it: the lookup this is about is the first of them not already allowed, so a new lookup riding behind an allowed one is not waved through on its allowance. Nor is it answered: the allowed one still prints, and a denial would swallow its output, so the answer is withheld and the line runs (`otherStatementsRun`). The default allows none, which is the line's first lookup, as it always was.
    static func lookup(
        command: String?,
        payload: [String: Any],
        in directory: String? = nil,
        noting suppressions: SuppressionLog = .standard(),
        digested: DigestedFiles = .standard(),
        couldAnswer: (String, String?) -> Bool = { AdvisableName.couldAnswer($0, from: $1) },
        resolvingDigests resolve: (String, String) -> String? = { SiblingIndexProbe.declaringFile(named: $0, atRoot: $1) },
        allowed: ([String]) -> Set<String> = { _ in [] }
    ) -> Lookup? {
        guard var lookup = classified(command: command, payload: payload, in: directory, allowed: allowed) else {
            // Three rules silence the hook without any suggestion ever being built, so they reach no other gate —
            // and no share counts what any lets through: a toolchain run is a write, and a search of another
            // revision's tree is no lookup at this end or the scan's. That leaves the fire rate as the only
            // evidence there will be that none is over-firing.
            if let shell = shellText(command: command, payload: payload) {
                if let rule = RunAdvice.silencedAsAGateLeg(shell) ? "gateLeg" : RunAdvice.silencedAsAQuietLinter(shell) ? "quietLinter" : nil {
                    suppressions.note(symbol: nil, directory: directory, rule: rule, call: payload["tool_use_id"] as? String)
                } else if ShellInspection.searchesAnotherRevision(shell, in: directory) {
                    suppressions.note(symbol: nil, directory: directory, rule: "anotherRevision", call: payload["tool_use_id"] as? String)
                }
            }
            return nil
        }
        // A whole read of a file this context has already had digested would be refused with the digest it was
        // served: nothing new, for a round trip priced at the whole context. It is let through, and still counted,
        // as a read whole after its digest (`DigestedFiles`), even where the file has changed since, which nothing
        // here can tell from a rewrite of the same text, and where the read prints the current source anyway. A window of such a file is the second half of the loop
        // the digest began, and is no lookup at all: dropped from a line of several reads, whose rest runs beside
        // the lines it prints (`droppingReads`), and let through with nothing noted where nothing else is left. The
        // whole read is dropped from such a line too, rather than answered with the digest the context was served.
        if let session = payload["session_id"] as? String {
            let agent = payload["agent_id"] as? String
            /// A window is excused by a digest that only locates the file, line-range target included; a whole read needs the file's own whole-file digest.
            func located(_ path: String) -> Bool {
                digested.locates(path, session: session, agent: agent, resolve: resolve)
            }
            func wholeDigest(_ path: String) -> Bool {
                digested.contains(path, session: session, agent: agent, resolve: resolve)
            }
            /// What locates the file excuses a window no wider than ``ListedWindow/widestExcused``; a wider one is the file read through a window, judged as a cold one is unless the file's whole digest has already handed the context its member map.
            func located(_ path: String, through windows: [LineWindow]) -> Bool {
                guard located(path) else { return false }
                return !ListedWindow.isWide(windows, ofFileAt: path) || wholeDigest(path)
            }
            // A read let through standing alone: a located window, or a whole read of a file whose whole digest the
            // context holds. Beside other reads it still prints its source, so it is dropped and the rest runs.
            let alone = { (path: String, windows: [LineWindow], windowed: Bool) in windowed ? located(path, through: windows) : wholeDigest(path) }
            if let inPlace = lookup.inPlace, inPlace.windowed.contains(true) || inPlace.calls.count > 1 {
                if let rest = inPlace.droppingReads(where: alone) {
                    let keys = { (match: InPlaceShape.Match) in Set(match.statements.joined().compactMap { lookup.statementKeys[$0] }) }
                    lookup.usageLogHeldKeys = keys(inPlace).subtracting(keys(rest))
                    lookup.inPlace = rest
                } else if !inPlace.windowed.allSatisfy(\.self) {
                    suppressions.note(symbol: nil, directory: directory, rule: "alreadyDigested", call: payload["tool_use_id"] as? String)
                    return nil
                } else {
                    // Nothing answered is left, but a lookup no answer covers may be — a grep whose output is
                    // filtered. The line is judged by that one, as though the windows had been allowed re-runs,
                    // and is no lookup only where the windows were all there was.
                    let windows = Set(inPlace.statements.joined().compactMap { lookup.statementKeys[$0] })
                    guard !windows.isEmpty,
                          let beside = classified(command: command, payload: payload, in: directory, allowed: { allowed($0).union(windows) }),
                          !windows.contains(beside.key)
                    else { return nil }
                    lookup = beside
                    lookup.inPlace = beside.inPlace?.droppingReads(where: alone)
                }
            } else if lookup.isWindow {
                let paths = lookup.readPaths(from: directory)
                // A ranged `Read`'s window is the one its answer would weigh; a shell line no answered shape covers has none read off it.
                let windows = lookup.readPath == nil ? [] : lookup.inPlace?.calls.first?.windows ?? []
                if !paths.isEmpty, paths.allSatisfy({ located($0, through: windows) }) {
                    return nil
                }
            } else if case let paths = lookup.readPaths(from: directory), !paths.isEmpty, paths.allSatisfy(wholeDigest) {
                // A whole `Read`, or a shell line whose reads are all of such files (`cat`, `cat A; echo done`), is let
                // through as the ledger's held digest lets it; a lookup beside it is logged under the rule that
                // withholds it, never answered, as there.
                if let beside = Self.lookup(besideReadsOf: lookup, command: command, payload: payload, in: directory, allowed: allowed) {
                    _ = worthAsking(beside, in: directory, noting: suppressions, call: payload["tool_use_id"] as? String, couldAnswer: couldAnswer)
                }
                suppressions.note(symbol: nil, directory: directory, rule: "alreadyDigested", call: payload["tool_use_id"] as? String)
                return nil
            }
        }
        guard let asked = worthAsking(lookup, in: directory, noting: suppressions, call: payload["tool_use_id"] as? String, couldAnswer: couldAnswer) else {
            return nil
        }
        // A whole read of a document the latest prompt names is a read the context was told to make, so the outline
        // would only precede the identical re-run: let through untouched, uncounted as every document read is. Run
        // only here, once every other gate has not already withheld or answered the read some more specific way, so
        // a read those gates would allow anyway never pays the backwards scan of the transcript.
        if let path = asked.readPath, !asked.isWindow, MarkdownOutline.names(path), LatestPrompt.ofCall(payload)?.names(path, cwd: directory) == true {
            suppressions.note(symbol: nil, directory: directory, rule: "namedInPrompt", call: payload["tool_use_id"] as? String)
            return nil
        }
        return asked
    }

    /// Everything the hook does with a call that *is* the advice being taken, and what it should print.
    ///
    /// Three things, none of them a judgement about the call — the hook has no opinion about an index call and never denies one. It writes down that this context reached the index, which is the one thing that restores its unheeded run, and *what it asked*, which is what lets a later refusal tell an offer this context has already taken up from one with something to say; it writes down *which* context, because this is the only moment on the machine where an index call and the conversation that made it are visible together; and it pins the call to the caller's own repository, which is the only thing here that changes the call rather than observing it — unless `serverDirectory`, where the server was started, shows the pin would change nothing.
    ///
    /// One function rather than three statements inside `run`, so that what a test exercises is what the hook does. Split across the call site, each piece would have cover and their composition none — and the composition is the part that can be dropped without any of them failing.
    static func adviceTaken(
        session: String,
        context: AdviceContext,
        payload: [String: Any],
        command: String? = nil,
        cwd directory: String?,
        serverDirectory: String? = nil,
        ledger: AdviceLedger = .standard(),
        callers: CallAttribution = .standard()
    ) -> String? {
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        ledger.noteIndexCall(
            session: context.key,
            calls: IndexSuggestion.callsMade(
                toolName: payload["tool_name"] as? String,
                input: input,
                command: Self.shellText(command: command, payload: payload),
                root: CallerRoot.statedRoot(toolName: payload["tool_name"] as? String, input: input) ?? CallerRoot.root(forCallerIn: directory)
            ),
            digests: digestsAsked(toolName: payload["tool_name"] as? String, input: input, command: command, cwd: directory),
            toolUseID: payload["tool_use_id"] as? String
        )
        noteCaller(session: session, payload: payload, command: command, into: callers)
        guard let amended = CallerRoot.amendment(
            toolName: payload["tool_name"] as? String,
            input: input,
            cwd: directory,
            serverDirectory: serverDirectory
        ) else {
            return nil
        }
        return HookOutput.preToolUseAmendment(input: amended)
    }

    /// Records the file a write or an edit puts in this context, answering whether the call was one.
    ///
    /// The hook has no opinion about the call itself and lets it through; what it keeps is that this context holds the file's text, so a later read of the file is a revisit rather than a lookup. A relative path is spelled out against the call's directory, as a read's is.
    static func notesWrite(context: AdviceContext, payload: [String: Any], cwd directory: String?, ledger: AdviceLedger = .standard()) -> Bool {
        guard LookupTool.writes(payload["tool_name"] as? String ?? "") else { return false }
        if let path = LookupTool.readPath(in: payload["tool_input"] as? [String: Any] ?? [:]),
           let file = SwiftTree.resolve(path, relativeTo: directory)
        {
            ledger.noteWritten(session: context.key, path: file)
        }
        return true
    }

    /// Leaves the identity of the context making this call for the server to stamp on the log line.
    ///
    /// For a call to this server's MCP tools, and for each query subcommand a Bash command runs — the shell half of `takesTheAdvice`, a *different process* that writes its own log line and claims its slip by its own argv, filed under a face no MCP tool has (``SiftMCP/CallAttribution/cliFace``), so neither half can take the other's. Any other `sift` in Bash — `sift run`, `sift usage` — logs no lookup and gets no slip.
    ///
    /// The session key is the raw `session_id` and not ``AdviceContext``'s per-agent key, because the server can only look this up by what its own environment tells it, which is the session. The agent is what the slip *carries*, not what it is filed under.
    ///
    /// Written for a parent's call as well, with no agent on it. That is not a wasted write: it displaces a subagent's earlier slip, so a parent's call can never claim an attribution that was not its own.
    static func noteCaller(session: String, payload: [String: Any], command: String? = nil, into store: CallAttribution = .standard()) {
        let agent = payload["agent_id"] as? String
        guard let name = payload["tool_name"] as? String, let tool = IndexToolName.tool(named: name) else {
            let shell = shellText(command: command, payload: payload) ?? ""
            for arguments in IndexCallTarget.cliLookups(inCommand: shell) {
                store.note(session: session, agent: agent, arguments: arguments)
            }
            return
        }
        store.note(
            session: session,
            agent: agent,
            tool: tool,
            target: IndexCallTarget.of(payload["tool_input"] as? [String: Any] ?? [:], tool: tool)
        )
    }

    /// The shell command this call carries, from the flag or from the payload — the one place that pair is read.
    private static func shellText(command: String?, payload: [String: Any]) -> String? {
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        guard let shell = command ?? input["command"] as? String, !shell.isEmpty else { return nil }
        return shell
    }

    /// The `PreToolUse` payload Claude Code writes to the hook's stdin.
    ///
    /// Guarded by `isatty` so running this by hand returns immediately instead of blocking on a read that will never be satisfied.
    private func hookPayload() -> [String: Any] {
        guard isatty(FileHandle.standardInput.fileDescriptor) == 0,
              let data = try? FileHandle.standardInput.readToEnd(), !data.isEmpty,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return payload
    }
}

extension PreToolUseCommand {
    /// Whether this call *is* the advice being taken — an index call, or the tool's own CLI.
    ///
    /// The two ways there are to take it, which is exactly the pair two log files record: `usage.jsonl` for an index call and `run.jsonl` for a wrapped build. Read here instead of off those logs, they are attributable to the context that made them, because the payload names the session and the agent and a log line names neither.
    ///
    /// The shell half is any invocation of the binary, not just `sift run --`. A context reaching for `sift where` in Bash is a context taking the advice by the only route left to it once an allowlist has stripped the MCP server — which is precisely the context this must not go on to quiet — wherever the shell runs it, a command substitution's body included, and read by ``SiftMCP/ShellInspection/invokesSift(_:)``, the one definition the scan and the advisor ask too.
    ///
    /// **Answering `true` here ends the hook's turn, and that is the one place the measurement is knowingly allowed to see a miss this cannot.** `sift where Foo; grep -rn Bar Sources/` is a single Bash call that both reaches the index and goes around it. This returns on the first half, because denying anything on a call that is *also* an index call is the one thing this hook may not do — so the grep is never classified and never refused. ``SiftMCP/TranscriptScan`` counts it anyway. The rule that says the two must agree is about a search the tool *declined to claim it could serve* (see ``lookup(command:payload:in:noting:)``): counting one of those would be the metric arguing with the hook about what a lookup is. This is the other thing — nothing declined it, the hook simply never looked — and a cold lookup dropped from the denominator raises the share, which ``SiftMCP/TranscriptTally`` may never do. Such compounds are no tiny fraction — a replay left 175 of some 800 cold lookups cold on lines like it, 22% — so the divergence is named here for what it is, and what it moves is not small.
    ///
    /// **One shape inside that fraction is governed by ``SiftMCP/TextSearch`` instead, and it is worth saying so rather than letting the paragraph above quietly stop being true.** `sift where Foo; grep -rn "0\.1\.0" Sources --include=*.swift` is such a compound whose grep half is a search the advisor declares unanswerable, so the scan scores it `.textSearch` and it leaves the denominator. That is the *first* rule and not this exception: the question was declined, and a declined question leaving the share is what every other declined question does. What this paragraph protects is a cold lookup being dropped, and a text search was never one.
    static func takesTheAdvice(command: String?, payload: [String: Any]) -> Bool {
        if let name = payload["tool_name"] as? String, IndexToolName.tool(named: name) != nil {
            return true
        }
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        guard let shellCommand = command ?? input["command"] as? String, !shellCommand.isEmpty else {
            return false
        }
        return ShellInspection.invokesSift(shellCommand)
    }

    /// `run`'s decision for a call that is neither an index call nor a write: the call classified, then decided, with the terse verdict a probe reads.
    ///
    /// A call let through as no lookup after a gate withheld it is named by that gate's rule, the one the suppression log at `suppressions` records (`unknownName`), so a probe reads the same name the log does. Only the verdict changes: the log is written exactly as without it.
    static func decided(
        command: String?,
        payload: [String: Any],
        cwd directory: String?,
        session: String?,
        context: AdviceContext,
        ledger: AdviceLedger = .standard(),
        usage: UsageLog? = .standard(),
        suppressions: URL = SuppressionLog.standardFileURL,
        runPermission: (_ directory: String?) -> WrappedRunPermission = WrappedRunPermission.standard(in:),
        couldAnswer: (String, String?) -> Bool = { AdvisableName.couldAnswer($0, from: $1) }
    ) -> (json: String?, verdict: Verdict) {
        let noted = NotedRule()
        let log = SuppressionLog(fileURL: suppressions, noted: noted.record)
        let letThrough = { Verdict(token: "allowed", rule: noted.last ?? "noLookup") }
        guard let lookup = lookup(
            command: command,
            payload: payload,
            in: directory,
            noting: log,
            couldAnswer: couldAnswer,
            allowed: { ledger.rerunsAllowed(session: context.key, among: $0) }
        ) else {
            return (nil, letThrough())
        }
        let decided = outcome(
            to: lookup,
            session: session,
            context: context,
            payload: payload,
            command: command,
            cwd: directory,
            ledger: ledger,
            usage: usage,
            suppressions: log,
            runPermission: runPermission,
            couldAnswer: couldAnswer
        )
        return decided.verdict.rule == "noLookup" ? (decided.json, letThrough()) : decided
    }

    /// Whether `target` — a path an offered `digest` would be answered by reading — sits where no root can be resolved for it.
    ///
    /// The file has to be there before the tree it sits in is anybody's claim: a target naming no file is a read that fails on its own, and a hook that withheld on it would be judging a tree it never found. Resolved against the call's own working directory exactly as ``SiftMCP/RepositoryIndex`` resolves the same path, so a repo-relative target is asked about where the caller stands and not where this process was started.
    private static func cannotBeRooted(_ target: String, in directory: String?) -> Bool {
        guard let resolved = SwiftTree.resolve(target, relativeTo: directory),
              FileManager.default.fileExists(atPath: resolved) else { return false }
        return RepositoryIndex.isRootless(for: resolved)
    }

    /// The payload the hook judges, in Claude Code's form, or `nil` where it prints nothing: a Cursor payload under the Claude Code registration, and one the Cursor registration cannot read.
    private func read(_ payload: [String: Any]) -> [String: Any]? {
        switch agent {
        case .claude:
            return Self.standsAsideForCursor(payload, verdict: verdict) ? nil : payload
        case .cursor:
            guard let read = command == nil ? CursorPreToolUse.claudePayload(from: payload) : payload else {
                if verdict {
                    StandardStreams.emit(Verdict(token: "allowed", rule: "unread").line)
                }
                return nil
            }
            return read
        }
    }

    /// Whose rules decide that a build's rewrite costs no prompt: Claude Code's say nothing of what Cursor prompts for, so on Cursor a build is refused with its wrapping rather than rewritten.
    private var runPermission: (String?) -> WrappedRunPermission {
        guard agent == .cursor else { return WrappedRunPermission.standard(in:) }
        return { _ in WrappedRunPermission(allowed: [], vetoed: []) }
    }

    /// Prints the hook's `output` in the protocol of the harness it is registered for: as written for Claude Code, and read into Cursor's schema for Cursor, where what that schema cannot carry prints nothing.
    private func answer(_ output: String, toolName: String?) {
        guard agent == .cursor else {
            StandardStreams.emit(output)
            return
        }
        if let response = CursorPreToolUse.response(to: output, toolName: toolName) {
            StandardStreams.emit(response)
        }
    }

    /// Whether `payload` is Cursor's, which shows a refusal to the user rather than the model (`CursorHookPayload`), so the hook prints nothing; a probe is told why.
    private static func standsAsideForCursor(_ payload: [String: Any], verdict: Bool) -> Bool {
        guard CursorHookPayload.recognises(payload) else { return false }
        if verdict {
            StandardStreams.emit(Verdict(token: "allowed", rule: "cursor").line)
        }
        return true
    }

    /// A build rewritten in place to its `sift run --` wrapping, a build let through untouched because the user's own ask or deny rule speaks for the line, or `nil` where `lookup` is no build or the rewrite could cost the user a prompt.
    ///
    /// The command runs wrapped in the same turn, with no permission decision made here, so the user's own rules still apply — to the rewritten command, which is why the rewrite waits on ``SiftMCP/WrappedRunPermission``. It interrupts nothing, so it neither consults nor spends the ledger, and every run of the build is rewritten, the loop's repeats included. A line the shell would not run as written is never rewritten.
    ///
    /// Where an ask or deny rule matches anything the line runs as written, the build is neither rewritten nor refused with its wrapping named: either would hand the model a command that rule, written for the original, does not match. It is let through, so Claude Code applies the rule to the command it was written for.
    private static func rewrite(
        _ lookup: Lookup,
        command: String?,
        payload: [String: Any],
        in directory: String?,
        suppressions: SuppressionLog,
        permission: () -> WrappedRunPermission
    ) -> (json: String?, verdict: Verdict)? {
        guard lookup.rule == "RunAdvice", let shell = shellText(command: command, payload: payload) else { return nil }
        let permission = permission()
        if permission.vetoes(line: shell) {
            suppressions.note(symbol: nil, directory: directory, rule: "vetoed")
            return (nil, Verdict(token: "allowed", rule: "vetoed"))
        }
        guard !ShellSyntax.isIncomplete(shell),
              permission.addsNoPrompt(legs: RunAdvice.wrappedLegs(of: shell), mode: payload["permission_mode"] as? String)
        else { return nil }
        var input = payload["tool_input"] as? [String: Any] ?? [:]
        input["command"] = lookup.suggestion.call
        return (
            HookOutput.preToolUseAmendment(input: input),
            Verdict(token: "amended", call: TerseCall.call(for: lookup.suggestion, serverGone: false), rule: lookup.rule)
        )
    }

    /// The wrapping's own refusal text — the one place this template still runs, now that a lookup answers in place or is let through instead.
    ///
    /// The opening line and the escape hatch come from the suggestion, and the invariant middle names the call and what it yields. Every line of the call is indented, not just the first. A suggestion is a rebuild of the whole command the caller wrote, so a command spanning several lines produces a call that does too — and interpolating that into one indented slot would leave the continuation flush against the margin, reading as prose rather than as part of the command being offered.
    ///
    /// No Bash note and no server-gone spelling: a wrapping already runs from Bash, so neither question this template once answered for a lookup's refusal arises here.
    static func reason(for suggestion: IndexSuggestion) -> String {
        let call = suggestion.call
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : "    \($0)" }
            .joined(separator: "\n")
        return """
        \(suggestion.offer)

        \(call)
            → \(suggestion.yields)

        \(suggestion.escapeHatch) That re-run returns the command's whole output. This asks once per command.
        """
    }

    /// The Swift leg `alone` of a line let run whole for its other statements, judged by what it would meet alone within `remaining` seconds, weighed as a read alone is (``WholeReadWorth/weighing(_:of:payload:)``): `otherStatementsRun` and the note naming its calls where `answer` answers it and the answer is worth the turn, or the withholding it meets alone and no note.
    ///
    /// `answer` is asked to spell its calls for Bash, as the server's absence spells them: the note names calls to put on a shell line.
    private static func judgedAlone(
        _ alone: InPlaceShape.Match,
        payload: [String: Any],
        remaining: TimeInterval,
        answer: (InPlaceShape.Match, TimeInterval) -> InPlaceAnswerer.Outcome
    ) -> (why: InPlaceAnswerer.Withholding, note: String?) {
        guard remaining > 0 else { return (.overTime, nil) }
        return switch WholeReadWorth.weighing(answer(alone, remaining), of: alone, payload: payload) {
        case let .answered(answered):
            (.otherStatementsRun, batchedLegNote(for: answered, of: alone))
        case let .withheld(why):
            (why, nil)
        }
    }

    /// The one line of context a compound line let run whole is handed: the sift calls that answered its Swift leg alone, to put on the line in place of the read or the search, as a hook output that decides nothing.
    ///
    /// The calls are the ones the answer's own opening line names, spelled for Bash, so they name what the answer was computed from — a file by its path in the tree it resolved in — and carry `--root` where that tree is not the one the leg's directory stands in.
    private static func batchedLegNote(for answered: InPlaceAnswerer.Answered, of leg: InPlaceShape.Match) -> String? {
        let openingLine = answered.reason.prefix { $0 != "\n" }
        let calls = InPlaceAnswer.calls(inOpeningLine: openingLine) ?? answered.calls.map { "sift \($0.tool) \(ShellWord.quoted($0.target))" }
        guard !calls.isEmpty else { return nil }
        let ownTree = CallerRoot.root(forCallerIn: leg.directory).map(CanonicalPath.of)
        let rooting = ownTree == CanonicalPath.of(answered.root) ? "" : " --root \(ShellWord.quoted(answered.root))"
        let named = calls.map { "`\($0)\(rooting)`" }.joined(separator: ", ")
        // A `cat`, a line window or a `sed` range is a read; a grep of a file or a tree is a search.
        let what = leg.calls.allSatisfy { call in
            if case .memberRange = call {
                return true
            }
            return call.readPath != nil
        } ? "read" : "search"
        // Named by the kind of file read: a Markdown document is not Swift, and a line that reads both is only "the read".
        let documents = leg.calls.filter { $0.shape == .outline }.count
        let kind = what == "search" || documents == 0 ? "Swift " : documents == leg.calls.count ? "Markdown " : ""
        return HookOutput.preToolUseContext("sift: the \(kind)\(what) on this line is answered by \(named) — put that on the line in place of the \(what).")
    }

    /// `lookup`, where the index could have served it with a call that can be made, or `nil` where a rule withholds it, logged under that rule and against `call`, the judged call's `tool_use_id`.
    private static func worthAsking(
        _ lookup: Lookup,
        in directory: String?,
        noting suppressions: SuppressionLog,
        call: String?,
        couldAnswer: (String, String?) -> Bool = { AdvisableName.couldAnswer($0, from: $1) }
    ) -> Lookup? {
        // The advisor built a suggestion because the miss is real and the metric must go on counting it;
        // what this adds is that the index could not have served *this* question — a count, a sweep whose
        // pattern names nothing, prose on one file, a literal, a merge's markers, a tree no index holds
        // (`TextSearch`). Withheld here rather than in the advisor so that both ends still answer together,
        // and logged under the rule that decided, like every other withholding.
        if let reason = lookup.textSearch {
            suppressions.note(symbol: lookup.suggestion.symbol, directory: directory, rule: reason.rawValue, call: call)
            return nil
        }
        // A refusal has to offer a call that can be made, and a bare `search` asks the caller to write the query
        // the advisor could not. It is built only where no index call answers the lookup — a phrase of ordinary
        // words, or an alternation with one in it (`SweepPattern`) — so the scan scores it out of the share on the
        // same property, and the two ends still agree.
        if !lookup.suggestion.namesATarget {
            suppressions.note(symbol: nil, directory: directory, rule: "untargeted", call: call)
            return nil
        }
        // Several names are one `where` per name of an alternation — as many questions as the caller asked — and
        // a `where` for a name no index declares answers "no symbol named". So the ask is answered whole or not
        // at all: where any of the names is undeclared the hook says nothing and the search runs
        // (`partlyDeclared`). Offering the declared subset instead would answer a question nobody asked, and
        // silently — the caller wanted every branch, and the narrowing appears nowhere in the refusal. Staying
        // quiet costs nothing, because the search the advice would have interrupted simply goes through; wrong
        // advice is the expensive failure here, not a missed nudge. One file's digest standing on several names
        // (`IndexSuggestion.forSearch`) is not that shape and would not be narrowed here: it answers for the file
        // whatever the names are, so one declared name among them would be enough. Nothing reaches this gate in
        // that shape, though — an alternation confined to the files it names is withheld a rule earlier, on the
        // price of the offer rather than on the names (`TextSearch.Reason.severalNames`). The scan asks the same
        // of both.
        let symbols = lookup.suggestion.symbols
        if !symbols.isEmpty {
            let declared = symbols.filter { couldAnswer($0, directory) }
            guard !declared.isEmpty else {
                suppressions.note(symbol: symbols.joined(separator: " "), directory: directory, rule: "unknownName", call: call)
                return nil
            }
            if lookup.suggestion.isOneCallPerName, declared.count < symbols.count {
                suppressions.note(symbol: symbols.joined(separator: " "), directory: directory, rule: "partlyDeclared", call: call)
                return nil
            }
        }
        // No repository, no root: the one tree rule (``SiftMCP/RepositoryIndex/isRootless(for:relativeTo:)``),
        // and the general form of the invariant every advisor states — a refusal has to offer a call that can
        // be made. An unindexed checkout can answer the offered call, because the call indexes it on the way —
        // measured in tenths of a second, and bounded by the hook's own time budget rather than by a gate
        // here. A path standing outside every repository never can, because a call naming a *path* is answered
        // by reading that exact path under a root, and a path with no repository above it resolves none. The
        // answer is `… is in no repository to root at — read it directly`, so the refusal would deny the read
        // and then charge a whole context re-send to ask for it.
        //
        // Asked of the call's own targets rather than of the lookup's anchor, which is what keeps it a claim
        // about the offer: `digest View` names a symbol and is answered out of whatever index the caller's own
        // root resolves to, wherever the file read happened to sit, while `digest /notes/Plan.md` can be
        // answered nowhere. A document is the everyday case, since a `.md` target is always its own path —
        // vault notes, rule files, a plan in a home directory — and the Swift analogue is the same rule.
        //
        // The rule takes nothing out of the share: the lookup still went around an index that could have held
        // it, and the scan goes on counting it. What it decides is only whether the hook spends a turn.
        //
        // Asked only of a path that is *there*. The claim is about the tree a file sits in, and a path naming no
        // file names no tree to make it about — the read is about to fail on its own, and withholding on a
        // judgement the disk cannot support is the one direction this rule must not err in. It is the same
        // preference every gate here has on doubt: say nothing about what cannot be judged, refuse as before.
        if lookup.suggestion.pathTargets.contains(where: { Self.cannotBeRooted($0, in: directory) }) {
            suppressions.note(symbol: nil, directory: directory, rule: "noRepository", call: call)
            return nil
        }
        // A whole read of a small document is let through: the outline would save a fraction of a read that
        // small, and a wrong guess — the caller wanted the exact text — costs the outline, the file and a round
        // trip over the whole context (``SiftMCP/ReadAdvice/isSmallDocument(_:)``). Asked last, so it is logged
        // only where no other rule had already withheld the read.
        if let path = lookup.readPath, ReadAdvice.isSmallDocument(path) {
            suppressions.note(symbol: nil, directory: directory, rule: "smallDocument", call: call)
            return nil
        }
        return lookup
    }

    /// The lookup beside the reads `reading` let through — a grep whose output is filtered — classified with those reads and the re-runs `allowed` names allowed, or `nil` where the reads were all the line asked.
    ///
    /// Only ever logged under the rule that withholds it, never answered: an answer would deny the reads as well.
    private static func lookup(besideReadsOf reading: Lookup, command: String?, payload: [String: Any], in directory: String?, allowed: ([String]) -> Set<String>) -> Lookup? {
        let keys = Set(reading.inPlace?.statements.joined().compactMap { reading.statementKeys[$0] } ?? []).union(reading.usageLogHeldKeys)
        guard !keys.isEmpty, let beside = classified(command: command, payload: payload, in: directory, allowed: { allowed($0).union(keys) }), !keys.contains(beside.key) else { return nil }
        return beside
    }

    /// The line `command` or `payload` carries classified again with `keys` — the statements of reads this context already holds — allowed as re-runs beside the ledger's own, or `nil` where those reads were all it asked.
    private static func lookup(besideReads keys: Set<String>, command: String?, payload: [String: Any], in directory: String?, context: AdviceContext, ledger: AdviceLedger) -> Lookup? {
        guard !keys.isEmpty,
              let beside = classified(command: command, payload: payload, in: directory, allowed: { ledger.rerunsAllowed(session: context.key, among: $0).union(keys) }),
              !keys.contains(beside.key)
        else { return nil }
        return beside
    }

    private static func classified(
        command: String?,
        payload: [String: Any],
        in directory: String? = nil,
        allowed: ([String]) -> Set<String>
    ) -> Lookup? {
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        let tool = command == nil ? LookupTool.rule(for: payload["tool_name"] as? String ?? "") ?? "" : "Bash"

        switch tool {
        case "Bash":
            guard let shellCommand = command ?? input["command"] as? String, !shellCommand.isEmpty else {
                return nil
            }
            // Built once and handed to both readings, so the tree is walked once per call rather than
            // once per question asked about it.
            let holdsSource = SwiftTree.probe(relativeTo: directory)
            // A lookup first, and a toolchain run only if it was not one. They cannot both match — a
            // `swift build` is a write to `ShellInspection` long before it could be a lookup — and asking
            // in this order keeps that an invariant rather than a coincidence of two advisors' rules.
            // A line of several lookups is about the first one the ledger has not already allowed: every fact
            // below is drawn from that one, so a new lookup behind the re-run of an allowed one is advised on
            // as itself; the allowed one still prints, so the line runs rather than being answered. The ledger is asked only where there is a choice to
            // make, so a line of one lookup reads nothing more than it ever did.
            let keys = ShellAdvice.lookupKeys(for: shellCommand, holdsSource: holdsSource)
            let sanctioned = keys.count > 1 ? allowed(keys) : []
            if let suggestion = ShellAdvice.suggestion(
                for: shellCommand,
                holdsSource: holdsSource,
                directory: directory,
                skipping: sanctioned
            ) {
                // The re-run this refusal promises is recognised by the reading stage alone — pattern, flags
                // and paths — never by the whole line, so a retry that only changes what rides beside the
                // grep is still the same ask. Falls back to the whole command only where the key could not
                // be drawn from a stage, which `suggestion` having matched makes unreachable in practice.
                let key = ShellAdvice.lookupKey(for: shellCommand, holdsSource: holdsSource, skipping: sanctioned)
                    ?? AdviceLedger.key(forShell: shellCommand)
                let inPlace = ServedReading.match(forShell: shellCommand, in: directory, holdsSource: holdsSource, skipping: sanctioned)
                return Lookup(
                    key: key,
                    suggestion: suggestion,
                    textSearch: ShellAdvice.textSearchReason(shellCommand, holdsSource: holdsSource, cwd: directory, skipping: sanctioned),
                    searchPath: ShellAdvice.namedPath(for: shellCommand, holdsSource: holdsSource, skipping: sanctioned),
                    inPlace: inPlace,
                    rule: "ShellAdvice",
                    isWindow: ShellAdvice.readsThroughAWindow(shellCommand, holdsSource: holdsSource, skipping: sanctioned),
                    windowPaths: ShellAdvice.windowedReadPaths(shellCommand, holdsSource: holdsSource, cwd: directory),
                    statementKeys: ServedReading.statementKeys(of: inPlace) { ShellAdvice.lookupKey(for: $0, holdsSource: holdsSource) }
                )
            }
            guard let suggestion = RunAdvice.suggestion(for: shellCommand) else { return nil }
            return Lookup(key: AdviceLedger.key(forShell: shellCommand), suggestion: suggestion, textSearch: nil, rule: "RunAdvice")
        case "Grep", "Glob":
            guard let suggestion = SearchToolAdvice.suggestion(tool: tool, input: input, in: directory) else {
                return nil
            }
            // Keyed on the arguments that decide the answer, so the retry is recognised however the tool
            // orders or defaults the rest.
            let pattern = input["pattern"] as? String ?? ""
            let path = input["path"] as? String ?? directory ?? ""
            return Lookup(
                key: "\(tool) \(pattern) \(path)",
                suggestion: suggestion,
                textSearch: SearchToolAdvice.textSearchReason(tool: tool, input: input, in: directory),
                searchPath: (input["path"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                inPlace: InPlaceShape.match(forSearchTool: tool, input: input, in: directory),
                rule: "SearchToolAdvice"
            )
        case "Read":
            guard let path = LookupTool.readPath(in: input) else { return nil }
            // The same reading of "ranged" the transcript scan uses: `limit` alone bounds a read too, and
            // an explicit JSON null is not a range.
            let ranged = input["offset"] is NSNumber || input["limit"] is NSNumber
            // A ranged read of a Swift file is judged as the whole read is, and let through as no lookup once
            // this context has located the file; a document's ranged read stays the advisor's to wave through.
            let window = ranged && path.hasSuffix(".swift")
            guard let suggestion = ReadAdvice.suggestion(path: path, ranged: ranged && !window) else { return nil }
            // A read names a file outright, so of `TextSearch`'s rules only the one about where it points can
            // reach it: a file in a tree no index holds, which the scan scores out of the share on the same verdict.
            return Lookup(
                key: "Read \(path)",
                suggestion: suggestion,
                textSearch: TextSearch.reason(forWholeRead: path, cwd: directory),
                readPath: path,
                inPlace: InPlaceShape.match(forRead: path, in: directory, window: window ? LineWindow(offset: (input["offset"] as? NSNumber)?.intValue, limit: (input["limit"] as? NSNumber)?.intValue) : nil),
                rule: "ReadAdvice",
                isWindow: window
            )
        default:
            return nil
        }
    }

    /// The digest targets an index call asks for, keyed by the repository each is answered from: an MCP `digest`'s targets at its `root`, or each `sift digest` in a Bash command at its `--root` — either one, where it names none, the caller's own repository, which for a Bash call is the one the literal `cd`s in front of it moved to.
    ///
    /// Recorded in the ledger as digests this context holds, which is why a Bash call is read here at all: the CLI's own log line knows the session from its environment but never the agent, so it cannot speak for a subagent.
    static func digestsAsked(toolName: String?, input: [String: Any], command: String? = nil, cwd directory: String?) -> [String: [String]] {
        let callerRoot = CallerRoot.root(forCallerIn: directory)
        if let toolName, IndexToolName.tool(named: toolName) == "digest" {
            // An `at` call answers a past revision, never the working file its target names — recording it
            // here would credit a later whole `Read` of today's file as already digested.
            guard input["at"] == nil else { return [:] }
            // Normalized the way a Bash `--root` is below: a `root` naming a subdirectory of the repository
            // is recorded at the repository itself, so a later read finds the digest under the root the read
            // resolves the same file to, rather than under a spelling nothing else ever matches again.
            guard let root = (input["root"] as? String).flatMap(CallerRoot.root(forCallerIn:)) ?? callerRoot else { return [:] }
            return [root: IndexCallTarget.all(input, tool: "digest")]
        }
        guard toolName == nil || toolName == "Bash", let command = command ?? input["command"] as? String else { return [:] }
        var digests: [String: [String]] = [:]
        for (runsIn, asked) in IndexCallTarget.cliDigests(inCommand: command, from: directory) {
            let named = asked.root.flatMap { SwiftTree.resolve($0, relativeTo: runsIn) }
            let runsInRoot = runsIn == directory ? callerRoot : CallerRoot.root(forCallerIn: runsIn)
            guard let root = named.flatMap(CallerRoot.root(forCallerIn:)) ?? named ?? runsInRoot else { continue }
            digests[root, default: []].append(asked.target)
        }
        return digests
    }

    /// The files an answered `where` or `search` call's `answer` listed, keyed by the repository it was answered from, as the server and the CLI record them in the usage log (`DigestedFiles.locatedFiles`): an MCP call at its `root`, where it names none the caller's own repository, or a Bash line's output where ``SiftMCP/ShellAnswerSource`` can say which repository answered it.
    ///
    /// Read by the replay, which sees an answer only in the transcript. A call as of another revision locates nothing, and neither does a Bash line that is anything but lookups of one repository (a `cd` in front, another command beside them), since its output cannot be pinned to the repository the CLI answered from.
    static func locatedByAnswer(_ answer: String, toolName: String?, input: [String: Any], cwd directory: String?) -> [String: [String]] {
        let callerRoot = CallerRoot.root(forCallerIn: directory)
        if let toolName, let tool = IndexToolName.tool(named: toolName) {
            guard input["at"] == nil,
                  let root = (input["root"] as? String).flatMap(CallerRoot.root(forCallerIn:)) ?? callerRoot
            else { return [:] }
            let files = DigestedFiles.locatedFiles(inAnswer: answer, tool: tool)
            return files.isEmpty ? [:] : [root: files]
        }
        guard toolName == nil || toolName == "Bash", let command = input["command"] as? String,
              let source = ShellAnswerSource.of(command: command, cwd: directory)
        else { return [:] }
        let files = source.locatedFiles(inOutput: answer)
        return files.isEmpty ? [:] : [source.root: files]
    }

    /// A lookup worth interrupting: what to remember it by, and what to offer instead.
    struct Lookup {
        let key: String
        let suggestion: IndexSuggestion
        /// The rule by which the advisor declared this a search the index could not have served (``SiftMCP/TextSearch``), or `nil` where none did.
        ///
        /// Carried on the lookup rather than re-derived at the gate because deriving it means walking the command a second time, and because the answer must be the advisor's own — the whole point of the predicate is that the hook and the metric ask one question. The rule, and not only that there is one, because the hook logs its withholding under the rule's name, and a fire rate pooled across rules says nothing about which one is over-firing.
        let textSearch: TextSearch.Reason?
        /// The file a `Read` names, whole or ranged, which is what decides whether the context already holds its digest; `nil` for every other kind of lookup.
        var readPath: String?
        /// The path a `Grep`/`Glob` or a shell search names explicitly — its own `path` argument, or the file or directory its reading stage is pointed at — `nil` where it names none of its own beyond the working directory.
        ///
        /// What roots the offer for these tools instead of the directory the call happens to run in (``anchor``): a search explicitly pointed at another checkout is aimed at that checkout whatever worktree the session is standing in.
        var searchPath: String?
        /// The call that answers this lookup in the refusal's place, and what answering it stands for — `nil` where the lookup is not one of the answered shapes (``SiftMCP/InPlaceShape``).
        var inPlace: InPlaceShape.Match?
        /// Which advisor classified this lookup — `ShellAdvice`, `RunAdvice`, `SearchToolAdvice` or `ReadAdvice` — carried only for `--verdict`'s third column, and named nowhere a hook payload reaches.
        ///
        /// Required rather than defaulted: all four production constructions set it, so a fifth advisor that forgot to is a compile error here rather than an `unknown` a gate would have to notice in the wild.
        let rule: String
        /// Whether this lookup reads its file through a line window — a ranged `Read`, or a shell window such as `sed -n '1,200p'` — which is answered in place as the whole read is until this context has located the file, and is no lookup from then on.
        var isWindow = false
        /// The file each lookup on a shell line reads through a line window, where every lookup on it is one (``SiftMCP/ShellAdvice/windowedReadPaths(_:holdsSource:)``) — what ``readPaths(from:)`` answers for a line no answered shape covers, so a window of a located file is no lookup in any shell shape.
        var windowPaths: [String] = []
        /// The key each statement `inPlace` or its ordinary reading answers is recognised by on the ledger, for those that are lookups (``SiftMCP/ShellAdvice``).
        var statementKeys: [String: String] = [:]
        /// The keys of the statements whose reads were dropped from this lookup as held through the usage log, which a later classification of the line beside other reads takes as allowed re-runs, so it never offers a digest the usage log says the context holds.
        var usageLogHeldKeys: Set<String> = []
    }

    /// The terse fact `--verdict` prints about a decision already made: the token, the call offered (when one was), and the rule that decided it — one line, tab-separated, nothing else.
    ///
    /// The token set and the separator are documented in `Docs/Design.md`, which a gate quotes.
    struct Verdict {
        let token: String
        var call: String?
        var rule: String?
        /// The denial's reason text, exactly as handed to ``HookOutput/preToolUseDenial(reason:)`` — the answer an in-place denial or a bare deny gives, unset for an allow.
        var reason: String?

        init(token: String, call: String? = nil, rule: String? = nil, reason: String? = nil) {
            self.token = token
            self.call = call
            self.rule = rule
            self.reason = reason
        }

        /// The token alone where neither a call nor a rule is known, and otherwise the fields up to the last one that is — tab-separated, empty where a later field is known and an earlier one is not.
        ///
        /// A field keeps its position whatever is missing, so `cut -f2` is always the call and `cut -f3` always the rule: an `allowed` with a rule and no call is `allowed\t\tledger`, never `allowed\tledger`, which would read as a call named `ledger`. Nothing ever ends in a tab.
        var line: String {
            guard call != nil || rule != nil else { return token }
            guard let rule else { return "\(token)\t\(call ?? "")" }
            return "\(token)\t\(call ?? "")\t\(rule)"
        }
    }
}
