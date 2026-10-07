//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Classifies transcript lines into Swift lookups.
///
/// Shared by every reader of a transcript, so `sift audit` and `sift report` can never disagree about what a miss is.
public struct TranscriptScan {
    /// Every countable event on one transcript line, advancing `state`.
    ///
    /// `belowFloor` decides whether a first-touch read cost anything a digest could have saved; it is a parameter so tests can pin the classification without putting files on disk. Each path is asked at most once per transcript — only a *first* touch consults it — so nothing needs caching behind it.
    ///
    /// `couldAnswer` is the same question the PreToolUse hook asks before denying a search on the strength of a symbol name, and it is injected for the same two reasons `belowFloor` is: a test can pin the classification without an index on disk, and a caller sweeping many transcripts can hand in one memo for the whole pass. Unmemoised it costs an index open per search.
    ///
    /// `memberExists` is the same question asked of a specific member of a specific type rather than a bare name — `AdvisableName.couldAnswer(member:of:from:)` — and it is injected for the same reason: unmemoised, both search surfaces this asks (`SearchToolAdvice`, `ShellAdvice`) pay an index open per member-shaped search, and a sweep over a window of transcripts asks the same handful of them over and over.
    ///
    /// `since` reports only what happened inside the window while still folding everything before it into `state`, and both halves of that are load-bearing. Filtering whole transcripts instead would put a session that merely *continued* into today into a report of today's work, carrying yesterday's misses with it. But skipping the earlier lines outright would be just as wrong the other way: a file digested this morning and read this afternoon is still guided, because the digest is still in the same context window.
    ///
    /// `until` is the same rule at the other edge: exclusive, so a lookup timestamped exactly on it falls outside the window, and a line with no timestamp is kept rather than dropped — the same reasoning as `since`, cutting the same way.
    ///
    /// `loggedLetThrough` is the rule the hook's suppression log records letting each of its `tool_use_id`s run under — `notSmaller`, `linesNotShown`, `notWorthTheTurn` or `otherStatementsRun`: a cold lookup made by one of them is scored not worth under the first three rather than cold, and a batched miss under the fourth, wherever the caller has read the log.
    ///
    /// `answeredCalls` is the `tool_use_id`s the hook's answered log records answering in place (``AnsweredLog``). A result for one of them takes the path an error-delivered answer takes whatever its error flag says, because the log is the proof it was sift's answer: a transport that hands the answer over as an ordinary result is scored exactly as the hook error it replaced, and the result's text is never read to decide.
    public static func events(
        line: Data,
        state: inout TranscriptScanState,
        since: Date? = nil,
        until: Date? = nil,
        belowFloor: (String) -> Bool = DigestFloor.wouldServeSource,
        couldAnswer: @escaping (String, String?) -> Bool = { AdvisableName.couldAnswer($0, from: $1) },
        memberExists: @escaping (String, String, String?) -> Bool = { AdvisableName.couldAnswer(member: $0, of: $1, from: $2) },
        loggedLetThrough: [String: InPlaceAnswerer.Withholding] = [:], answeredCalls: Set<String> = []
    ) -> [TranscriptEvent] {
        // A byte-level pre-filter before any JSON parse: transcripts reach 60 MB and the overwhelming
        // majority of lines are prose that can never contribute to a count.
        guard line.count > 2,
              mayContribute(
                  line,
                  awaiting: state.pendingIndexCalls.keys,
                  shellDigests: state.pendingShellDigests.keys,
                  shellAnswers: state.pendingShellAnswers.keys,
                  reads: state.pendingReads.keys,
                  nextTurn: !state.awaitingRoundTrip.isEmpty
              )
        else {
            return []
        }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return [] }
        TranscriptAccess.note(object, in: &state)
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else {
            return []
        }

        // A line with no timestamp is kept rather than dropped: it still moves the state, and excluding it
        // from a window it cannot be proven to be outside of would lose real events.
        let timestamp = (object["timestamp"] as? String).flatMap(Self.instant)
        if let timestamp, state.earliestStamp.map({ timestamp < $0 }) ?? true {
            state.earliestStamp = timestamp
        }
        let reported = (since.map { start in timestamp.map { $0 >= start } ?? true } ?? true)
            && (until.map { end in timestamp.map { $0 < end } ?? true } ?? true)

