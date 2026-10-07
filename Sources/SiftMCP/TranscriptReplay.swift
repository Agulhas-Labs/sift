//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// `audit --replay`: the window's real lookups put to the advice hook as it stands now, and the share the index would reach if it had answered them.
///
/// A unit test pins one shape, and the share is made of every shape at once, so this is the gate a hook change is judged by: each context is walked in transcript order, every call handed to the hook with the payload the harness would have sent, and the lookups the scan calls cold are counted by what the hook would do with them today.
public struct TranscriptReplay {
    /// The key an answered call's payload carries its answer's text under (``ReplayHook/answered(payload:cwd:at:)``) — one the harness never writes, so a binary that does not read it takes the payload as it always has.
    public static var answerKey: String {
        "sift_answer_text"
    }

    /// The key every replayed call's payload carries the context's latest prompt under as of that call (``LatestPrompt/payloadValue``), empty where none has been read yet — so the hook reads the prompt the call followed, never the transcript's last, and a binary that does not read it takes the payload as it always has.
    public static var promptKey: String {
        "sift_latest_prompt"
    }

    /// The replay section, in the style of the audit it is appended to.
    public static func section(
        projectsDirectory: URL,
        since: Date?,
        until: Date? = nil,
        transcript: String?,
        timeZone: TimeZone = .current,
        unredacted: Bool = false,
        hook: some ReplayHook
    ) -> [String] {
        sections(projectsDirectory: projectsDirectory, since: since, until: until, transcript: transcript, timeZone: timeZone, unredacted: unredacted, hook: hook).report
    }

    /// The replay section, and from the same replay every shape and structure of every still-cold rule with nothing summed — the list `--shapes` writes.
    ///
    /// `suppressionLog` is the hook's log the audit was rendered with: a call it records letting run on worth is scored not worth before the replay sees it, as the audit scores it.
    ///
    /// `snapshot` is the one the audit was rendered from, so the replay reads the same transcripts to the same byte; taken here where none is given.
    ///
    /// `audited` is the audit's own counts for each context, which the share line prints as the audit's in place of the replay's own walk's count of them, so the two sections cannot differ by what the two walks classify differently.
    ///
    /// `summary` cuts the report to its narrowest reading: without `against`, the replayed share and its per-day rows; with it, the differ count, one line per rule → rule transition, the denominator line and the replayed share — every per-transition shape list and structure block dropped either way.
    ///
    /// `sample` bounds the contexts replayed, whole sessions at a time, and where it leaves any out the report says so before its first count. `progress` is told the sessions about to be replayed and each one as it finishes, for a caller to print; it never changes the report.
    public static func sections(
        projectsDirectory: URL,
        since: Date?,
        until: Date? = nil,
        transcript: String?,
        timeZone: TimeZone = .current,
        unredacted: Bool = false,
        hook: some ReplayHook,
        against: (any ReplayHook)? = nil,
        suppressionLog: URL? = nil,
        snapshot: TranscriptSnapshot? = nil,
        audited: AuditTallies? = nil,
        summary: Bool = false,
        sample: ReplaySample = .everySession,
        progress: @escaping (String) -> Void = { _ in }
    ) -> (report: [String], shapes: [String]) {
        let snapshot = snapshot ?? .take(projectsDirectory: projectsDirectory, since: since, transcript: transcript)
        let contextsOf = { (session: URL) in 1 + snapshot.subagents(of: session).count }
        let sessions = sample.chosen(from: snapshot.sessions, holdingLookups: { session in
            ([session] + snapshot.subagents(of: session)).contains { url in
                snapshot.contents(of: url).map { ReplaySample.holdsLookup($0, since: since, until: until) } ?? false
            }
        }, contexts: contextsOf)
        let coverage = ReplaySample.Coverage(replayed: sessions.reduce(0) { $0 + contextsOf($1) }, total: snapshot.sessions.reduce(0) { $0 + contextsOf($1) })
        let advance = ReplayProgress(tell: progress, started: Date())
        advance.began(sessions.count, of: snapshot.sessions.count)
        // The floor is asked of the path the hook is handed, moved off a gone worktree as `resolved` moves it: asked
        // as written, a file read through a deleted worktree cannot be read and is never excused, so a file below
        // the floor would count as a cold lookup the hook lets through. The plain audit still asks as written.
        let floor = DigestFloor.memoised()
        let (couldAnswer, memberExists) = (AdvisableName.memoised(in: snapshot.indexes), AdvisableName.memoisedMember(in: snapshot.indexes))
        let enclosing = WorktreeOrigins.memoisedEnclosing()
        // The log the audit read, read the same way, so the audit's own share beside the replayed one is the audit's.
        let loggedLetThrough = suppressionLog.map { SuppressionLog.callsLetThrough(in: $0) } ?? [:]
        let answeredCalls = suppressionLog.map { AnsweredLog.calls(in: AnsweredLog.fileURL(besideSuppressionLog: $0)) } ?? []
        var contexts: [ContextReplay] = []
        for (index, session) in sessions.enumerated() {
            let agents = snapshot.subagents(of: session)
            // A worktree one context adds is often worked in by another, so the session and its subagents are read together.
            let origins = WorktreeOriginScan.origins(of: [session] + agents, in: snapshot, enclosing: enclosing)
            let probes = ReplayProbes(
                since: since,
                until: until,
                timeZone: timeZone,
                belowFloor: { floor(origins.mapping(in: $0)) },
                couldAnswer: couldAnswer,
                memberExists: memberExists,
                origins: origins,
                loggedLetThrough: loggedLetThrough,
                answeredCalls: answeredCalls,
                snapshot: snapshot
            )
            for (url, isSubagent) in [(session, false)] + agents.map({ ($0, true) }) {
                let context = replay(url, session: session, isSubagent: isSubagent, probes: probes, hook: hook, against: against)
                contexts.append(audited?.applied(to: context, of: url) ?? context)
            }
            advance.finished(index + 1, of: sessions.count, contexts: agents.count + 1)
        }
        let report = against == nil
            ? render(contexts, unredacted: unredacted, summary: summary)
            : ReplayComparison.lines(contexts, unredacted: unredacted, summary: summary, sampled: sessions.count < snapshot.sessions.count)
        return (
            ReplaySample.noted(report, replayed: sessions.count, of: snapshot.sessions.count, contexts: coverage),
            ReplaySample.notedShapes(shapeList(contexts, unredacted: unredacted), replayed: sessions.count, of: snapshot.sessions.count, contexts: coverage)
        )
    }

