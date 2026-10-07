//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// What a scan has to carry between lines to classify the next one.
///
/// Kept per transcript rather than per session, deliberately. A subagent has its own context window: the parent's digest never reached it, so a subagent's read of a file the parent digested is genuinely cold *for the subagent*, and pooling the two would score it as guided.
public struct TranscriptScanState: Sendable, Equatable {
    /// Index calls whose result has not been seen yet, by `tool_use_id`, because a tool's failure is recorded on a later line than the call and names only that id.
    ///
    /// Without this, a failed digest is indistinguishable from a failed `Bash`. Holding what each call *was* rather than only that one is outstanding is what lets a failure be reported as the thing it was — the result line carries the message and nothing else, so the tool and target are knowable only from here.
    var pendingIndexCalls: [String: PendingIndexCall] = [:]
    /// The earliest timestamp a window was judged against, so a scan made under one `--since` can tell whether another would have reported every line it did.
    var earliestStamp: Date?
    /// The targets each shell `sift digest` named, keyed by the repository each was asked of, by the `tool_use_id` of the Bash call that ran it, credited as digests once that call's result arrives without an error.
    ///
    /// Held apart from ``pendingIndexCalls`` because a Bash call's error is the whole line's, not the index's: filing it as an index failure, or retracting the lookup, would charge the tool for a `sed` or a build that failed beside it.
    var pendingShellDigests: [String: [String: Set<String>]] = [:]
    /// The directory each of those repositories' digests was answered from — its `--root`, else where the line ran — by the same `tool_use_id`, which spells a named file once that checkout is gone (``LocatedDigest/anchor``).
    var pendingShellDigestAnchors: [String: [String: String]] = [:]
    /// Where each Bash line of nothing but `sift where`/`sift search` lookups was answered from, by `tool_use_id`, until its result's text says which files they listed.
    var pendingShellAnswers: [String: ShellAnswerSource] = [:]
    /// `tool_use_id`s of Bash calls counted as an indexed lookup — `digest`/`where`/`search`/`strings` on the CLI — whose line's result has not been seen yet, taken back off the tally if it errors.
    ///
    /// Held apart from ``pendingIndexCalls`` for the reason ``pendingShellDigests`` is: the error is the whole Bash line's, which may belong to another command sharing it, so it is never filed as an index failure — only the count is taken back.
    var pendingShellLookups: Set<String> = []
    /// Swift file stems any index call but a digest has named, keyed by the canonical repository each was answered from — `""` where none could be resolved, matched only against a read whose own repository is equally unresolved.
    var located: [String: Set<String>] = [:]
    /// The digests this context received, keyed the same way as ``located``: matched by the file each resolved to rather than by stem (``LocatedDigest``), and the only calls that promised to save reading a file whole, so the only ones a whole read afterwards is counted against.
    var digests: [String: Set<LocatedDigest>] = [:]
    /// Full paths of Swift files already read — paths rather than stems, so two files sharing a basename stay distinct.
    var opened: Set<String> = []
    /// Full paths of Swift files a shell window has shown part of.
    ///
    /// Kept apart from `opened` because a window puts only its lines in context: it makes a later window or ranged read of the same file a re-read, and never a later whole read, which is the file paid for in full whatever part of it was already seen.
    var windowed: Set<String> = []

    /// What each whole-file digest this context received decided about its file's floor, in the order the answers arrived.
    ///
    /// The transcript's own record of the decision, so a later read of the file is judged on what the index actually said at the time rather than on whatever the disk holds when the scan runs — which, for an audit over a week of since-deleted worktrees, is often nothing.
    var floorVerdicts: [FloorVerdict] = []

    /// Files whose counted first touch had no digest verdict to go on and was judged against the disk instead.
    ///
    /// Kept so a report can say how much of its below-floor count rests on the disk as it stood when the scan ran, rather than on the transcript.
    var floorFromDisk: Set<String> = []

    /// Reads counted but not yet confirmed, by `tool_use_id`, so an error result can take one back.
    ///
    /// Keyed rather than kept as a single slot because one assistant turn can issue several reads at once and their results arrive together; a slot would retract only the last of them. Entries for reads that succeeded are cleared when their result line is parsed and otherwise linger, exactly as `pendingIndexCalls` does — a result line only reaches the scanner if it passes the byte pre-filter, and widening that filter to catch every result would mean JSON-parsing the file contents that dominate a transcript.
    var pendingReads: [String: PendingRead] = [:]