        var events: [TranscriptEvent] = []
        let turn = object["type"] as? String == "assistant" ? message["id"] as? String : nil
        if let turn {
            if turn != state.turn {
                // A turn begins, so every call of the one before it has been written: a refusal given there was
                // alone in it or it was not, and this turn is the round trip it cost.
                // Whatever window this line is in: only a counted refusal waits for its round trip, so one counted
                // just inside `--until` is priced by the turn that begins past it.
                events += roundTrips(of: &state, nextTurnUsage: message["usage"] as? [String: Any])
                state.awaitingRoundTrip = []
                state.turn = turn
                state.turnToolUses = 0
            }
            state.turnToolUses += content.count { $0["type"] as? String == "tool_use" }
        }
        for block in content {
            switch block["type"] as? String {
            case "tool_use":
                // The next tool call the transcript writes after a solo refusal is what followed it, whatever
                // it turns out to be — dequeued here, ahead of that call's own classification, because this is
                // the first point every `tool_use` block of every tool passes through. Only the oldest pending
                // refusal is resolved: a second one still waiting keeps waiting for the call after this one. Only a
                // counted round trip queues one, so it is reported whichever side of `--until` this call falls on.
                if let pending = state.awaitingFollowUp.first {
                    state.awaitingFollowUp.removeFirst()
                    let name = block["name"] as? String ?? ""
                    let input = block["input"] as? [String: Any] ?? [:]
                    events.append(.refusalFollowUp(followUp(after: pending.shape, name: name, input: input), cost: pending.cost))
                }
                // Ahead of the call's own classification, which never looks at what an answer earlier in the context was about.
                events += AnswerThenRead.noteCall(block, cwd: object["cwd"] as? String, counted: reported, in: &state)
                // Outside the window the classification is discarded, so the filesystem is never consulted
                // for it — `--since today` would otherwise stat and read every Swift file first-touched
                // across seven days of transcripts and throw every answer away. State still advances.
                let found = Self.events(
                    forToolUse: block,
                    on: object,
                    state: &state,
                    belowFloor: belowFloor,
                    probes: SymbolProbes(couldAnswer: couldAnswer, memberExists: memberExists, loggedLetThrough: loggedLetThrough),
                    consultFilesystem: reported
                )
                if reported {
                    events += ScanWindowLog.opening(found, of: block, in: &state)
                }
            case "tool_result":
                guard let id = block["tool_use_id"] as? String else { continue }
                // An answer the hook gave is read as the hook error it travels as, however it was delivered.
                let failed = block["is_error"] as? Bool == true || answeredCalls.contains(id)
                // Where the windows are kept, what this result locates and does to its own window is settled as it closes.
                let mark = ScanWindowLog.mark(id, events: events.count, in: state)
                defer { ScanWindowLog.close(mark, events: events, in: &state) }
                // Ahead of the guards below, which end at the first entry they find: a Bash line can hold a read too.
                events += creditShellCall(answering: id, block: block, failed: failed, in: &state)
                events += AnswerThenRead.noteResult(id: id, block: block, failed: failed, in: &state)
                // A read that succeeded only needs its pending entry dropped; nothing about the count changes.
                guard var pending = state.pendingReads.removeValue(forKey: id) else {
                    guard let call = state.pendingIndexCalls.removeValue(forKey: id) else { continue }
                    guard failed else {
                        // Keyed as the advice ledger keys a digest (``PreToolUseCommand/digestsAsked``): another root's file must not excuse a read of this repository's own.
                        let root = call.counted ? locatingRoot(call.root) : ""
                        let text = answerText(of: block).joined(separator: "\n")
                        if call.tool == "digest" {
                            // Only an answer locates anything, so the targets the arguments held are credited now,
                            // each by the file its answer named for it — never by a stem another file shares. Only
                            // a digest promised to save reading the file whole: `where` returns file:line locations
                            // and never promised to save you the file, so counting a whole read after one as "read
                            // whole after its digest" would name a digest that was never made.
                            state.digests[root, default: []].formUnion(LocatedDigest.credited(targets: call.digestTargets, whole: call.servesWorkingTree, answer: text, anchor: call.root))
                        } else {
                            // The answer names files the arguments never could: a `search` is asked in
                            // `field:value` terms and hands back `file:line` locations, so the file it located
                            // is knowable only here.
                            state.located[root, default: []].formUnion(call.located.union(locatedNames(inAnswer: block)))
                        }
                        // A whole-file digest also says, in its own text, whether the file was under the
                        // floor — the one record of that decision that outlives the file. Its path is relative
                        // to the checkout that answered, which the transcript records only in part: the
                        // directory the call named, the tree's name in the answer's header, and the repository
                        // the answer says it resolved to where it had to resolve one. All three are kept, and
                        // a read is placed against them (`FloorVerdict`).
                        if call.weighsSource, let verdict = SourcePassthrough.fileVerdict(in: text) {
                            state.recordFloorVerdict(
                                verdict,
                                anchor: call.root,
                                adopted: ResolvedRoot.adoptedRoot(inAnswer: text),
                                tree: WorkingTree.named(inAnswer: text)
                            )
                        }
                        continue
                    }
                    // Asked of the call rather than of this line: a call counted just inside `--until` whose
                    // error lands past it is still taken back, and one made before `--since` never is.
                    if call.counted {
                        // A call that errored served no lookup, so it leaves the numerator as well as
                        // raising the failure count. It was counted `.indexed` on the way out — the
                        // result is the first line that can know it failed — and `share` is the index's
                        // share of the lookups it *answered*, so leaving it in would report a session whose
                        // only call errored and whose only read went around the index as 50% served.
                        //
                        // Asked of the same target and by the same predicate the count was: a document call
                        // never entered the share, so retracting it would take out a lookup that was never in,
                        // and a session whose one call was a failed `.md` digest would read as minus one.
                        if !IndexCallTarget.namesOnlyDocuments(call.target, tool: call.tool) {
                            events.append(.lookupRetracted(.indexed))
                        }
                        let reason = failureReason(of: block)
                        // An error the harness wrote in place of delivering the call is not the index
                        // failing: the server never saw it. Filed as a failure it would be reported against
                        // the tool, and — since a failed call proves the tool was there — it would also veto
                        // the very verdict it is evidence for. A call stopped at the permission check never
                        // reached it either, and is no failure of the index.
                        if Self.stoppedAtThePermissionCheck(reason) {
                            events.append(.indexDeclined)
                        } else {
                            events.append(Self.neverReachedTheServer(reason)
                                ? .indexUnavailable
                                : .indexFailure(IndexFailure(tool: call.tool, target: call.target, reason: reason)))
                        }
                    }
                    continue
                }
                // Scored after an earlier call of its turn taken as answered: that call's result has said whether it was.
                events += LetThroughFallback.settle(&pending, in: state)
                // The hook logs its verdict while it judges the call, so a scan that read the call's line first — a
                // scan run in between — scored it cold; the result is written after the verdict, and
                // scores it again as what the log says it was.
                if !failed, pending.counted, case .cold = pending.lookup, let why = loggedLetThrough[id], pending.lookup.scored(letThroughAs: why) != pending.lookup {
                    events += [.lookupRetracted(pending.lookup), .lookup(pending.lookup.scored(letThroughAs: why))]
                }
                if failed {
                    if pending.openedPath, pending.shellWindow {
                        state.windowed.remove(pending.path)
                    } else if pending.openedPath {
                        // The read that first opened the file is the one whose floor was judged, so taking it
                        // back takes that judgement with it — the retry is a first touch and judges again.
                        state.opened.remove(pending.path)
                        state.floorFromDisk.remove(pending.path)
                    }
                    let reason = failureReason(of: block)
                    // A refusal that carries its answer is the index serving the lookup: the hook ran the call a
                    // refusal would have named and handed its answer over. So the lookup the call was counted as
                    // is taken back, as a refusal's is, and counted again as what it was — indexed, never cold
                    // and never a refusal routed around — and what the answer located is credited as an index
                    // call's answer would be. Its re-run is the same sanctioned escape hatch a refusal offers, in
                    // either spelling: the answer named the identical re-run as its way out, and a whole read is
                    // remembered by its path as a search is by its key.
                    if let calls = InPlaceAnswer.calls(inOpeningLine: reason) {
                        // Named beside the caveat's own count so the key an alternation's identical re-run
                        // is remembered by is the one a partial answer's sweep is watched for on
                        // (`TranscriptScanState.partialAnswered`) — read once here rather than at both ends,
                        // so the two cannot drift apart on what counts as "the same key". Read off the block's
                        // whole text rather than `reason`, which `failureReason` trims to the opening line
                        // alone — the caveat sits inside the answer, several lines further down.
                        let uncovered = InPlaceAnswer.uncoveredBranchCount(inReason: answerText(of: block).joined(separator: "\n"))
                        if !pending.key.isEmpty {
                            // Remembered under exactly the lookups the served reading stands for, as the hook's ledger
                            // records it (`PreToolUseCommand.outcome`): every read of several answered together, and
                            // never a lookup the answer dropped, even the one the line was filed under. An answer
                            // no reading of the line spells served none of its lookups, and is remembered under none.
                            if let served = ServedReading.keys(servedBy: calls, note: InPlaceAnswer.note(inOpeningLine: reason), among: pending.readings) {
                                state.hookDenied.formUnion(served.isEmpty ? [pending.key] : served)
                                if uncovered != nil {
                                    state.partialAnswered.insert(pending.key)
                                }
                            }
                        } else if !pending.path.isEmpty, !pending.shellWindow {
                            state.hookDenied.insert(RefusalMemory.readKey(pending.path))
                        }
                        // A bounded window's call is displayed as the file's whole digest, `digest F.swift`,
                        // without being one — the note beside it says so, and the scan reads it back here so
                        // such a call is credited as locating the file, never as having digested it whole
                        // (the ledger already draws the same line, on `target` rather than the display). One
                        // call on the line is never ambiguous, so a lone bounded call needs no name in the
                        // note; several files on one line share the note, so each is named there beside its
                        // ranges, and a call is read as bounded only where the note names its own target.
                        let note = InPlaceAnswer.note(inOpeningLine: reason)
                        for call in calls {
                            creditAnswer(call: call, block: block, for: pending, note: note, soleCall: calls.count == 1, in: &state)
                        }
                        if pending.counted {
                            events += [.lookupRetracted(pending.lookup), .lookup(.indexed), .answeredInPlace]
                            if let uncovered {
                                events.append(.partialAnswer(uncovered: uncovered))
                            }
                        }
                        continue
                    }
                    if RefusalMemory.heldBack(reason, pending: pending, events: &events, in: &state) {
                        continue
                    }
                    // Recognised by the offer line rather than by the flag alone: a permission denial, a
                    // timeout and a missing file are all `is_error` too, and none of them is this tool
                    // speaking.
                    let refused = reason.hasSuffix(Self.lookupOfferSuffix)
                    // A refusal is remembered as well as retracted. Every refusal ends by offering this
                    // exact command back as the way through, the hook allows it the second time
                    // (`AdviceLedger.decide`), and taking a route the tool named is not going around the
                    // index — it is the only route left for the case the escape hatch exists for, a search
                    // for text no index records. Only searches carry a key, so only searches are remembered:
                    // the hatch is for text the index does not record, which a file's contents are not.
                    if refused, !pending.key.isEmpty {
                        state.hookDenied.insert(pending.key)
                    }
                    if pending.counted {
                        // Counted for every refused tool, key or no key, because this measures the advice
                        // rather than the escape hatch: a context with no index tools at all takes its
                        // refusals on reads exactly as it does on searches, and counting only the half
                        // that opens the hatch would read two thirds of the evidence and drop the rest.
                        // Windowed like the retraction beside it — and like `indexed`, which is the other
                        // half of the verdict these feed, so both halves describe the same stretch of time.
                        if refused {
                            events.append(.lookupRefused)
                            // Priced when the next turn begins, which is the round trip this refusal cost.
                            if let turn = pending.turn {
                                state.awaitingRoundTrip.append(PendingRoundTrip(turn: turn, shape: pending.shape))
                            }
                        }
                        events.append(.lookupRetracted(pending.lookup))
                    }
                }
            default:
                continue
            }
        }
        return events
    }

    /// Every countable event one `tool_use` block carries — none, one, or, for a Bash block that both invokes this tool and looks up Swift source, two.
    ///
    /// **A list rather than one event because one call can be two facts.** `sift where Foo; grep -rn Bar Sources/` reaches the index *and* goes around it, and returning only the first would drop the grep from the denominator — which raises the share, the one direction ``TranscriptTally`` may never round. See the `Bash` branch for why that is worth a divergence from the hook.
    ///
    /// `workingDirectory` is the line's `cwd`, and it is used three ways. Everything that probes the disk with it — the tree walk, the advisors, the index check — sees it only inside a `--since` window (`directory` below), since outside one the classification is discarded. Spelling a relative path out in full sees it always, because the state has to know which files are open whether or not the line is reported, or a file opened before the window would not be known as open inside it. And the volume probe behind a floor verdict's case sensitivity sees it always too: it runs once for every recorded verdict, off the anchor the call named — `workingDirectory` where the call gave no `root` — whether or not that verdict falls in the window, and its answer is cached in the verdict rather than asked again.
    ///
    /// The line also names the assistant turn the call was made in (`turn`), which a refusal of it is priced by.
    private static func events(
        forToolUse block: [String: Any],
        on line: [String: Any],
        state: inout TranscriptScanState,
        belowFloor: (String) -> Bool,
        probes: SymbolProbes,
        consultFilesystem: Bool
    ) -> [TranscriptEvent] {
        let couldAnswer = probes.couldAnswer
        let memberExists = probes.memberExists
        let workingDirectory = line["cwd"] as? String
        let turn = line["type"] as? String == "assistant" ? (line["message"] as? [String: Any])?["id"] as? String : nil
        guard let name = block["name"] as? String else { return [] }
        let directory = consultFilesystem ? workingDirectory : nil
        let input = block["input"] as? [String: Any] ?? [:]

        if let tool = IndexToolName.tool(named: name) {
            // Named as the server resolved it, which is how the usage log names the same call. A
            // several-targets call weighs like any other: a floor verdict names its own file
            // (`SourcePassthrough.FileVerdict`), so the one read off the answer is about the file
            // it names, whichever of the targets produced it.
            let target = IndexCallTarget.of(ArgumentAlias.resolved(tool: tool, arguments: input).arguments, tool: tool)
            // An `at` call answers a past revision's tree, never the working file its arguments name.
            let servesWorkingTree = input["at"] == nil
            // What the call names is credited when its answer arrives, never here: a call the permission
            // check stopped, the harness never delivered, or the server failed located nothing, and a call
            // with no id can never be matched to an answer at all.
            if let id = block["id"] as? String {
                state.pendingIndexCalls[id] = PendingIndexCall(
                    tool: tool,
                    target: target,
                    weighsSource: tool == "digest"
                        && servesWorkingTree
                        && (input["offset"] as? Int ?? 0) == 0
                        && input["signaturesOnly"] as? Bool != true,
                    located: locatedNames(in: input, tool: tool),
                    digestTargets: tool == "digest" ? LocatedDigest.targets(in: input) : [],
                    root: input["root"] as? String ?? workingDirectory,
                    servesWorkingTree: servesWorkingTree,
                    counted: consultFilesystem
                )
            }
            // **A document lookup is no Swift lookup, on either side of the share.** The read population
            // below is Swift-only — a whole `Read` of a `.md` returns nothing at all — so counting the
            // `digest` that answers a document would put it in the numerator *and* the denominator with no
            // miss population of its own behind it, and every context that took the Markdown nudge
            // (`ReadAdvice`) would raise the number the tool is judged on by taking advice. The ruling is that
            // the Markdown pair stays outside a share measured over Swift lookups, and this is the call side
            // of it. The call is still held as pending: it is an index call, and what it locates, what its
            // answer weighed and how it failed are all facts about the tool whether or not the share counts it.
            return IndexCallTarget.namesOnlyDocuments(target, tool: tool) ? [] : [.lookup(.indexed)]
        }

        // Judged by rule rather than by tool name, so a read through another MCP server counts as the read
        // it is. Counting `Read` and not `XcodeRead` would let displaced traffic land somewhere invisible
        // and the share climb while nothing improved.
        // A file this context wrote or edited is text it holds, so a later read of it is a revisit, as the hook
        // lets it through; keyed by the path as written, the way a read is.
        guard !notesWrite(name, input: input, in: &state) else { return [] }
        let rule = LookupTool.rule(for: name)
        switch rule {
        case "Read":
            guard let path = LookupTool.readPath(in: input), path.hasSuffix(".swift"),
                  !SwiftPMManifest.isManifestPath(path) else { return [] }
            // Keyed on the full path, not the stem. "Have I read this already" has the path in hand — and a repo with two
            // `Container.swift`s would otherwise score the second file's *first* read as a re-read of the
            // first, dropping it from the count entirely. Duplicated basenames are ordinary, and the error
            // flatters the share, which is the one direction it must never round.
            // `limit` alone is a ranged read too — `Read(file, limit: 40)` takes the first 40 lines — and
            // reading `offset` presence alone would file those as whole-file. `NSNull` is what an explicit
            // JSON null decodes to, and it is not a range.
            let ranged = input["offset"] is NSNumber || input["limit"] is NSNumber
            let firstRead = !state.opened.contains(path)
            // A shell window put only its lines in context, so it makes a ranged read a re-read and never a
            // whole one: the whole read paid for the file in full, and after a digest it is the read the digest
            // exists to save.
            let alreadyOpen = !firstRead || (ranged && state.windowed.contains(path))
            let lookup: SwiftLookup = if !ranged, state.hookDenied.contains(RefusalMemory.readKey(path)) {
                // The identical re-run of a whole read the hook answered in place: the answer named it as the
                // way to the raw output. Withheld on worth rather than on reach — the index recorded this file and had
                // just answered for it, so the half that says the index never owed the lookup would be a
                // false claim about a file it served a moment ago.
                .withheldOnWorth(rule: .retryAllowed)
            } else if alreadyOpen {
                .revisited(file: path)
            } else if !ranged, IndexSuggestion.digestTarget(for: path) == nil {
                // No call can ask for this file, so the hook never refuses a whole read of it (`ReadAdvice`),
                // and a read the hook declined to refuse is not a miss: it is withheld here on the same
                // property, as a `cat` of the same file is. The file is what is missing, not the pattern.
                .textSearch(cause: .unnameableFile)
            } else if !ranged, let reason = TextSearch.reason(forWholeRead: path, cwd: directory) {
                // A file in a tree no index holds — build output, a dependency's checkout, a scratch file — which
                // the hook lets through on this same verdict, so a whole read of it is no miss either. Which
                // count it may be added to, and which cause it is counted under, are the rule's own to say,
                // never this call site's.
                SwiftLookup(withheld: reason)
            } else if isBelowFloor(path, state: &state, belowFloor: belowFloor, consultFilesystem: consultFilesystem) {
                // Tested before the located branch: below the floor `digest` answers with the source itself,
                // so reading the file whole afterwards gets identical bytes. Filing that as a digest failure
                // would poison the metric with the majority case — most reads are of files short enough to
                // sit under the floor.
                .belowFloor(file: path)
            } else if ranged, state.guides(path, in: locatingRoot(ofFile: path, in: directory), wide: consultFilesystem && ListedWindow.isWide([LineWindow(offset: (input["offset"] as? NSNumber)?.intValue, limit: (input["limit"] as? NSNumber)?.intValue)], ofFileAt: path)) {
                .guided(file: path)
            } else if !ranged, state.digestedWhole(path, in: locatingRoot(ofFile: path, in: directory)) {
                .readWholeAfterDigest(file: path)
            } else {
                .cold(file: path, missed: nil)
            }
            state.opened.insert(path)
            return [hold(
                .lookup(lookup),
                block: block,
                path: path,
                opened: firstRead,
                counted: consultFilesystem,
                turn: turn,
                directory: workingDirectory,
                shape: refusedCallShape(read: path, cwd: directory),
                loggedLetThrough: probes.loggedLetThrough,
                in: &state
            )]
        case "Grep", "Glob":
            // Never guided: a search names no file, so there is nothing to have been guided to. Cold unless
            // the tool itself has said it could not serve this one — see `textSearch` below.
            //
            // Judged by exactly the rule the PreToolUse hook applies, because a looser one — "swift"
            // appearing anywhere in the arguments, lowercased — would count every single Grep in a repo whose
            // path holds `Swift`, and none at all in a repo called `Depot`. A miss the metric can
            // see and the hook cannot is a number that cannot be trusted; the reverse is a nudge that never
            // arrives.
            // Classified by the advisor that would have nudged this very call, so the audit's account of what
            // the misses wanted and the hook's account of what to do instead cannot disagree — and asked once,
            // because `isSwiftLookup` is this same call tested for nil and each one walks the tree to answer.
            guard let advice = SearchToolAdvice.suggestion(
                tool: rule ?? name,
                input: input,
                in: directory,
                memberExists: { memberExists($0, $1, directory) }
            ) else {
                return []
            }
            // Keyed on the arguments that decide the answer, exactly as `PreToolUseCommand.classified` keys
            // the ledger, so the search the hook let back through is the search excused here.
            let key = searchKey(tool: rule ?? name, input: input, directory: directory)
            // Scored a second time only where an earlier call of this turn, taken as answered, is this same
            // search: as it reads if the hook let that call through, which its result goes on to say.
            let ahead = LetThroughFallback.answeredAhead(of: turn, in: state).filter { $0.value == key }
            let search = SearchToolAdvice.textSearch(tool: rule ?? name, input: input, in: directory)
            let scored = { (denied: Set<String>) -> SwiftLookup in
                WithholdingLookup.lookup(
                    key: key,
                    suggestion: advice,
                    search: search,
                    denied: denied,
                    couldAnswerHere: { couldAnswer($0, directory) },
                    consultFilesystem: consultFilesystem
                ) ?? .cold(file: nil, missed: MissedCall(advice))
            }
            let lookup = scored(state.hookDenied.union(ahead.values))
            let fallback = ahead.isEmpty ? nil : LetThroughFallback(lookup: scored(state.hookDenied), key: key, readings: [], assumedAnswered: ahead)
            let sweep = Self.sweepEvent(for: lookup, key: key, in: &state)
            return [hold(
                .lookup(lookup),
                block: block,
                counted: consultFilesystem,
                key: key,
                fallback: fallback,
                turn: turn,
                directory: workingDirectory,
                shape: refusedCallShape(searchTool: rule ?? name, input: input, cwd: directory),
                loggedLetThrough: probes.loggedLetThrough,
                in: &state
            )] + (sweep.map { [$0] } ?? [])
        case "Bash":
            // The competitor the metric could not see. Same treatment as a search — a shell lookup went
            // around the index, and attributing it to a file would invite the guided/revisited logic on
            // something that is not a read of that file's contents in the same sense.
            // `cwd` is what makes `grep -rn Symbol Sources/` countable at all — it names no `.swift`, so the
            // command text alone cannot classify it, and without it every such sweep would be silently absent
            // from the denominator. Absent from the denominator means the share reads *higher* than the truth.
            // One probe for all three questions asked of this command below — the counting guard, the window
            // check and the advisor each resolve the same paths, and each walk costs up to `SwiftTree.visitLimit`
            // entries. Built here rather than three times inside them.
            let holdsSource = SwiftTree.probe(relativeTo: directory)
            // Made contiguous before anything reads it. `JSONSerialization` hands back strings backed by
            // `NSString`, and every character operation on one of those crosses into CoreFoundation to fetch a
            // UTF-16 unit at a time — which a profile of a full audit put at the top of the tree, above the
            // JSON parsing itself. The shell classifiers walk this string many times over, so paying once to
            // move it into Swift's own contiguous UTF-8 storage buys all of those back.
            guard var command = input["command"] as? String else { return [] }
            command.makeContiguousUTF8()
            // Asked first, and in the order the advice hook asks it: an invocation of this tool is the
            // advice being taken and is never a lookup that went around the index. Any subcommand is the
            // only thing in a transcript that can say a context reached the index without holding the MCP
            // tools (`TranscriptTally.couldNotReachTheIndex`).
            //
            // A lookup-shaped one — `digest`, `where`, `search`, `strings` — is also the index serving a
            // Swift lookup, and counts in the share like the matching MCP call, by the same reading
            // `invokesIndexCLI` already gives a refusal's follow-up. The route is not what the share asks
            // about. A `sift run -- swift build` is not that: a wrapped build answers no lookup and must
            // stay out of the numerator, which is why the two questions are asked separately rather than
            // `invokesSift` being read as both.
            var taken: [TranscriptEvent] = []
            if ShellInspection.invokesSift(command) {
                taken.append(.cliCall)
                // One per block that carries at least one, which is how every other tool call is counted
                // and how `cliCalls` has always counted these. A block running two queries is under-counted
                // by one, and under-counting the numerator is the direction this is allowed to err in.
                //
                // A document digest leaves the share here exactly as the MCP call does — the route is not
                // what the share asks about, and a Markdown lookup is outside the Swift population on both
                // sides. Read as "any `.md` among the arguments" rather than "every target", which the
                // structured arguments of an MCP call allow and a shell line does not: a command mixing a
                // document with Swift source leaves the share too, which under-counts the numerator — the
                // direction this branch already errs in, and never the one that flatters the number.
                // Counted now, provisionally — taken back on the result line if the line errors
                // (``creditShellCall(answering:block:failed:in:)``), never filed as an index failure: the error
                // may belong to another command sharing the line, not to the digest/where/search/strings
                // itself, exactly as a shell digest's location credit is never charged to the index either
                // (``TranscriptScanState/holdShellDigests(of:block:directory:)``).
                if invokesIndexCLI(command), !IndexCallTarget.documentDigest(inCommand: command) {
                    taken.append(contentsOf: [.lookup(.indexed), .cliLookup])
                    if consultFilesystem {
                        holdShellIndexedLookup(block: block, in: &state)
                    }
                }
                state.holdShellDigests(of: command, block: block, directory: directory)
                state.holdShellAnswer(of: command, block: block, directory: directory)
            }
            // **And then the command is classified anyway, which is a deliberate divergence from the hook.**
            // `sift where Foo; grep -rn Bar Sources/` is one call carrying two facts: the context reached
            // the index, and it also went around it. Returning on the first would drop the grep, and a cold
            // lookup dropped from the denominator makes the share read *higher* than the truth — the one
            // direction `TranscriptTally` may never round, and the same error the branch above it exists to
            // undo. So the two invariants in play are in genuine conflict on this input, and the code has to
            // pick one out loud rather than silently.
            //
            // The one that wins is the metric's, and the one that gives way is the rule two branches up:
            // the hook returns before it classifies whenever a Bash command invokes this tool
            // (`PreToolUseCommand.takesTheAdvice`), so this grep is a miss the metric can see and the hook
            // cannot. That rule is there so a search the tool *declined to claim it could serve* is not
            // then counted against it — the metric agreeing with the hook about what a lookup is. This is
            // not that: nothing declined it, the hook simply never looked, because denying anything on a
            // call that is also an index call is the one thing it may not do. Such compounds are a tiny
            // fraction of Bash calls — and of Bash calls only; the share's denominator is the lookups
            // themselves (indexed + cold + read whole after a digest), a far smaller population. Which is not why they are
            // counted anyway. They are counted because a denominator that quietly drops the awkward cases is
            // not a floor.
            guard ShellInspection.isSwiftLookup(command, holdsSource: holdsSource) else { return taken }
            // A windowed read of one named file is the shell spelling of a ranged Read, and is scored the
            // same way: a re-read when the file is already open in this context, guided when an index call
            // located it, cold when nothing did — and it opens the file for the windows and ranged reads that
            // follow it, never for a whole read, which pays for the file in full whatever part of it a window
            // already showed (`windowed`). Everything else a shell lookup can be is a
            // search, which names no file to have been guided to and so is never guided — and the escape
            // hatch needs no branch here: a window the hook answered in place leaves its file located by that
            // answer's digest, so the identical re-run is scored guided.
            if let path = ShellInspection.windowedReadPath(command, holdsSource: holdsSource) {
                // A token still holding a shell expansion — `sed -n '1,30p' $f.swift` inside a loop — reads
                // real files, but the text carries only the variable, so naming `$f.swift` in the report
                // invents a file no tree contains. The lookup still counts; it cannot be named, and it
                // cannot be guided either — `located` holds real stems an unexpanded token never matches.
                // No call is named here: with no file to name, there is no digest the hook could have offered.
                guard !path.contains("$"), !path.contains("`") else {
                    return taken + [hold(
                        .lookup(.cold(file: nil, missed: nil)),
                        block: block,
                        counted: consultFilesystem,
                        turn: turn,
                        directory: workingDirectory,
                        shape: refusedCallShape(bash: command, cwd: directory),
                        loggedLetThrough: probes.loggedLetThrough,
                        in: &state
                    )]
                }
                // Keyed on the path spelled out in full, because that is how a `Read` names the same file:
                // `sed -n '120,160p' Sources/App/View.swift` after a Read of `/repo/Sources/App/View.swift`
                // is a re-read, and comparing the two as written would score it cold every time. A relative
                // path behind a `cd` in the same command is spelled out against where each literal `cd` moves,
                // as the hook places it (`ShellAdvice.lookupDirectories`); behind a move that cannot be followed
                // it is scored as it always was: judged no re-read and opening nothing, since guessing the file
                // would excuse a lookup on the strength of a different file being open.
                let file = !path.hasPrefix("/") && changesDirectory(command)
                    ? ShellAdvice.lookupDirectories(of: command, holdsSource: holdsSource, cwd: workingDirectory, requiringDirectories: false)?.first
                    .flatMap { InPlaceShape.resolve(path, against: $0) }
                    : absolute(path, in: workingDirectory)
                let alreadyOpen = file.map { state.opened.contains($0) || state.windowed.contains($0) } ?? false
                // The floor is asked exactly as for the ranged Read this window stands for, and before the located
                // branch for the same reason: below it `digest` hands back the source, so the window saved nothing
                // a digest would have. Only a path spelled out in full is probed — a relative one with no
                // directory would be read against the audit's own working directory, which is another file.
                let spelledOut = file.flatMap { $0.hasPrefix("/") ? $0 : nil }
                let lookup: SwiftLookup = if alreadyOpen {
                    .revisited(file: path)
                } else if let spelledOut,
                          isBelowFloor(spelledOut, state: &state, belowFloor: belowFloor, consultFilesystem: consultFilesystem)
                {
                    .belowFloor(file: path)
                } else if state.guides(file ?? path, in: file.map { locatingRoot(ofFile: $0, in: directory) } ?? locatingRoot(directory), wide: consultFilesystem && spelledOut.map { ListedWindow.isWide(readBy: command, ofFileAt: $0, holdsSource: holdsSource) } == true) {
                    .guided(file: path)
                } else {
                    .cold(file: path, missed: nil)
                }
                let firstWindow = file.map { !state.windowed.contains($0) } ?? false
                if let file {
                    state.windowed.insert(file)
                }
                return taken + [hold(
                    .lookup(lookup),
                    block: block,
                    path: file ?? path,
                    opened: firstWindow,
                    shellWindow: true,
                    counted: consultFilesystem,
                    turn: turn,
                    directory: workingDirectory,
                    shape: refusedCallShape(bash: command, cwd: directory),
                    loggedLetThrough: probes.loggedLetThrough,
                    in: &state
                )]
            }
            // Built with the directory the hook had, so a member offer is checked against the same index the
            // hook checked it against and the two ends name the same call — withheld outside a `--since`
            // window with every other probe, where the classification is discarded anyway.
            // A line of several lookups is about the first one the hook had not already answered, as the hook
            // chooses it (`PreToolUseCommand.classified`): its answers are what `hookDenied` holds, so the
            // lookup scored — and the key an answer to it is remembered by — is the one the hook spoke about.
            // An earlier call of this same turn counts as answered already: its hook ran, and recorded its
            // answer, before this call's hook did, though its result is written after this call. The line is
            // scored a second time where one of those earlier calls decides which lookup it is about, as it
            // reads if the hook let that call through, and the earlier call's result says which was right.
            let ahead = LetThroughFallback.answeredAhead(of: turn, in: state)
            let keys = ShellAdvice.lookupKeys(for: command, holdsSource: holdsSource)
            // A whole read of a digested file is that miss whichever tool made it (`ShellReadAfterDigest`).
            let readAgain = ShellReadAfterDigest.file(readBy: block, cwd: workingDirectory, directory: directory, state: &state, belowFloor: belowFloor, consultFilesystem: consultFilesystem)
            let scored = { (denied: Set<String>) in
                ShellReadAfterDigest.rescoring(shellReading(of: command, denied: denied, holdsSource: holdsSource, in: workingDirectory, probes: probes, consultFilesystem: consultFilesystem), readingWhole: readAgain)
            }
            let judged = scored(state.hookDenied.union(ahead.values))
            let (lookup, key, readings) = (judged.lookup, judged.key, judged.readings)
            let deciding = ahead.filter { keys.contains($0.value) || $0.value == key }
            var fallback = deciding.isEmpty ? nil : scored(state.hookDenied)
            fallback?.assumedAnswered = deciding
            let sweep = Self.sweepEvent(for: lookup, key: key, in: &state)
            return taken + [hold(
                .lookup(lookup),
                block: block,
                counted: consultFilesystem,
                key: key,
                readings: readings,
                fallback: fallback,
                turn: turn,
                directory: workingDirectory,
                shape: refusedCallShape(bash: command, cwd: directory),
                loggedLetThrough: probes.loggedLetThrough,
                in: &state
            )] + (sweep.map { [$0] } ?? [])
        default:
            return []
        }
    }

    /// Whether a line could possibly hold a countable block, decided on raw bytes.
    ///
    /// A successful result carries none of the fixed markers — no tool name, no failure flag, just the reply — whether it answers an index call, a shell digest or a held read, so the ids still awaiting a result are markers too. Both kinds, because both are dropped only by the line that answers them: an index call's answer is what credits what it located, and a read's success is what releases its held entry, which otherwise sits in the scan state for good. Matching on the ids rather than on something in the result keeps the filter exact: only the results of calls this scan actually saw are parsed, whatever they happen to say. The sets stay small because an id is dropped the moment its result arrives, success or failure.
    ///
    /// While a refusal waits to be priced every assistant line counts, the text-only one that opens the next turn included: that line carries the usage the round trip is priced by, and nothing else on it could pass.
    private static func mayContribute(
        _ line: Data,
        awaiting pendingIndexCallIDs: some Collection<String>,
        shellDigests pendingShellDigestIDs: some Collection<String>,
        shellAnswers pendingShellAnswerIDs: some Collection<String>,
        reads pendingReadIDs: some Collection<String>,
        nextTurn: Bool
    ) -> Bool {
        if markers.contains(where: { line.range(of: $0) != nil }) {
            return true
        }
        if nextTurn, assistantMarkers.contains(where: { line.range(of: $0) != nil }) {
            return true
        }
        let awaited = { (id: String) in line.range(of: Data(id.utf8)) != nil }
        return pendingIndexCallIDs.contains(where: awaited) || pendingShellDigestIDs.contains(where: awaited)
            || pendingShellAnswerIDs.contains(where: awaited) || pendingReadIDs.contains(where: awaited)
    }

    /// An assistant line, in either spacing of its key.
    private static let assistantMarkers: [Data] = [#""type":"assistant""#, #""type": "assistant""#].map { Data($0.utf8) }

    /// The byte pre-filter: a line carrying none of these cannot be a lookup or a failure, and is skipped before anything parses it.
    ///
    /// Both spacings of the failure marker are listed because this is a pre-filter over *someone else's* file format: today's transcripts write `"is_error":true` compactly, but a writer that ever emitted `"is_error": true` would make failures silently uncountable, and a filter that quietly stops matching is the worst shape of bug available here. The other markers are values and a tool-name prefix, which key-value spacing cannot affect.
    ///
    /// The unquoted `Xcode` catches that server's `XcodeRead`/`XcodeGrep`/`XcodeGlob`, whose names the quoted forms above miss by one character — and a pre-filter that quietly stops matching would make those lookups uncountable without ever failing.
    ///
    /// This tool's own prefix is taken from ``IndexToolName/prefix`` rather than written out again, so the name it answers to can never be known to the classifier and unknown to the filter — which would leave the classifier's branch unreachable and every call under that name uncounted, with nothing anywhere saying so.
    ///
    /// The harness's report of failed servers is matched on its key alone, whatever the list holds: the lines carrying it are a handful per transcript, so parsing each costs nothing, and matching on the shape of a non-empty value would be the spacing trap again.
    ///
    /// Every tool call counts toward its turn, whatever the tool, because a refusal that shared its turn with an `Edit` cost no round trip of its own — so `"tool_use"`, a value no other key carries, lets every call line through. The key a result names its call by is `"tool_use_id"`, which the quote closing the value keeps it from matching.
    ///
    /// `"prompt_snapshot"` is its own marker rather than relying on one of the above: the tool-presence question it answers is decided most often by its *absence* from a context's tool list, and a snapshot silent about this server carries none of the other markers either — no `mcp__sift__`, and often no `"Bash"`, `"Read"` or the rest, if the allowlist that shaped it left those out too. `"deferred_tools_delta"` is a marker for the same reason: whether the held-back half of a tool list was written down at all is part of proving sift was not in it, and a delta that names no sift tool and no failed server carries nothing else here.
    ///
    /// `"hook_non_blocking_error"` lets through the harness's record of a hook failing, which is where a missing binary at session start is written — a handful of lines per transcript, and none at all where every hook ran.
    private static let markers: [Data] = ([IndexToolName.prefix] + [
        "\"Read\"", "\"Grep\"", "\"Glob\"", "\"Bash\"", "Xcode",
        "\"is_error\":true", "\"is_error\": true",
        "\"failedMcpServers\"", "\"tool_use\"",
        "\"prompt_snapshot\"", "\"deferred_tools_delta\"", "\"hook_non_blocking_error\"",
    ]).map { Data($0.utf8) }
}