    /// The section's lines for replayed contexts, with the real calls behind each still-cold shape where `unredacted`; `summary` drops every row but the replayed share and its per-day breakdown.
    static func render(_ contexts: [ContextReplay], unredacted: Bool = false, summary: Bool = false) -> [String] {
        var totals = TranscriptTally()
        var replay = ReplayTally()
        var dayTallies: [String: TranscriptTally] = [:]
        var dayReplays: [String: ReplayTally] = [:]
        // The one-file text searches the old denominator counted as misses, from the contexts whose misses it held.
        var oneFile = 0
        var dayOneFile: [String: Int] = [:]
        for context in contexts {
            totals += context.tally.scored
            for (day, tally) in context.byDay {
                dayTallies[day, default: TranscriptTally()] += tally.scored(inContext: context.tally)
            }
            // A context that could not reach the index has its cold lookups out of the share, so they are out of
            // the replay too: recovering one would add to a numerator whose denominator never held it.
            guard !context.tally.couldNotReachTheIndex else { continue }
            replay += context.replay
            oneFile += context.tally.textSearchCauses.patternInOneFile
            for (day, counted) in context.replayByDay {
                dayReplays[day, default: ReplayTally()] += counted
            }
            for (day, tally) in context.byDay {
                dayOneFile[day, default: 0] += tally.textSearchCauses.patternInOneFile
            }
        }
        var lines: [String] = summary ? [] : [
            "",
            "replay — the window's cold lookups put to the advice hook as it stands now, each context in its own order:",
            "  cold         \(TranscriptAudit.pad(replay.cold))  the lookups the audit calls cold",
            "  recovered    \(TranscriptAudit.pad(replay.recoveredCount))  the hook would now answer these in place",
        ]
        if !summary {
            for (key, count) in replay.recovered.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) {
                lines.append("      \(TranscriptAudit.pad(count))  \(key)")
            }
            lines.append("  still cold   \(TranscriptAudit.pad(replay.stillColdCount))  the hook would still let these through, by the rule that lets each through")
            for (rule, count) in replay.stillCold.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) {
                lines.append("      \(TranscriptAudit.pad(count))  \(rule)\(Self.ungroupedSuffix(replay, rule))")
                lines += ReplayColdShapes.lines(replay.stillColdCalls[rule] ?? [:], rule: rule, unredacted: unredacted)
            }
            lines.append("  not worth    \(TranscriptAudit.pad(replay.notWorthCount))  the hook would let these run, no answer it has smaller than what the command prints — not worth answering, out of the share")
            for (rule, count) in replay.notWorth.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) {
                lines.append("      \(TranscriptAudit.pad(count))  \(rule)")
            }
            lines.append("  located      \(TranscriptAudit.pad(replay.located))  windows of a file only an answer in place located — guided, out of the share")
            lines.append("  read whole   \(TranscriptAudit.pad(replay.readWholeAfterAnswer))  whole reads of a file only an answer in place located — read whole after its digest")
            lines.append("  unreplayable \(TranscriptAudit.pad(replay.unreplayable))  the directory they run in is not on disk now — neither recovered nor judged")
        }
        lines.append("  replayed share \(shareLine(totals, replay: replay, oneFile: oneFile))")
        for day in Set(dayTallies.keys).union(dayReplays.keys).sorted() {
            let tally = dayTallies[day] ?? TranscriptTally()
            guard tally.total > 0 else { continue }
            let counted = dayReplays[day] ?? ReplayTally()
            lines.append("    \(TranscriptAudit.column(day, 12))\(shareLine(tally, replay: counted, oneFile: dayOneFile[day] ?? 0))")
        }
        if !summary {
            lines.append("  (replayed share = (indexed + recovered) / (the audit's own lookups that had a choice + those its log took out as not worth")
            lines.append("   − located − unreplayable − not worth); the old denominator also held the unreplayable calls, the lookups not worth answering")
            lines.append("   and the greps of one file for a pattern naming nothing a declaration could be, as misses)")
        }
        return lines
    }

    /// Every still-cold rule of `contexts` with every shape behind it and every structure its calls fall in, nothing summed, with the real calls behind each shape where `unredacted`.
    static func shapeList(_ contexts: [ContextReplay], unredacted: Bool = false) -> [String] {
        let replay = contexts.filter { !$0.tally.couldNotReachTheIndex }.reduce(into: ReplayTally()) { $0 += $1.replay }
        var lines = ["still cold — every shape of every rule the hook would still let through, and every structure, nothing summed:"]
        for (rule, count) in replay.stillCold.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) {
            lines.append("      \(TranscriptAudit.pad(count))  \(rule)\(Self.ungroupedSuffix(replay, rule))")
            lines += ReplayColdShapes.lines(replay.stillColdCalls[rule] ?? [:], rule: rule, unredacted: unredacted, complete: true)
        }
        return lines
    }

    /// The header suffix naming how many of `rule`'s still-cold count has no call to group by structure, or empty where the grouping accounts for all of it.
    private static func ungroupedSuffix(_ replay: ReplayTally, _ rule: String) -> String {
        let ungrouped = replay.ungroupedStillCold(for: rule)
        guard ungrouped > 0 else { return "" }
        return " (\(ungrouped) without a call to group)"
    }

    /// One share line: the replayed share, its arithmetic, the audit's own share beside it, and the share on the old denominator after that, so neither hides the other.
    ///
    /// The `located` reads are out of the denominator as the audit takes a guided read out of it, and so are the `unreplayable` calls, whose directory is gone and which were never judged: a call the replay cannot put to the hook is no evidence either way. So are the `notWorth` ones, which the hook lets run whole because answering them would save nothing: no answer it has is smaller than what the command prints (`notSmaller`), or would show the lines a window asks for while saving little (`linesNotShown`) — as the audit says of the lookups on its own not-worth row. A line the hook lets run whole for its other statements (`otherStatementsRun`) is not one of them: its lookup would have been answered alone, so it stays a miss in the denominator. The old denominator held `notWorth` lookups as misses, and held the searches of one file for a pattern naming nothing a declaration could be (`oneFile`), which the scan now scores as the tree form is scored; none was ever recovered — no in-place answer is drawn for such a pattern, an unreplayable call is never judged, and a lookup not worth answering is let through — so the numerator is the same on both.
    static func shareLine(_ tally: TranscriptTally, replay: ReplayTally, oneFile: Int = 0) -> String {
        let numerator = numerator(tally, replay: replay)
        let total = denominator(tally, replay: replay)
        let oldTotal = total + replay.unreplayable + replay.notWorthCount + oneFile
        return "\(percent(numerator, total)) = (indexed \(tally.indexed) + recovered \(replay.recoveredCount)) / \(total) — the audit's own \(tally.shareText ?? "n/a")"
            + " — on the old denominator \(percent(numerator, oldTotal)) = … / \(oldTotal)"
            + " (text searches in one file +\(oneFile), unreplayable +\(replay.unreplayable), not worth +\(replay.notWorthCount))"
    }

    /// The replayed share's numerator: the audit's own indexed lookups and those the replay recovered.
    static func numerator(_ tally: TranscriptTally, replay: ReplayTally) -> Int {
        tally.indexed + replay.recoveredCount
    }

    /// The replayed share's denominator: the audit's own lookups that had a choice and those its log took out as not worth, less those the replay found located, could not replay, or found not worth answering.
    ///
    /// A call the log names is out of the audit's total already, yet the replay still judges it by the hook's own verdict and takes out those it finds not worth; putting the logged ones back first takes each out once.
    static func denominator(_ tally: TranscriptTally, replay: ReplayTally) -> Int {
        tally.total + replay.loggedOnWorth - replay.located - replay.unreplayable - replay.notWorthCount
    }

    /// `part` of `whole` as a percentage rounded to `places` decimal places, or `n/a` where there is no whole.
    static func percent(_ part: Int, _ whole: Int, places: Int = 0) -> String {
        guard whole > 0 else { return "n/a" }
        let share = Double(part) / Double(whole) * 100
        return places == 0 ? "\(Int(share.rounded()))%" : String(format: "%.\(places)f%%", share)
    }

    /// One context's transcript scanned as the audit scans it, with each of its calls put to `hook` in order — and to `against` too where one is named, each hook fed only its own index calls' answers, so both carry the history they would carry in a replay of their own.
    static func replay(
        _ url: URL,
        session: URL,
        isSubagent: Bool,
        probes: ReplayProbes,
        hook: some ReplayHook,
        against: (any ReplayHook)? = nil
    ) -> ContextReplay {
        let (since, until, timeZone) = (probes.since, probes.until, probes.timeZone)
        var result = ContextReplay()
        guard let data = probes.snapshot?.contents(of: url) ?? (try? Data(contentsOf: url)) else { return result }
        let identity = ReplayIdentity(
            sessionTranscript: session.path,
            fallbackSession: session.deletingPathExtension().lastPathComponent,
            fallbackAgent: isSubagent ? String(url.deletingPathExtension().lastPathComponent.dropFirst("agent-".count)) : nil
        )
        var state = TranscriptScanState()
        // Index calls waiting on their result, by `tool_use_id`: an answer is what makes a digest count.
        var pendingIndexCalls: [String: (payload: [String: Any], cwd: String)] = [:]
        var pendingAgainst: [String: (payload: [String: Any], cwd: String)] = [:]
        // The cold lookups each call was counted for, and what the other hook made of each, so an errored result can take them back.
        var counted: [String: [(lookup: ReplayedLookup, day: String?)]] = [:]
        // What each hook made of every call on its own line, whatever the scan scored it as there, so a lookup the scan
        // scores again on the call's result is put down to that call and that verdict.
        var judged: [String: (lookup: ReplayedLookup, site: ReplayCall)] = [:]
        // The prompt each call followed, as the live hook reads it off the transcript at the moment of the call.
        var prompt: LatestPrompt?
        // The permission mode each call was made in, as the live hook's payload names it: the transcript records every change of it.
        var permissionMode: String?
        // The size of the context as of each call, from the usage of the latest assistant message read: what the live hook reads off the tail of the transcript.
        var contextTokens: Int?
        // Set once a line past `--until` has been read and no counted call waits on a later one: nothing read after
        // that can change a count, so only the access facts the context is judged on, read from the whole
        // transcript, are still taken from it.
        var onlyAccessOwed = false
        for slice in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let line = Data(slice)
            if onlyAccessOwed {
                TranscriptAccess.note(line: line, in: &state)
                continue
            }
            let events = TranscriptScan.events(
                line: line,
                state: &state,
                since: since,
                until: until,
                belowFloor: probes.belowFloor,
                couldAnswer: probes.couldAnswer,
                memberExists: probes.memberExists,
                answeredCalls: probes.answeredCalls
            )
            if line.range(of: Data(#""type":"user""#.utf8)) != nil, line.range(of: Data(#""type":"tool_result""#.utf8)) == nil,
               let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let written = LatestPrompt(line: object)
            {
                prompt = written
            }
            if line.range(of: Data(#""permissionMode""#.utf8)) != nil,
               let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let mode = object["permissionMode"] as? String
            {
                permissionMode = mode
            }
            guard !events.isEmpty || line.range(of: Data("tool_use".utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            if let tokens = ContextSize.tokens(inLine: object) {
                contextTokens = tokens
            }
            let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            let instant = (object["timestamp"] as? String).flatMap(TranscriptScan.instant)
            let day = instant.map { TranscriptAudit.day(of: $0, timeZone: timeZone) }
            // The scan's own window rule: a line with no timestamp is kept, and the end cuts the same way the start does.
            let pastEnd = until.map { end in instant.map { $0 >= end } ?? false } ?? false
            let inWindow = !pastEnd && (since.map { start in instant.map { $0 >= start } ?? true } ?? true)
            var lineCall: (id: String, lookup: ReplayedLookup)?
            var lineSite: ReplayCall?
            var resultIDs: [String] = []
            for block in content {
                switch block["type"] as? String {
                case "tool_use":
                    // A call past the end is never put to the hook: it cannot be counted, and every call it could
                    // change on the ledger comes after it, past the end too. Judging it is the whole cost.
                    guard let id = block["id"] as? String, !pastEnd else { continue }
                    let call = ReplayCall(block: block, line: object, identity: identity, origins: probes.origins, prompt: prompt, permissionMode: permissionMode, contextTokens: contextTokens)
                    let outcome: ReplayOutcome
                    var other: ReplayOutcome? = against == nil ? nil : .unreplayable
                    var answerBytes: Int?
                    if let cwd = call.cwd {
                        let verdict = hook.verdict(payload: call.payload, cwd: cwd, at: instant, decides: inWindow)
                        if verdict?.isIndexCall == true {
                            pendingIndexCalls[id] = (call.payload, cwd)
                        }
                        outcome = verdict.map(Self.outcome) ?? .stillCold("notHooked")
                        answerBytes = verdict?.answerBytes
                        if let against {
                            let theirs = against.verdict(payload: call.payload, cwd: cwd, at: instant, decides: inWindow)
                            if theirs?.isIndexCall == true {
                                pendingAgainst[id] = (call.payload, cwd)
                            }
                            other = theirs.map(Self.outcome) ?? .stillCold("notHooked")
                            if inWindow {
                                result.compare(theirs, with: verdict, payload: call.payload)
                            }
                        }
                    } else {
                        outcome = .unreplayable
                    }
                    // The harness writes one block to a line, so a line's lookups are its one call's.
                    if lineCall == nil {
                        let lookup = ReplayedLookup(outcome: outcome, call: ReplayColdCall(payload: call.payload, answerBytes: answerBytes), other: other)
                        lineCall = (id, lookup)
                        lineSite = call
                        judged[id] = (lookup, call)
                    }
                case "tool_result":
                    guard let id = block["tool_use_id"] as? String else { continue }
                    resultIDs.append(id)
                    // Handed the answer's text beside the call, so a `where` or `search` answer can locate what it
                    // listed exactly as the server's log line does for the live hook.
                    let answer = TranscriptScan.answerText(of: block).joined(separator: "\n")
                    if var call = pendingIndexCalls.removeValue(forKey: id), !pastEnd, block["is_error"] as? Bool != true {
                        call.payload[Self.answerKey] = answer
                        hook.answered(payload: call.payload, cwd: call.cwd, at: instant)
                    }
                    if var call = pendingAgainst.removeValue(forKey: id), !pastEnd, block["is_error"] as? Bool != true {
                        call.payload[Self.answerKey] = answer
                        against?.answered(payload: call.payload, cwd: call.cwd, at: instant)
                    }
                default:
                    continue
                }
            }
            // A cold lookup on a result line is the scan scoring that result's call again, once the result of an
            // earlier call of its turn has said whether the hook answered it: the same call, judged on its own line.
            if lineCall == nil, let id = resultIDs.first(where: { judged[$0] != nil }), let call = judged.removeValue(forKey: id) {
                lineCall = (id, call.lookup)
                lineSite = call.site
            }
            for event in events {
                // The scan is left unseeded, so a window the log names is still scored against each hook's own
                // verdict below; only the audit's own tally reads it as the audit does.
                let retracting = resultIDs.first(where: { counted[$0]?.isEmpty == false })
                let audited = Self.audited(event, call: lineCall?.id, retracting: retracting, logged: probes.loggedLetThrough)
                result.tally.fold(audited)
                if let day {
                    result.byDay[day, default: TranscriptTally()].fold(audited)
                }
                switch event {
                case let .lookup(.cold(file, _)):
                    let uncalled = ReplayOutcome.stillCold("noCall")
                    // Asked on the call's own line, before any later answer can move what the context holds.
                    let outcome = Self.scored(lineCall?.lookup.outcome ?? uncalled, file: file, site: lineSite, origins: probes.origins, hook: hook)
                    let other = against.map { Self.scored(lineCall?.lookup.other ?? uncalled, file: file, site: lineSite, origins: probes.origins, hook: $0) }
                    let lookup = ReplayedLookup(outcome: outcome, call: lineCall?.lookup.call, other: other)
                    result.count(lookup.outcome, day: day, call: lookup.call)
                    if let id = lineCall?.id, Self.loggedOnWorth(id, in: probes.loggedLetThrough) {
                        result.countLogged(day: day)
                    }
                    if let other {
                        result.against.count(other)
                    }
                    counted[lineCall?.id ?? "", default: []].append((lookup, day))
                case .lookupRetracted(.cold):
                    guard let id = resultIDs.first(where: { counted[$0]?.isEmpty == false }),
                          let taken = counted[id]?.popLast()
                    else { continue }
                    result.count(taken.lookup.outcome, day: taken.day, call: taken.lookup.call, by: -1)
                    if Self.loggedOnWorth(id, in: probes.loggedLetThrough) {
                        result.countLogged(day: taken.day, by: -1)
                    }
                    if let other = taken.lookup.other {
                        result.against.count(other, by: -1)
                    }
                default:
                    continue
                }
            }
            onlyAccessOwed = pastEnd && !state.awaitsCountedCall
        }
        result.tally.recordedToolListWithoutIndex = state.recordedToolListWithoutIndex
        result.tally.recordsWholeToolList = state.recordsWholeToolList
        return result
    }

    /// What `hook` makes of a cold lookup of `file` on the line of `site`: `outcome`, unless the hook let it through only because an answer it gave in place located the file, which the audit scores as a located read or a whole read after its digest.
    private static func scored(_ outcome: ReplayOutcome, file: String?, site: ReplayCall?, origins: WorktreeOrigins, hook: any ReplayHook) -> ReplayOutcome {
        guard let file, let call = site, let cwd = call.cwd, isLetThroughAsLocated(outcome),
              let directory = directory(resolving: file, call: call.payload, cwd: cwd),
              hook.locatedOnlyByAnswers(resolved(file, in: directory, origins: origins), payload: call.payload)
        else { return outcome }
        return isWholeRead(call.payload) ? .readWholeAfterAnswer : .located
    }

    /// Whether the hook let a cold lookup through on the rule it lets a located read through on: `noLookup` for a window or a whole read the usage log locates, `alreadyDigested` for a whole read the ledger does — and any rule only the suppression log names, since the verdict itself let that call through as `noLookup`.
    static func isLetThroughAsLocated(_ outcome: ReplayOutcome) -> Bool {
        guard case let .stillCold(rule) = outcome else { return false }
        return rule == "noLookup" || rule == "alreadyDigested" || rule.hasSuffix(ReplayVerdict.logged(""))
    }

    /// Whether a call is a whole `Read`, which the scan scores as read whole after its digest where a window or ranged read of the same file is guided.
    static func isWholeRead(_ payload: [String: Any]) -> Bool {
        guard LookupTool.rule(for: payload["tool_name"] as? String ?? "") == "Read" else { return false }
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        return !(input["offset"] is NSNumber) && !(input["limit"] is NSNumber)
    }

    /// The directory a cold lookup's relative file is read from, or `nil` where it cannot be known: the call's own cwd, or the directory the literal `cd`s before the lookup move to, which is where the hook and the scan both read it from — but never behind a move that cannot be followed, which would spell out a different file than the one read.
    static func directory(resolving file: String, call payload: [String: Any], cwd: String) -> String? {
        guard !file.hasPrefix("/"),
              let command = (payload["tool_input"] as? [String: Any])?["command"] as? String,
              TranscriptScan.changesDirectory(command)
        else { return cwd }
        guard let first = ShellAdvice.lookupDirectories(of: command, holdsSource: nil, cwd: cwd, requiringDirectories: false)?.first else { return nil }
        return first
    }

    /// The file a cold lookup names, moved off a gone worktree and spelled out against the directory its call ran in.
    static func resolved(_ file: String, in cwd: String, origins: WorktreeOrigins) -> String {
        let mapped = origins.mapping(in: file)
        guard !mapped.hasPrefix("/") else { return mapped }
        return URL(fileURLWithPath: mapped, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardizedFileURL.path
    }

    /// What a verdict makes of a cold lookup: recovered where the hook would answer it in place, not worth where it lets it run because no answer is smaller than what the command prints, still cold otherwise — a line run whole for its other statements included, a miss the call could have been put on the line for.
    static func outcome(of verdict: ReplayVerdict) -> ReplayOutcome {
        guard verdict.recovers else {
            let onWorth = InPlaceAnswerer.Withholding(rawValue: verdict.rule).flatMap(TextSearch.Rule.init(loggedAs:)) != nil
            return onWorth ? .notWorth(verdict.rule) : .stillCold(verdict.rule)
        }
        let words = (verdict.call ?? "").split(separator: " ")
        let tool = words.first == "sift" ? words.dropFirst().first : words.first
        return .recovered("\(verdict.rule) → \(tool.map(String.init) ?? "answer")")
    }

    /// `text` with every `.claude/worktrees/<name>` prefix moved onto the repository above it, since the worktree is gone whatever the cwd is — a whole directory, a `file_path` or `path` argument, or a `cd <worktree>` target (with or without a trailing slash) inside a Bash command's own text.
    static func mappingWorktrees(in text: String) -> String {
        var result = text
        while let range = result.range(of: "/.claude/worktrees/") {
            let rest = result[range.upperBound...]
            let name = rest.prefix { !"/ \t\n&|;\"'()<>".contains($0) }
            guard !name.isEmpty else { break }
            let end = result.index(range.upperBound, offsetBy: name.count)
            result.removeSubrange(range.lowerBound ..< end)
        }
        return result
    }
}

extension TranscriptReplay {
    /// Whether the log records letting `call` run on a judgement of worth, which takes it out of the audit's total; a line run whole is a miss the total already holds.
    static func loggedOnWorth(_ call: String, in logged: [String: InPlaceAnswerer.Withholding]) -> Bool {
        logged[call].flatMap(TextSearch.Rule.init(loggedAs:)) != nil
    }

    /// `event` as the audit scores it, where the hook's log records letting the call behind it run.
    ///
    /// The audit reads such a call as not worth, under the rule the log names, or as a batched miss for a line run whole, rather than plain cold; the replay scores the same call against each hook's own verdict, so only the audit's own tally is read through the log.
    static func audited(_ event: TranscriptEvent, call: String?, retracting: String?, logged: [String: InPlaceAnswerer.Withholding]) -> TranscriptEvent {
        switch event {
        case let .lookup(lookup):
            call.flatMap { logged[$0] }.map { .lookup(lookup.scored(letThroughAs: $0)) } ?? event
        case let .lookupRetracted(lookup):
            retracting.flatMap { logged[$0] }.map { .lookupRetracted(lookup.scored(letThroughAs: $0)) } ?? event
        default:
            event
        }
    }
}