    /// Searches this context has already been refused by the advice hook, by the key the hook remembers them under.
    ///
    /// Never cleared, mirroring the ledger's own `denied`: no command is refused twice in a session, so every later run of one of these was allowed by the hook rather than merely tolerated by it. The scan cannot read the ledger — it is keyed on a session id the transcript does not carry into a subagent, and an audit runs over transcripts whose ledgers have long since aged out — so the refusal is recovered from the transcript itself, where it is written down as the result of the call it denied.
    var hookDenied: Set<String> = []

    /// Search keys a partial in-place answer's caveat is still waiting on the identical re-run for, a subset of `hookDenied`.
    ///
    /// Cleared on the key its own re-run arrives at — unlike `hookDenied`, which stays set for the ledger's sake — so a second identical run past that one is still the sanctioned escape hatch without being counted as a second sweep of the same caveat.
    var partialAnswered: Set<String> = []

    /// Whether this context's transcript records the harness reporting this server as failed — it did not start, or dropped its connection.
    ///
    /// Never evidence for `couldNotReachTheIndex` on its own: a server that fails can be reconnected, and the verdict rests on the tool list instead (``recordedToolListWithoutIndex``). This says *why*.
    ///
    /// Not a count and not windowed: it is a fact about the context's access, read by the report that has to say *why* a context could not reach the index, and a server that failed before a window opened is still the reason inside it.
    var serverFailed = false

    /// Whether this context's transcript ever recorded an `mcp__sift__*` tool as callable — named in a `prompt_snapshot`'s tool list, or added by a `deferred_tools_delta` — the harness's own record of what this context could call, independent of whether it ever did.
    ///
    /// A context can go on to lose the tools (``serverFailed``) or never touch them at all, and this stays `true` either way: it answers "did this context ever hold sift's MCP tools", not "does it hold them now". Read for the refusals report's `where` breakdown (main context, a subagent holding the tools, a subagent that never did), and — only through ``recordedToolListWithoutIndex``, beside a proof that the list was recorded whole — for `couldNotReachTheIndex`. Its `false` on its own proves nothing: a transcript that records no tool list at all is `false` too.
    var heldIndexTools = false

    /// Whether this context's transcript recorded the tools sent in full with every request: a `prompt_snapshot` carrying a `tools` list, whatever it names.
    var listedTools = false

    /// Whether any tool list it recorded named the tool-search tool, which the harness offers only when some tools are held back and loaded on demand — so the full list alone is not the whole list.
    var offeredDeferredTools = false

    /// Whether it recorded a `deferred_tools_delta`: the harness's list of the tools it held back, which is where this server's tools usually appear.
    var listedDeferredTools = false

    /// Whether this transcript records the `SessionStart` hook failing because the shell could not find the sift binary to run — exit status 127 on a `session-start` registration.
    ///
    /// Only the session's own context can hold this line, and it is the one record that says *why* that session's server was never there: a binary missing when the session started is missing for the server launched beside the hook as well.
    var binaryMissingAtStart = false

    /// Whether the transcript demonstrably records this context's whole tool list: the full list, plus the held-back list wherever the full one offered a tool search to load them.
    ///
    /// A snapshot that offers no tool search is the whole list by itself — nothing is held back to be listed anywhere else. One that offers it is only half, and the other half is the delta. Anything less — no snapshot with a tool list, which is what an older harness writes, or a snapshot offering a search with no delta — is a transcript that has not said, and silence is never read as absence.
    var recordsWholeToolList: Bool {
        listedTools && (!offeredDeferredTools || listedDeferredTools)
    }

    /// Whether the transcript records this context's whole tool list and not one of this server's tools is in it — direct evidence that the context held nothing the advice named.
    var recordedToolListWithoutIndex: Bool {
        recordsWholeToolList && !heldIndexTools
    }

    /// The assistant turn the latest assistant line belonged to — its `message.id`, which every block of one turn shares, each written on a line of its own.
    var turn: String?

    /// How many tool calls that turn has carried so far, whatever tool each was for.
    ///
    /// Whether a refusal was alone in its turn is decided from this when the next turn begins, because only then have all of its calls been written.
    var turnToolUses = 0

    /// The turns in which a refusal was given, each with the shape of the call it refused, waiting for the turn after to say what the round trip re-sent.
    var awaitingRoundTrip: [PendingRoundTrip] = []

    /// Refusals already priced, each waiting for the next tool call the transcript writes — anywhere later, not necessarily in the round trip's own turn — to say what followed it.
    ///
    /// A FIFO queue rather than a single slot: two solo refusals can both be waiting before anything follows either of them, and the next tool call to appear resolves only the oldest.
    var awaitingFollowUp: [PendingFollowUp] = []