/// Split from the class body to keep it under SwiftLint's type-body-length cap.
///
/// What a call or its answer located: the Swift file stems an index call's arguments name, and the ones its answer's text names in turn.
extension TranscriptScan {
    /// The instant an ISO-8601 transcript timestamp names, or nil if it is not one.
    static func instant(_ text: String) -> Date? {
        TranscriptTimestamp.instant(text) ?? fractionalTimestamps.date(from: text) ?? wholeSecondTimestamps.date(from: text)
    }

    /// The parser of a timestamp written to the millisecond, as the harness writes every one.
    ///
    /// Built once rather than per timestamp: making the formatter costs several times the parse, and an audit parses one for every line of every transcript it reads. A formatter nothing mutates after it is made is safe to share across threads, which is what `nonisolated(unsafe)` asserts: the type is not marked `Sendable`.
    nonisolated(unsafe) private static let fractionalTimestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// The parser of a timestamp written to the whole second, built once for the same reason.
    nonisolated(unsafe) private static let wholeSecondTimestamps = ISO8601DateFormatter()

    /// Whether an index call's error was written by the harness in place of the call, which therefore never reached the server.
    ///
    /// The tool is not in this context at all (`No such tool available: …`, with or without the sentence naming the server): the harness speaking about the call rather than relaying an answer to it. Matched on the harness's own wording because nothing else on the line tells it apart — an error from the server itself arrives as the same `is_error` result, and it is the one kind that says anything about the index.
    ///
    /// A permission check that could not rule is not this, though it never reached the server either: see ``stoppedAtThePermissionCheck(_:)``.
    static func neverReachedTheServer(_ reason: String) -> Bool {
        reason.contains("No such tool available")
    }

    /// Whether an index call's error is the harness reporting that the permission check stopped the call: the user declined it at the prompt, or the auto-mode classifier could not rule on it in time.
    ///
    /// One kind, because both say the same two things. Neither is a failure of the index, which never saw the call, and neither is a lookup that went around it. And both prove the context held the tool: the harness asks the user about, and the classifier rules on, only a tool the context has, so reading a check that timed out as the tool being absent would let it excuse a context that provably had the index. Matched on the harness's own wording, for the reason ``neverReachedTheServer(_:)`` is: the result is an `is_error` like any other, and only the text says the permission step answered it rather than the server.
    static func stoppedAtThePermissionCheck(_ reason: String) -> Bool {
        reason.contains("The user doesn't want to proceed with this tool use")
            || reason.contains("so auto mode cannot determine the safety of")
    }

    /// How a lookup refusal is told apart from every other error a tool can return: the offer line it opens with, minus the tool's own name.
    ///
    /// Read off `IndexSuggestion` rather than spelled again, so the refusal and the thing that recognises it cannot drift apart.
    static var lookupOfferSuffix: String {
        IndexSuggestion.lookupOfferSuffix
    }

    /// A tool result's text, which the transcript writes either as a bare string or as typed content blocks.
    static func answerText(of block: [String: Any]) -> [String] {
        if let text = block["content"] as? String {
            return [text]
        }
        guard let blocks = block["content"] as? [[String: Any]] else { return [] }
        return blocks.compactMap { $0["text"] as? String }
    }