    /// How many tool calls this context has made, whatever each was for — the clock an answer's follow-up is measured on.
    var toolCalls = 0

    /// Calls that read files, awaiting their results, by `tool_use_id` (``AnswerThenRead``).
    var readingCalls: [String: OpenAnswer] = [:]

    /// In-place answers to reads still inside the span a whole read of their file makes them a miss (``AnswerThenRead``).
    var openAnswers: [OpenAnswer] = []

    /// Every window this context's scan scored, by its call, where the scan was asked to keep them (`sift scan-dump`), and `nil` otherwise, so a scan that was not asked for them neither carries nor needs one.
    public var windowLog: ScanWindowLog?

    public init() {}
}

extension TranscriptScanState {
    /// Whether a call this scan counted is still waiting on a later line: its result, the turn that prices its refusal, or the next call that says what followed it.
    ///
    /// While it is, a line past `--until` can still change a count, so a replay reads on; once it is not, nothing later can.
    var awaitsCountedCall: Bool {
        pendingIndexCalls.values.contains(where: \.counted) || pendingReads.values.contains(where: \.counted)
            || !pendingShellLookups.isEmpty || !awaitingRoundTrip.isEmpty || !awaitingFollowUp.isEmpty
    }

    /// The verdict a whole-file digest in this context gave the file a read names, if one did — the latest, where several did.
    ///
    /// Matched on the whole absolute path, never on a suffix alone, because a suffix match would take a digest of `Sources/App/Model.swift` in one repository as the verdict on the same relative path in another, and a repository's root file as the verdict on every file of its name anywhere. A read no verdict decides is left to the disk.
    func floorVerdict(forRead path: String) -> Bool? {
        guard path.hasPrefix("/") else { return nil }
        let read = URL(fileURLWithPath: path).standardizedFileURL.path
        return floorVerdicts.last { $0.decides(read) }?.servedSource
    }

    /// Records what a whole-file digest's answer decided — made from `anchor`, answered by the `tree` its header names, from the repository it says it `adopted` where it says one — replacing an earlier verdict on the same file from the same place; nothing where the answer's path cannot be placed.
    mutating func recordFloorVerdict(_ verdict: SourcePassthrough.FileVerdict, anchor: String?, adopted: String?, tree: WorkingTree?) {
        guard let recorded = FloorVerdict(verdict, anchor: anchor, adopted: adopted, tree: tree) else { return }
        floorVerdicts.removeAll {
            $0.anchor == recorded.anchor && $0.adopted == recorded.adopted && $0.tree == recorded.tree && $0.path == recorded.path
        }
        floorVerdicts.append(recorded)
    }
}

extension TranscriptScanState {
    /// Whether this context has located the file at `path`, read in the repository `root`: an answer other than a digest named its stem, or a digest resolved to it.
    func locates(_ path: String, in root: String) -> Bool {
        located[root]?.contains(TranscriptScan.stem(ofPath: path)) == true
            || digests[root]?.contains { $0.covers(path, in: root, whole: false) } == true
    }

    /// Whether a window of the file at `path`, read in the repository `root`, is the loop working: the file is located, and a `wide` window (more than ``ListedWindow/widestExcused`` printed lines) only where its whole digest was served, the width rule the advice hook holds the same window to.
    func guides(_ path: String, in root: String, wide: Bool) -> Bool {
        locates(path, in: root) && (!wide || digestedWhole(path, in: root))
    }

    /// Whether this context has had the whole digest of the file at `path`, read in the repository `root`.
    func digestedWhole(_ path: String, in root: String) -> Bool {
        digests[root]?.contains { $0.covers(path, in: root, whole: true) } == true
    }

    /// Holds the targets each `sift digest` in a Bash command names, keyed by the repository each was asked of, until the line's result says whether it came back.
    ///
    /// A shell digest locates what it names exactly as the MCP one does: the advice hook records the same targets as digests this context holds (`PreToolUseCommand.digestsAsked`) and lets a later window of the file through as the loop working, so crediting nothing here scored as cold the one read the hook calls no lookup at all. Keyed by root through the reading the ledger keys it by (``IndexCallTarget``), statement by statement behind each literal `cd`, so a `--root` or a move into another repository never credits this one's file, and a digest whose directory a move leaves unknown credits nothing.
    mutating func holdShellDigests(of command: String, block: [String: Any], directory: String?) {
        var named: [String: Set<String>] = [:]
        var anchors: [String: String] = [:]
        // A digest behind a `cd` into another checkout asks that one, and its answer names files relative to it;
        // keyed as a read of one of them is, by its own repository where that is still there, else by this line's.
        for (runsIn, asked) in IndexCallTarget.cliDigests(inCommand: command, from: directory) {
            let resolved = asked.root.flatMap { SwiftTree.resolve($0, relativeTo: runsIn) }
            let movedRoot = runsIn == directory ? nil : runsIn.flatMap { CallerRoot.root(forCallerIn: $0) }
            let root = resolved.map { CallerRoot.root(forCallerIn: $0) ?? $0 } ?? movedRoot ?? TranscriptScan.locatingRoot(directory)
            named[root, default: []].insert(asked.target)
            anchors[root] = resolved ?? runsIn
        }
        if !named.isEmpty, let id = block["id"] as? String {
            pendingShellDigests[id] = named
            pendingShellDigestAnchors[id] = anchors
        }
    }