    /// The two symbol questions `events(forToolUse:on:state:belowFloor:probes:consultFilesystem:)` asks, together — `couldAnswer` the bare-name question, `memberExists` the type-and-member one — so that worker stays inside the parameter count every function here holds to, without giving either question a name that outlives the call the way a shared mutable field would.
    ///
    /// `loggedLetThrough` rides with them for the same reason: the `tool_use_id`s the hook's suppression log records letting run on worth, with the rule, handed in by the caller and never persisted in the scan state, since nothing the hook lets run leaves a mark in the transcript.
    private struct SymbolProbes {
        let couldAnswer: (String, String?) -> Bool
        let memberExists: (String, String, String?) -> Bool
        let loggedLetThrough: [String: InPlaceAnswerer.Withholding]
    }

    /// The Swift file stems an index call's arguments could be about.
    ///
    /// Deliberately generous. `digest RecordDetailState.DetailData` is about `RecordDetailState.swift` while `digest SiftCore.DigestRenderer` is about `DigestRenderer.swift` — which component names the file depends on whether the qualifier is a type or a module, and the transcript does not say. Every component is taken. Over-matching costs one read scored generously; under-matching puts the digest-then-read loop back in the raw column, which is the thing this exists to stop.
    ///
    /// `digest`'s several targets arrive as a list under `targets`, and each is read exactly as a single `target` is. A `target` is never split, whatever it holds: a path with a space in it is one file, and an old transcript is scored as it always was.
    ///
    /// A line-range target (`File.swift:12-40`) names its file by its path: the lines are taken off before the stem is, or `File.swift:12-40` would reach the stem only by the accident of splitting at the dot before `swift`.
    ///
    /// Reads both `target` and `symbol` with no regard to which tool sent them — the caller here (`creditAnswer`) has only the plain name a refusal's own text spelled, not the original arguments a tool could be read against, so there is no key to scope this to.
    static func locatedNames(in input: [String: Any]) -> Set<String> {
        var values = ["target", "symbol"].compactMap { input[$0] as? String }
        values += input["targets"] as? [String] ?? []
        var names: Set<String> = []
        for value in values where !value.isEmpty {
            let named = DigestLineRange.parse(value)?.path ?? value
            for component in stem(ofPath: named).split(separator: ".") where !component.isEmpty {
                names.insert(String(component))
            }
        }
        return names
    }