    /// The directory the hook's in-place answer to a Bash line was read from (``PendingRead/answeredFrom``): where the literal `cd`s in front of its lookups move, every one of them followed as the ledger's reading of a shell digest follows them (``IndexCallTarget``), else the line's own where it moves nowhere.
    ///
    /// Only the list in front of the line's first `||` is read, as the hook places its answer: the lookup it answered is there, and the fallback after it never ran. `nil` — no directory at all — where a move in that list cannot be followed (a subshell, `pushd`, `cd -`, a substitution, a pipe the move is in) or its lookups run in more than one directory: anchoring the answer at the line's own directory would credit a file of a repository the line had left, and an answer left unlocated costs one answered read, never a wrong suppression.
    static func digestDirectory(of command: String, from directory: String?) -> String? {
        guard command.contains(IndexCallTarget.movesAnywhere) else { return directory }
        let statements = ShellSyntax.statementRanges(of: command)
        let head = InPlaceShape.joints(of: command, between: statements).firstIndex(of: "||").map { String(command[..<statements[$0].range.upperBound]) } ?? command
        guard let placed = InPlaceShape.statementDirectories(of: head, from: directory, requiringDirectories: false) else { return nil }
        // A `cd` only quoted or written as a word of another command moves nothing.
        guard ShellSyntax.statementRanges(of: head).contains(where: { TranscriptScan.changesDirectory($0.statement) }) else { return directory }
        let lookups = ShellAdvice.lookupDirectories(of: head, holdsSource: nil, cwd: directory, requiringDirectories: false) ?? []
        let candidates: [String?] = lookups.isEmpty ? placed.compactMap(\.directory) : lookups
        let directories = Set(candidates)
        guard directories.count == 1, let only = directories.first else { return nil }
        return only
    }

    /// Credits what the shell digests of the Bash call `id` named as digests, each by the file the line's output named for it, unless its line came back with an error.
    ///
    /// Only an answer locates anything, as for an MCP call; but the error is the whole line's, so nothing is retracted or filed as the index failing. The output may hold another command's lines too, so it only settles which file a target resolved to, and credits no file of its own beyond those a module digest lists under its headings.
    mutating func creditShellDigests(answering id: String, block: [String: Any], failed: Bool) {
        let anchors = pendingShellDigestAnchors.removeValue(forKey: id) ?? [:]
        guard let named = pendingShellDigests.removeValue(forKey: id), !failed else { return }
        let output = TranscriptScan.answerText(of: block).joined(separator: "\n")
        for (root, targets) in named {
            digests[root, default: []].formUnion(LocatedDigest.credited(targets: Array(targets), whole: true, answer: output, anchor: anchors[root]))
        }
    }

    /// Holds where a Bash line of nothing but `sift where`/`sift search` lookups was answered from (``ShellAnswerSource``), until its result's text says which files they listed.
    mutating func holdShellAnswer(of command: String, block: [String: Any], directory: String?) {
        if let source = ShellAnswerSource.of(command: command, cwd: directory), let id = block["id"] as? String {
            pendingShellAnswers[id] = source
        }
    }

    /// Credits the files the held Bash line `id` listed in its output as located, unless its line came back with an error.
    ///
    /// The advice hook lets a later window of one of them through as the loop working, from the CLI's usage-log line (`located`) live and from this same output in the replay, so crediting nothing here scored as cold a read the hook calls no lookup at all. Read by the same parsers and under the same conditions as the replay reads it.
    mutating func creditShellAnswer(answering id: String, block: [String: Any], failed: Bool) {
        guard let source = pendingShellAnswers.removeValue(forKey: id), !failed else { return }
        let listed = source.locatedFiles(inOutput: TranscriptScan.answerText(of: block).joined(separator: "\n"))
        located[source.root, default: []].formUnion(listed.map(TranscriptScan.stem(ofPath:)))
    }
}