    /// Read from the call as the server resolved it (``ArgumentAlias/resolved(tool:arguments:)``), not as the transcript records it.
    ///
    /// The model's own record of `digest name:"Engine"` or `digest path:"Sources/Foo.swift"` never gains the `target` key the server healed it into, and without the healing a digest the server answered would locate nothing, scoring the ranged read it earned as a miss. Reading the resolved call also keeps what a key locates to exactly the tools it is healed for — a `path:` sent to `where`, which has no argument it stands for, locates nothing, as the server read nothing from it.
    ///
    /// Only the one key the tool itself reads is credited (``ArgumentAlias/nameArgument``), and only for the two tools whose argument is a Swift name or a file (``ArgumentAlias/nameOnlyArgument``): `digest`'s `target:` and `where`'s `symbol:`. A `target:` sent to `where` beside its `symbol:` is read by nothing, so the answer was never about the file it names, and crediting it would score a cold read as guided. `digest`'s several targets, and a line-range target's own file, are read exactly as ``locatedNames(in:)`` reads them.
    static func locatedNames(in input: [String: Any], tool: String) -> Set<String> {
        guard ArgumentAlias.nameOnlyArgument.contains(tool), let key = ArgumentAlias.nameArgument[tool] else { return [] }
        let resolved = ArgumentAlias.resolved(tool: tool, arguments: input).arguments
        var values = (resolved[key] as? String).map { [$0] } ?? []
        values += resolved["targets"] as? [String] ?? []
        var names: Set<String> = []
        for value in values where !value.isEmpty {
            let named = DigestLineRange.parse(value)?.path ?? value
            for component in stem(ofPath: named).split(separator: ".") where !component.isEmpty {
                names.insert(String(component))
            }
        }
        return names
    }

    /// The Swift file stems an index call's *answer* named.
    ///
    /// `locatedNames(in:)` reads the arguments, which is enough for `digest` and `where` because their argument *is* the name. `search` is asked in `field:value` terms that name no file at all, so without this every ranged read of a file a search had just located would score as a miss — the digest-then-read loop counted, the search-then-read loop punished, when the guidance pushes searching hardest of the two.
    ///
    /// A module or repo overview names many files and credits them all. That is the same generosity the argument side already takes, and in the same direction: the overview did locate them.
    ///
    /// The sites a `where` lists by name match, where the store could not answer, credit nothing (`NameMatchedSites`). They are spellings that agree with the name rather than locations the index resolved — same-named members of unrelated types, same-named locals and parameters — so a read of a file that only they named was not led there by anything the index established, and scoring it guided would take a miss out of the share on the strength of a text match. The declarations the same answer resolved still credit their files.
    static func locatedNames(inAnswer block: [String: Any]) -> Set<String> {
        var names: Set<String> = []
        for text in answerText(of: block) {
            for line in NameMatchedSites.linesOutside(answer: text) where !isNotice(line) {
                for token in line.split(whereSeparator: { $0.isWhitespace || $0 == "," }) {
                    guard let stem = pathStem(inToken: token) else { continue }
                    names.insert(stem)
                }
            }
        }
        return names
    }

    /// A line whose files the answer is warning about, or merely suggesting as the next call to make, rather than locating.
    ///
    /// The parse-error and guessed-module banners both name real `.swift` paths, and both say the same thing about them: this answer may be wrong about these files, so read them directly. Crediting a read of one as guided would let the index's own admission of doubt *raise* its share — `guided` leaves `TranscriptTally.total` while `cold` does not — which is the one direction this metric must never round. A renderer's own `digest <target>` line is the same kind of admission for an ambiguous or missing-file answer: the exact targets it offers instead of settling on one, so crediting any of them as located would undo the "ambiguous" verdict that named them precisely so none would be mistaken for the answer. A missing file's own line (no indexed file at one path, served another) names a path that holds no indexed file, so what it served is left to that file's own header.
    static func isNotice(_ line: Substring) -> Bool {
        let trimmed = line.drop(while: \.isWhitespace)
        return trimmed.hasPrefix("⚠") || trimmed.hasPrefix("digest ") || trimmed.hasPrefix("no indexed file ")
    }

    /// The file stem a token names, or `nil` when the token is not a path.
    ///
    /// The extension has to end the path rather than merely appear in it: `Foo.swiftinterface` and `Foo.swiftmodule` are not `Foo.swift`, and a below-floor digest serves the file's own source, so `path.hasSuffix(".swift")` in that source would otherwise credit a stem spelled `path.hasSuffix("`.
    private static func pathStem(inToken token: Substring) -> String? {
        guard let extensionRange = token.range(of: ".swift") else { return nil }
        if let following = token[extensionRange.upperBound...].first, following.isLetter || following.isNumber {
            return nil
        }
        let path = token[token.startIndex ..< extensionRange.lowerBound]
        guard let name = path.split(separator: "/").last else { return nil }
        let stem = name.drop { "([\"'`".contains($0) }
        return stem.isEmpty ? nil : String(stem)
    }

    /// The file name a path or target ends in, without its `.swift` extension.
    static func stem(ofPath path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name.hasSuffix(".swift") ? String(name.dropLast(6)) : name
    }
}

extension TranscriptScan {
    /// The message an errored result carried, as one line.
    ///
    /// Collapsed to its first non-empty line because several of the server's messages continue into an indented list of the roots or fields it means, and a report grouping failures needs the sentence rather than the appendix. Empty when the result carried no text at all, which is what an older transcript can look like.
    private static func failureReason(of block: [String: Any]) -> String {
        for text in answerText(of: block) {
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return ""
    }

    /// Marks the file a write or an edit names as opened, answering whether the call was one.
    private static func notesWrite(_ name: String, input: [String: Any], in state: inout TranscriptScanState) -> Bool {
        guard LookupTool.writes(name) else { return false }
        if let path = LookupTool.readPath(in: input) {
            state.opened.insert(path)
        }
        return true
    }

    /// A path a shell command named, spelled out in full against the directory it ran in, as a `Read` of the same file would carry it.
    ///
    /// Left as written when it is already absolute or there is no directory to resolve it against — then it matches only a read that spelled it the same way, which misses a re-read rather than inventing one.
    private static func absolute(_ path: String, in directory: String?) -> String {
        guard !path.hasPrefix("/"), let directory else { return path }
        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: directory, isDirectory: true)).standardizedFileURL.path
    }

    /// Whether a shell command moves to another directory before what follows it runs, so its relative paths are not relative to the line's own.
    ///
    /// Read off the segment's command word rather than its first token, so a brace group or subshell (`{ cd Kit; …; }`, `(cd Kit && …)`) and an environment assignment in front are stepped over, and so is `builtin` or `command` in front of the word itself. A subshell's `cd` may end before the path is read, and counting it anyway only withholds a guess, which is the direction this is allowed to err in. The segments are the ones the window was read from, command substitutions included, so the `cd` in `$(cd Kit && sed -n '1,30p' View.swift)` is seen.
    static func changesDirectory(_ command: String) -> Bool {
        ShellSyntax.executedSegments(of: command).contains { segment in
            let words = ShellQuery(segment).invocation.drop { ["builtin", "command"].contains($0) }
            return words.first.map { ["cd", "pushd", "popd"].contains($0) } ?? false
        }
    }

    /// Whether a first touch of `path` cost nothing a digest would have saved, decided on the transcript's own evidence wherever it holds any.
    ///
    /// **The transcript first.** A whole-file digest of this file earlier in the context recorded the floor's decision in its own answer, and that record is exact and permanent; the disk is neither — an audit runs days later, over worktrees that have since been deleted, and a file that cannot be read is never excused. So where a digest decided, its decision stands in both directions and the disk is not asked. Only where no digest of the file came back is the disk consulted, and that is remembered (`floorFromDisk`) so a report can say how much of its count rests on it.
    ///
    /// Outside a `--since` window the disk is never consulted, exactly as before: the classification is discarded there.
    static func isBelowFloor(
        _ path: String,
        state: inout TranscriptScanState,
        belowFloor: (String) -> Bool,
        consultFilesystem: Bool
    ) -> Bool {
        if let verdict = state.floorVerdict(forRead: path) {
            return verdict
        }
        guard consultFilesystem else { return false }
        state.floorFromDisk.insert(path)
        return belowFloor(path)
    }

    /// Records a counted lookup against its `tool_use_id` so an error result can take it back, and returns it — unchanged, but for a cold one the hook logged letting run on worth, which is not worth under the rule it logged.
    ///
    /// Every tool the advice hook can refuse goes through here, not just `Read`. The hook denies `Bash`, `Grep` and `Glob` on the same rule and in the same shape, and shell lookups are typically the larger column by some way. Holding only reads would fix the smaller half and leave the share still falling every time the hook succeeded.
    ///
    /// `turn` and `directory` are where the call was made — its assistant turn and the directory it ran in — which a refusal of it is priced by and an answer given in its place is placed against.
    private static func hold(
        _ event: TranscriptEvent,
        block: [String: Any],
        path: String = "",
        opened: Bool = false,
        shellWindow: Bool = false,
        counted: Bool,
        key: String = "",
        readings: [ServedReading] = [],
        fallback: LetThroughFallback? = nil,
        turn: String?,
        directory: String?,
        shape: RefusedCallShape = RefusedCallShape(tool: "", text: "", kind: .other),
        loggedLetThrough: [String: InPlaceAnswerer.Withholding] = [:],
        in state: inout TranscriptScanState
    ) -> TranscriptEvent {
        guard case var .lookup(lookup) = event, let id = block["id"] as? String else { return event }
        var fallback = fallback
        if let why = loggedLetThrough[id] {
            lookup = lookup.scored(letThroughAs: why)
            if let scored = fallback?.lookup.scored(letThroughAs: why) {
                fallback?.lookup = scored
            }
        }
        state.pendingReads[id] = PendingRead(
            lookup: lookup,
            path: path,
            openedPath: opened,
            shellWindow: shellWindow,
            counted: counted,
            key: key,
            readings: readings,
            fallback: fallback,
            turn: turn,
            directory: directory,
            shape: shape
        )
        return .lookup(lookup)
    }

    /// The shape of a refused whole-file `Read`, read by ``RefusedCallShapeClassifier``.
    static func refusedCallShape(read path: String, cwd: String? = nil) -> RefusedCallShape {
        RefusedCallShapeClassifier.shape(read: path, cwd: cwd)
    }

    /// The shape of a refused `Grep`/`Glob`, read by ``RefusedCallShapeClassifier``.
    static func refusedCallShape(searchTool tool: String, input: [String: Any], cwd: String? = nil) -> RefusedCallShape {
        RefusedCallShapeClassifier.shape(searchTool: tool, input: input, cwd: cwd)
    }

    /// The shape of a refused Bash lookup, read by ``RefusedCallShapeClassifier``.
    static func refusedCallShape(bash command: String, cwd: String? = nil) -> RefusedCallShape {
        RefusedCallShapeClassifier.shape(bash: command, cwd: cwd)
    }

    /// What followed a lone refusal: the next tool call the transcript wrote after it, classified without regard to what that call itself went on to do.
    ///
    /// A re-run is judged on the same tool and identical input, both read the way the refused call's own shape was built — so a ranged `Read` of the same file, or a `Grep` that changed one field, is `other`, never `reRun`.
    static func followUp(after refused: RefusedCallShape, name: String, input: [String: Any]) -> RefusalFollowUp {
        if IndexToolName.tool(named: name) != nil {
            return .index
        }
        if name == "ToolSearch", toolSearchLoadsSift(input) {
            return .index
        }
        if LookupTool.rule(for: name) == "Bash", let command = input["command"] as? String, invokesIndexCLI(command) {
            return .index
        }
        if let rule = LookupTool.rule(for: name), rule == refused.tool,
           let key = followUpKey(rule: rule, input: input), key == refused.key
        {
            return .reRun(shape: refused.kind, call: refused.text)
        }
        return .other
    }

    /// The follow-up call's own identity key, built exactly the way the refused call's ``RefusedCallShape/key`` was, so the two can be compared for an identical re-run — `nil` when this call cannot be identical to any refused call of this tool, such as a ranged `Read`.
    private static func followUpKey(rule: String, input: [String: Any]) -> String? {
        switch rule {
        case "Read":
            guard let path = LookupTool.readPath(in: input) else { return nil }
            let ranged = input["offset"] is NSNumber || input["limit"] is NSNumber
            return ranged ? nil : "Read \(path)"
        case "Grep", "Glob":
            return refusedCallShape(searchTool: rule, input: input).key
        case "Bash":
            guard var command = input["command"] as? String else { return nil }
            command.makeContiguousUTF8()
            return "Bash: \(command)"
        default:
            return nil
        }
    }

    /// Whether a `ToolSearch` call is loading one of this server's own tools — the way a deferred `mcp__sift__*` tool actually reaches a context, so the refusal it follows redirected exactly as calling the tool itself would have.
    ///
    /// True for a query naming a tool directly (`select:mcp__sift__digest,mcp__sift__where`) and for a keyword query that names the server (`sift where`, `+sift digest`) — read as a whole word, so a query for an unrelated tool whose name merely contains the letters is never mistaken for one.
    private static func toolSearchLoadsSift(_ input: [String: Any]) -> Bool {
        guard let query = input["query"] as? String else { return false }
        if query.contains(IndexToolName.prefix) {
            return true
        }
        return query.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).contains(Substring(IndexToolName.server))
    }

    /// Holds the `tool_use_id` of a Bash call counted as an indexed lookup on the way out, so its line's result can take that count back if it errors.
    ///
    /// Called only for a call counted inside the window, so the held set is exactly what an error could take back.
    private static func holdShellIndexedLookup(block: [String: Any], in state: inout TranscriptScanState) {
        if let id = block["id"] as? String {
            state.pendingShellLookups.insert(id)
        }
    }

    /// Everything a Bash line's result credits: what its shell digests located, the files a line of `sift where`/`sift search` lookups listed, and — taken back if the line errored — the `.indexed`/``TranscriptEvent/cliLookup`` a lookup-shaped call on it was provisionally counted as.
    ///
    /// Only a call counted inside the window is held for that, so the result is taken back whichever side of the window it lands on.
    ///
    /// The error is the whole line's, not the index's — it may belong to another command sharing it — so this never files an index failure, only the retraction of what was already counted (``TranscriptScanState/pendingShellLookups``), exactly as a failed line locates nothing (``TranscriptScanState/creditShellDigests(answering:block:failed:)``).
    private static func creditShellCall(answering id: String, block: [String: Any], failed: Bool, in state: inout TranscriptScanState) -> [TranscriptEvent] {
        state.creditShellDigests(answering: id, block: block, failed: failed)
        state.creditShellAnswer(answering: id, block: block, failed: failed)
        guard state.pendingShellLookups.remove(id) != nil, failed else { return [] }
        return [.lookupRetracted(.indexed), .cliLookupRetracted]
    }

    /// Whether this Bash command invokes `sift digest`/`where`/`search`/`strings` — the CLI form of an index call, which redirects a refusal exactly as the matching MCP tool would and serves a lookup exactly as it would.
    ///
    /// Read off the subcommand rather than off `invokesSift` alone, which is true of every subcommand the binary has: `sift run -- swift build` reaches the tool without asking it anything about Swift. Two callers ask it, and they are the two places a CLI call has to be told from a wrapped run — what a refusal's follow-up reached for, and what counts in the share.
    private static func invokesIndexCLI(_ command: String) -> Bool {
        for segment in ShellSyntax.executedSegments(of: command) {
            let query = ShellQuery(segment)
            guard query.invokesSift, let siftIndex = query.invocation.firstIndex(where: {
                URL(fileURLWithPath: $0).lastPathComponent == "sift"
            }) else { continue }
            let subcommand = query.invocation[(siftIndex + 1)...].first { !$0.hasPrefix("-") }
            if let subcommand, ["digest", "where", "search", "strings"].contains(subcommand) {
                return true
            }
        }
        return false
    }

    /// The round trips the turn now ending cost, priced by the turn beginning: one for a refusal that was the only call in its turn, none where it shared the turn with other calls — the next turn was coming for them anyway.
    ///
    /// The price is what the next turn re-sent — its input tokens, cache reads and cache writes, split the way `message.usage` bills them — because every turn re-sends everything the context holds, and that is what acting on a refusal costs whatever the refusal itself said.
    ///
    /// Each refusal priced here is also queued for its own follow-up classification (``TranscriptScanState/awaitingFollowUp``): the next `tool_use` block the transcript writes, wherever it falls, says what came of it.
    private static func roundTrips(of state: inout TranscriptScanState, nextTurnUsage usage: [String: Any]?) -> [TranscriptEvent] {
        guard state.turnToolUses == 1, let turn = state.turn, let usage else { return [] }
        let cost = roundTripCost(from: usage)
        let matching = state.awaitingRoundTrip.filter { $0.turn == turn }
        for pending in matching {
            state.awaitingFollowUp.append(PendingFollowUp(shape: pending.shape, cost: cost))
        }
        return matching.map { _ in .refusalRoundTrip(cost: cost) }
    }

    /// `usage` read as a ``RoundTripCost``: the flat `cache_creation_input_tokens` read as a five-minute write when `message.usage` carries no `cache_creation` split.
    private static func roundTripCost(from usage: [String: Any]) -> RoundTripCost {
        let uncached = usage["input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let flatWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
        if let split = usage["cache_creation"] as? [String: Any] {
            return RoundTripCost(
                uncachedInputTokens: uncached,
                cacheReadTokens: cacheRead,
                cacheWrite5mTokens: split["ephemeral_5m_input_tokens"] as? Int ?? 0,
                cacheWrite1hTokens: split["ephemeral_1h_input_tokens"] as? Int ?? 0
            )
        }
        return RoundTripCost(uncachedInputTokens: uncached, cacheReadTokens: cacheRead, cacheWrite5mTokens: flatWrite)
    }

    /// The repository `directory` is in, canonicalized as ``CallerRoot`` resolves one — `""` where none is known — the key `located`/`digested` are filed and read under.
    static func locatingRoot(_ directory: String?) -> String {
        directory.flatMap { CallerRoot.root(forCallerIn: $0) } ?? ""
    }

    /// The repository the file at `path` is in, as the advice hook keys a located file — by the file's own repository rather than the one the call was made from, so a window of a file in another checkout is judged against that checkout's answers — or, where the file's own cannot be told, the one `directory` is in.
    ///
    /// Asked of the filesystem only where `directory` is known, as every other root here is, and only for a path spelled out in full: a relative one would be resolved against the scan's own working directory.
    static func locatingRoot(ofFile path: String, in directory: String?) -> String {
        guard directory != nil, path.hasPrefix("/") else { return locatingRoot(directory) }
        return CallerRoot.root(forCallerIn: (path as NSString).deletingLastPathComponent) ?? locatingRoot(directory)
    }

    /// Credits what a refusal answered in place located, as an index call's answer is credited: the file or name its call named, the files its answer listed, and a whole-file digest's floor verdict.
    ///
    /// The call is read off the refusal's opening line in either spelling it is written in — `digest …` or, once the server has gone from the context, `sift digest '…'` — and a reference sweep's `(refs: true)`, or its `--refs` for Bash, is set aside from its target. `note` is the opening line's aside, where one call on the line makes it bounded outright and several read it as naming their own target.
    private static func creditAnswer(call: String, block: [String: Any], for pending: PendingRead, note: String?, soleCall: Bool, in state: inout TranscriptScanState) {
        var spelled = call.hasPrefix("sift ") ? String(call.dropFirst("sift ".count)) : call
        for suffix in [InPlaceAnswer.referencesFlag, InPlaceAnswer.referencesArgument] where spelled.hasSuffix(suffix) {
            spelled.removeLast(suffix.count)
        }
        guard let space = spelled.firstIndex(of: " ") else { return }
        let tool = String(spelled[..<space])
        var target = String(spelled[spelled.index(after: space)...])
        if target.count >= 2, target.hasPrefix("'"), target.hasSuffix("'") {
            target = String(target.dropFirst().dropLast()).replacing(#"'\''"#, with: "'")
        }
        let bounded = note.map { soleCall || $0.contains(target) } ?? false
        // In-place answers are about the repository the refused line's lookups ran in — the call never carried a
        // `--root` of its own — so this is keyed the same way a read in that repository is: the one its `cd`s moved
        // into where that is still found, as a shell digest behind a `cd` is keyed, else the line's own.
        let movedTo = pending.answeredFrom
        let movedRoot = movedTo == pending.directory ? nil : movedTo.flatMap { CallerRoot.root(forCallerIn: $0) }
        let root = movedRoot ?? locatingRoot(pending.directory)
        // The refused read's own file is what the answer resolved its target against, so its directory — else where
        // the line's `cd` moved, not where it was run from — spells the file once that checkout is gone.
        let named = pending.path.hasPrefix("/") ? pending.path : pending.pathInFull(of: target)
        // Behind a move that cannot be followed the answer is about a checkout nothing here can tell, so it locates
        // nothing — unless the line spelled its file out in full.
        guard named != nil || pending.answerIsPlaced else { return }
        let answeredAt = named.map { ($0 as NSString).deletingLastPathComponent } ?? pending.answeredFrom
        if tool == "digest" {
            // A bounded window's call is spelled as the whole file's digest without being one, so it locates the
            // file and stops there — crediting it as a whole digest would let a later whole read of the same
            // file score as the loop working when only some of it was ever shown.
            let text = answerText(of: block).joined(separator: "\n")
            state.digests[root, default: []].formUnion(LocatedDigest.credited(targets: [target], whole: !bounded, answer: text, anchor: answeredAt))
        } else {
            state.located[root, default: []].formUnion(locatedNames(in: ["target": target]).union(locatedNames(inAnswer: block)))
        }
        // A bounded answer's text is member listings, not the file's own digest, so no floor verdict can be
        // read out of it for `target` — the whole-file digest it stands in for was never actually rendered.
        guard tool == "digest", !bounded,
              let answer = InPlaceAnswer.answer(inReason: answerText(of: block).joined(separator: "\n")),
              let verdict = SourcePassthrough.fileVerdict(in: answer, of: target)
        else {
            return
        }
        // Placed where the line's `cd` moved, as its digest is: the answer names its file relative to that checkout.
        state.recordFloorVerdict(verdict, anchor: pending.answeredFrom, adopted: nil, tree: WorkingTree.named(inAnswer: answer))
    }

    /// A shell line read as the hook judges it with the keys in `denied` answered: the lookup it scores, the key an answer to it is remembered by, and the readings that answer could stand for.
    ///
    /// `workingDirectory` is the line's `cwd`, which reaches the advisors and the index only where the line is inside a `--since` window, as everywhere else in the scan.
    private static func shellReading(
        of command: String,
        denied: Set<String>,
        holdsSource: ((String) -> Bool)?,
        in workingDirectory: String?,
        probes: SymbolProbes,
        consultFilesystem: Bool
    ) -> LetThroughFallback {
        let directory = consultFilesystem ? workingDirectory : nil
        let keys = ShellAdvice.lookupKeys(for: command, holdsSource: holdsSource)
        let sanctioned = keys.count > 1 ? Set(keys.filter(denied.contains)) : []
        let suggestion = ShellAdvice.suggestion(
            for: command,
            holdsSource: holdsSource,
            directory: directory,
            memberExists: { probes.memberExists($0, $1, directory) },
            skipping: sanctioned
        )
        // Remembered by the reading stage alone — pattern, flags and paths — because that is what the
        // hook allows the re-run on (`PreToolUseCommand.classified`). Keyed on the whole line instead,
        // a retry that changed only what rides beside the grep — the `echo` label a session prints
        // between steps, an unrelated leg of a `&&` — would find no refusal to match, and the escape
        // hatch the hook had just granted would be scored as defiance, which is the one thing the
        // ledger is built not to do. The whole command remains the fallback for a line no reading
        // stage could be drawn from, which is what it always was.
        let key = ShellAdvice.lookupKey(for: command, holdsSource: holdsSource, skipping: sanctioned)
            ?? AdviceLedger.key(forShell: command)
        // The readings the hook could answer this line as, drawn as the hook draws them and against the directory
        // it had, so the result side can remember an answer under the lookups it served
        // (``TranscriptScanState/hookDenied``) and not `key` alone.
        let match = ServedReading.match(forShell: command, in: workingDirectory, holdsSource: holdsSource, skipping: sanctioned)
        let readings = ServedReading.readings(of: match) { ShellAdvice.lookupKey(for: $0, holdsSource: holdsSource) }
        let lookup = WithholdingLookup.lookup(
            key: key,
            suggestion: suggestion,
            search: ShellAdvice.textSearch(command, holdsSource: holdsSource, cwd: directory, skipping: sanctioned),
            denied: denied,
            couldAnswerHere: { probes.couldAnswer($0, directory) },
            consultFilesystem: consultFilesystem
        ) ?? WithholdingLookup.namedFiles(of: command, unanswered: match == nil, holdsSource: holdsSource, skipping: sanctioned)
            ?? .cold(file: nil, missed: suggestion.flatMap(MissedCall.init))
        return LetThroughFallback(lookup: lookup, key: key, readings: readings, assumedAnswered: [:])
    }

    /// The sweep a partial answer's caveat promised, where this lookup is it: `lookup` scored the identical re-run of a search the ledger already allowed (``WithholdingLookup``), and `key` was left waiting on exactly that re-run by a caveat naming what it did not cover (``TranscriptScanState/partialAnswered``).
    ///
    /// Consumes the wait it answers — a further identical run past this one is still the sanctioned escape hatch, but it swept nothing a second time.
    private static func sweepEvent(for lookup: SwiftLookup, key: String, in state: inout TranscriptScanState) -> TranscriptEvent? {
        guard case .withheldOnWorth(rule: .retryAllowed) = lookup, state.partialAnswered.remove(key) != nil else { return nil }
        return .partialAnswerSwept
    }

    /// What the advice hook remembers a `Grep`/`Glob` by — the arguments that decide the answer, so the retry is recognised however the tool orders or defaults the rest.
    ///
    /// The one place this can disagree with the hook is a search straddling a `--since` boundary, where the earlier line's `cwd` is withheld and the later line's is not, so the two keys differ and the re-run is scored cold. That is the direction the count is allowed to be wrong in. It is peculiar to search tools: a `Bash` key is the command text alone (`AdviceLedger.key`), which carries no directory and so carries across the boundary unchanged.
    private static func searchKey(tool: String, input: [String: Any], directory: String?) -> String {
        let pattern = input["pattern"] as? String ?? ""
        let path = input["path"] as? String ?? directory ?? ""
        return AdviceLedger.key(for: "\(tool) \(pattern) \(path)")
    }
}
