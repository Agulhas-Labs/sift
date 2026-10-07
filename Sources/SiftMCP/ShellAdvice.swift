//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The sift call that would have answered a shell lookup of Swift source.
///
/// `ShellInspection` decides *whether* a command went around the index; this decides *what to say instead*. They stay separate on purpose: the first is a measurement the audit depends on, where a wrong answer skews a number that exists to be trusted, and this is advice handed to a model mid-task, where a wrong answer costs one call.
///
/// What they must never do is disagree, which is why both read the segment through the same `ShellQuery` and reach the same `IndexSuggestion.forLookup`. A command classified as a miss by one and not understood by the other is a nudge that never arrives.
///
/// **Withholding a suggestion is not this type's job.** Returning `nil` here for a search the index could not have served would silence the hook and leave the metric counting the command as a lookup the index lost — a number moving in the pessimistic direction for exactly the searches the tool had just judged unanswerable. What a search *is* is ``TextSearch``, asked here in ``textSearchReason(_:holdsSource:cwd:)`` and by the scan through the same predicate; what to *do* about one belongs at the seam that already withholds `AdvisableName`'s cases and logs each withholding (`PreToolUseCommand.lookup`).
public struct ShellAdvice {
    /// The suggestion for `command`, or `nil` when it is not a Swift lookup at all.
    ///
    /// A suggestion is always produced for a lookup, even when nothing specific can be extracted: the miss happened either way, and the generic form still names the tool. Repetition is not this type's problem — `AdviceLedger` deduplicates, and a generic suggestion collides with itself, so it is offered once per session.
    public static func suggestion(for command: String, in directory: String? = nil) -> IndexSuggestion? {
        suggestion(for: command, holdsSource: SwiftTree.probe(relativeTo: directory), directory: directory)
    }

    /// The same, against a probe the caller already holds.
    ///
    /// `directory` is what a member-path offer is checked against — `AdvisableName.couldAnswer(member:of:from:)` — so a suggestion never names a member the index does not hold; `nil` (the default every existing caller gets) leaves that check unable to fail, exactly as it always has.
    ///
    /// `memberExists` is injectable for the same reason `holdsSource` is: a caller sweeping many transcripts can hand in one memo for the whole pass rather than paying an index open per member offer. `nil`, the default every existing caller gets, asks `AdvisableName` fresh, exactly as it always has.
    ///
    /// `sanctioned` holds the keys of lookups the ledger has already allowed a re-run of; the suggestion is drawn from the first lookup on the line whose key is not among them (``lookupKey(for:holdsSource:skipping:)``). Empty, the default, is the first lookup, as it always was.
    ///
    /// `belowFloor` is the same judgement `ReadAdvice` already makes for the `Read` tool, injected here so a test can pin it without writing files of a particular length — a `cat`/`less`/`head` of a whole file is the same read `Read` would have made, and disagreeing with `ReadAdvice` about the same file would mean the digest a refusal offers costs more than the read it interrupted.
    public static func suggestion(
        for command: String,
        holdsSource: ((String) -> Bool)?,
        directory: String? = nil,
        memberExists: ((String, String) -> Bool)? = nil,
        belowFloor: (String) -> Bool = DigestFloor.wouldServeSource,
        skipping sanctioned: Set<String> = []
    ) -> IndexSuggestion? {
        // A command already reaching for sift needs no teaching, whatever rides alongside it —
        // `sift digest X | head -5; grep -rn Y Sources` mixes the tools deliberately, and denying
        // it advises sift to someone using sift. The measurement is deliberately untouched:
        // the grep half still went around the index, exactly like an advised command re-run.
        guard !ShellInspection.invokesSift(command) else {
            return nil
        }
        guard ShellInspection.isSwiftLookup(command, holdsSource: holdsSource),
              let pipeline = lookupPipeline(of: command, holdsSource: holdsSource, skipping: sanctioned)
        else {
            return nil
        }

        // A windowed read is advised as the read of its one file, whichever tool spells it and whichever stage
        // of the pipeline cuts the window (`cat View.swift | head -80`): it falls through to the plain-read offer
        // below, the file's digest. Whether something already located the file is the hook's question, not this
        // one's, since only the hook knows what this context has been handed.
        let memberExists = memberExists ?? { AdvisableName.couldAnswer(member: $0, of: $1, from: directory) }
        /// Whether `path`, resolved against `directory`, is below `DigestFloor`'s own compression floor.
        ///
        /// `belowFloor` reads bytes off disk, and the command names paths relative to where it ran, not to this process's own working directory, so the path is resolved first.
        ///
        /// A path that cannot be resolved — no `directory` to resolve a relative one against — is left `false` rather than guessed at: the conservative direction is to offer the call, as `DigestFloor` itself rounds when a file cannot be read at all.
        func fileBelowFloor(_ path: String) -> Bool {
            guard let resolved = SwiftTree.resolve(path, relativeTo: directory) else { return false }
            return belowFloor(resolved)
        }
        let query = pipeline.query
        guard let file = pipeline.file else {
            if query.searches {
                return .forSweep(pattern: query.appliedPattern, memberExists: memberExists)
            }
            // A read of several files is several reads: one digest per file named, or the module a glob reads.
            // Below the floor a digest would have served the source anyway, so that file draws no nudge; only
            // where every named file is below it is there nothing left worth interrupting.
            if query.swiftFiles.count > 1 {
                let aboveFloor = query.swiftFiles.filter { !fileBelowFloor($0) }
                guard !aboveFloor.isEmpty else { return nil }
                return .forFiles(aboveFloor)
            }
            if let glob = query.swiftGlobs.first {
                return .forGlob(glob)
            }
            return .forLookup(symbol: nil, file: nil)
        }
        guard query.searches else {
            guard !fileBelowFloor(file) else { return nil }
            return .forLookup(symbol: nil, file: file)
        }
        return .forSearch(pattern: query.appliedPattern, symbol: query.symbol, file: file, memberExists: memberExists)
    }

    /// The key a re-run of `command` is recognised by: the reading stage alone — pattern, flags and paths — rather than the whole line, so a retry that changes only what rides beside the grep (an `echo` label, an unrelated leg of a `&&`) is still the same ask.
    ///
    /// A reading stage that carries no pattern of its own — the `cat` of `cat A.swift | grep -n isProse` — is keyed together with every stage of its pipeline that does, so two patterns down one `cat` are two asks rather than one allowance for whatever the `cat` feeds. A stage with a pattern of its own is keyed alone, exactly as before, so the key only ever gets finer and an identical re-run is always the same key.
    ///
    /// **A line of several lookups is keyed on the first one the ledger has not already allowed** (`sanctioned`), so `grep -n Bar B.swift` riding behind a re-run of an allowed `grep -n Foo A.swift` is its own ask rather than an allowance inherited from the grep in front of it. Where nothing is left, the key is the first lookup's, which the ledger allows. Empty `sanctioned`, the default, is the first lookup, as it always was.
    ///
    /// `nil` where `command` is not a lookup at all, in which case the caller falls back to keying on the whole command as it always has.
    public static func lookupKey(for command: String, holdsSource: ((String) -> Bool)?, skipping sanctioned: Set<String> = []) -> String? {
        guard !ShellInspection.invokesSift(command),
              ShellInspection.isSwiftLookup(command, holdsSource: holdsSource),
              let pipeline = lookupPipeline(of: command, holdsSource: holdsSource, skipping: sanctioned)
        else {
            return nil
        }
        return pipeline.key
    }

    /// The key of every lookup on `command`, in the order the one the advice is about is chosen from — what a caller asks the ledger about before it asks for that one (``lookupKey(for:holdsSource:skipping:)``).
    ///
    /// Empty where `command` is not a lookup at all.
    public static func lookupKeys(for command: String, holdsSource: ((String) -> Bool)?) -> [String] {
        guard !ShellInspection.invokesSift(command), ShellInspection.isSwiftLookup(command, holdsSource: holdsSource) else {
            return []
        }
        return lookupPipelines(of: command, holdsSource: holdsSource).map(\.key)
    }

    /// Whether the lookup the advice on `command` is a search for names — every pattern one, none inverted — whose operands are several Swift files or a glob of them (``InPlaceShape/namesOnlySwiftFiles(_:)``), which the hook answers about those files or lets run, never with a `where` of the whole tree.
    ///
    /// Holds for a member grep the hook does answer as well, so a caller asks it only of a line the hook declined.
    static func searchesNamedSwiftFiles(_ command: String, holdsSource: ((String) -> Bool)?, skipping sanctioned: Set<String> = []) -> Bool {
        // One file named is left out: its offer is that file's own digest, scoped to what the search named.
        guard let pipeline = lookupPipeline(of: command, holdsSource: holdsSource, skipping: sanctioned), pipeline.file == nil,
              pipeline.query.searches, !pipeline.query.invertsMatch,
              !pipeline.query.patterns.isEmpty, pipeline.query.patterns.allSatisfy(IndexSuggestion.isName)
        else {
            return false
        }
        let paths = pipeline.query.operandPaths
        return !paths.isEmpty && InPlaceShape.namesOnlySwiftFiles(paths)
    }

    /// The path `command`'s reading stage is pointed at, or `nil` where it names none of its own — the file a single-file read or search names, or the first bare operand of a sweep.
    ///
    /// What roots the offer on the tree a search actually names rather than on wherever the session's shell happens to be standing (``SiftCLI/PreToolUseCommand/Lookup/anchor``).
    public static func namedPath(for command: String, holdsSource: ((String) -> Bool)?, skipping sanctioned: Set<String> = []) -> String? {
        guard !ShellInspection.invokesSift(command), let pipeline = lookupPipeline(of: command, holdsSource: holdsSource, skipping: sanctioned) else {
            return nil
        }
        return pipeline.file ?? pipeline.query.operandPaths.first
    }

    /// Whether the lookup the advice on `command` is about reads its one Swift file through a line window (the pipeline reading of a window ``ShellQuery`` holds) rather than whole or by a search.
    ///
    /// What the hook asks to tell a window of a file this context has already located, which is the loop working and let through as no lookup at all, from a whole read of a digested file, which is let through but still counted.
    public static func readsThroughAWindow(_ command: String, holdsSource: ((String) -> Bool)?, skipping sanctioned: Set<String> = []) -> Bool {
        guard let pipeline = lookupPipeline(of: command, holdsSource: holdsSource, skipping: sanctioned) else { return false }
        return ShellQuery.windowedReadPath(of: pipeline.stages, readBy: pipeline.reader) != nil
    }

    /// The Swift file each lookup on `command` reads through a line window, in command order, or none where any lookup on it is not such a window.
    ///
    /// What the hook asks of a line no answered shape covers — a window in a subshell, behind an environment assignment, sent to `/dev/null` — to tell whether every file it reads is one this context has already located, which makes the whole line no lookup. A relative path on a line that moves to another directory first is spelled out against the directory each literal `cd` before it moves to from `cwd`, a directory that is there on disk; where a move cannot be followed by the rule ``InPlaceShape`` keeps for a line's statements it names a file this cannot place, so such a line has none.
    public static func windowedReadPaths(_ command: String, holdsSource: ((String) -> Bool)?, cwd: String? = nil) -> [String] {
        let pipelines = lookupPipelines(of: command, holdsSource: holdsSource)
        let paths = pipelines.compactMap { ShellQuery.windowedReadPath(of: $0.stages, readBy: $0.reader) }
        guard paths.count == pipelines.count else { return [] }
        // A working directory that is itself a symbolic link places a climbing operand where the link points, as it does for the in-place match, so it is followed with no `cd` on the line too.
        let linked = cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path != $0 } ?? false
        guard TranscriptScan.changesDirectory(command) || linked, paths.contains(where: { !$0.hasPrefix("/") }) else { return paths }
        guard let directories = lookupDirectories(of: command, holdsSource: holdsSource, cwd: cwd, requiringDirectories: true) else { return [] }
        let placed = zip(paths, directories).compactMap { InPlaceShape.resolve($0, against: $1) }
        return placed.count == paths.count ? placed : []
    }

    /// The directory each lookup on `command` runs in, in the order ``lookupKeys(for:holdsSource:)`` lists them, once each literal `cd` before it has moved from `cwd` — or `nil` where a move on the line cannot be followed by the rule ``InPlaceShape`` keeps for a line's statements.
    ///
    /// Where the hook and the scan both place a relative path read behind a `cd`, so the two spell out the same file for the same line.
    static func lookupDirectories(of command: String, holdsSource: ((String) -> Bool)?, cwd: String?, requiringDirectories: Bool) -> [String?]? {
        guard let statements = InPlaceShape.statementDirectories(of: command, from: cwd, requiringDirectories: requiringDirectories) else { return nil }
        let directories = statements.flatMap { placed in
            lookupPipelines(of: placed.statement, holdsSource: holdsSource).map { _ in placed.directory }
        }
        return directories.count == lookupPipelines(of: command, holdsSource: holdsSource).count ? directories : nil
    }

    /// Which rule of ``TextSearch`` declares `command` a search the index could not have served, or `nil` where none does — the name the hook logs its withholding under, where the scan needs only that there is one.
    ///
    /// A plain read takes no pattern, so only the rules about what it is pointed at reach it: `cat View.swift` is the shape `digest` exists to replace, and a `cat` of a file under `.build/checkouts` a file no digest can serve. A search is judged on every pattern it applies (`ShellQuery.patterns`), and on whether it is confined to one file — which decides whether prose in it is one file's, which that file's digest does not record, or a sweep's, which ``SweepPattern`` reads for the names beside it.
    ///
    /// `cwd` is the call's own working directory, passed on to ``SwiftTree/isOutsideIndexedSources(_:)`` so an absolute path inside a repository that merely sits under a directory named `checkouts` or `Pods` is not read as outside it.
    public static func textSearchReason(
        _ command: String,
        holdsSource: ((String) -> Bool)?,
        cwd: String? = nil,
        skipping sanctioned: Set<String> = []
    ) -> TextSearch.Reason? {
        textSearch(command, holdsSource: holdsSource, cwd: cwd, skipping: sanctioned).flatMap(TextSearch.reason(for:))
    }

    /// The search ``textSearchReason(_:holdsSource:cwd:skipping:)`` judges, read off `command`'s lookup pipeline, or `nil` where `command` is no Swift lookup — for the audit, which asks one more question of it than the hook does (``TextSearch/namesNothingInOneFile(_:)``).
    static func textSearch(
        _ command: String,
        holdsSource: ((String) -> Bool)?,
        cwd: String? = nil,
        skipping sanctioned: Set<String> = []
    ) -> TextSearch.Search? {
        guard ShellInspection.isSwiftLookup(command, holdsSource: holdsSource),
              let pipeline = lookupPipeline(of: command, holdsSource: holdsSource, skipping: sanctioned)
        else {
            return nil
        }
        let query = pipeline.query
        let paths = query.operandPaths
        return TextSearch.Search(
            counting: pipeline.counts,
            file: pipeline.file,
            patterns: query.searches ? query.patterns : nil,
            fixedStrings: query.usesFixedStrings,
            outsideIndexedSources: !paths.isEmpty && paths.allSatisfy { SwiftTree.isOutsideIndexedSources($0, relativeTo: cwd) },
            printsContext: query.printsContext,
            confinedToNamedFiles: pipeline.confinedToNamedFiles,
            outputIsFiltered: pipeline.outputIsFiltered,
            inverted: query.invertsMatch,
            listsFiles: query.listsFiles
        )
    }

    /// The pipeline whose reading stage inspects Swift source: its stages, that stage, and the one file it is pointed at — the first on the line whose key is not in `sanctioned`, or the first of all where there is none.
    ///
    /// The same segmenting as `ShellInspection`, and for the same reason: `cd X && grep … | head -30` names a file in one piece and reads in another, and advice drawn from the wrong piece is advice about `head`. Walking the statements first is what bounds the *pipeline* — every stage returned shares a pipe with the reading one, so a fact read off them is a fact about this lookup and not about whatever else the line was doing. The statements include those inside command substitutions, after every statement outside one (`ShellSyntax.hostStatementsFirst`), as `ShellInspection` takes its window: a body names the lookup only where nothing around it reads Swift.
    private static func lookupPipeline(of command: String, holdsSource: ((String) -> Bool)?, skipping sanctioned: Set<String>) -> Pipeline? {
        let pipelines = lookupPipelines(of: command, holdsSource: holdsSource)
        guard !sanctioned.isEmpty else { return pipelines.first }
        return pipelines.first { !sanctioned.contains($0.key) } ?? pipelines.first
    }

    /// Every pipeline on `command` with a stage that reads Swift, in the order ``lookupPipeline(of:holdsSource:skipping:)`` chooses from.
    private static func lookupPipelines(of command: String, holdsSource: ((String) -> Bool)?) -> [Pipeline] {
        ShellSyntax.hostStatementsFirst(of: command).compactMap { statement in
            let stages = ShellSyntax.segments(of: statement).map(ShellQuery.init)
            guard let reader = NumberedRead.reader(of: stages, holdsSource: holdsSource) else { return nil }
            return Pipeline(stages: stages, reader: reader)
        }
    }
}

private extension ShellAdvice {
    /// The pipeline a lookup was found in: its stages, the stage that reads Swift, and the one file that stage is pointed at.
    struct Pipeline {
        let stages: [ShellQuery]
        /// Where the stage that reads Swift stands among them.
        let reader: Int

        var query: ShellQuery {
            stages[reader]
        }

        /// What a re-run of this lookup is recognised by (``ShellAdvice/lookupKey(for:holdsSource:skipping:)``).
        var key: String {
            guard query.patterns.isEmpty else {
                return AdviceLedger.key(for: query.segment)
            }
            let patternBearing = stages.indices
                .filter { $0 != reader && !stages[$0].patterns.isEmpty }
                .map { stages[$0].segment }
            return AdviceLedger.key(for: ([query.segment] + patternBearing).joined(separator: " | "))
        }

        /// The single Swift file this reads, or `nil` where it sweeps.
        ///
        /// More than one file is a sweep even without `-r`, and its answer is a symbol's sites rather than a file's shape.
        var file: String? {
            let files = query.swiftFiles
            return query.isRecursive || files.count > 1 ? nil : files.first
        }

        /// Whether this is pointed at the Swift files or globs it names outright rather than walking a tree.
        ///
        /// A recursion is never that, even where it also names a `.swift` path: what it prints comes from whatever the tree holds.
        var confinedToNamedFiles: Bool {
            !query.isRecursive && !(query.swiftFiles.isEmpty && query.swiftGlobs.isEmpty)
        }

        /// Whether any stage of this pipeline asks how many rather than which.
        var counts: Bool {
            stages.contains(where: \.counts)
        }

        /// Whether any stage after the reading one filters what it printed rather than passing it on.
        ///
        /// Only the stages *after* the reader, because those are the ones standing between the read and the terminal: what comes before it feeds it, and a `cat` in front of a `grep` changes nothing about what the grep prints. What passes the lines on is ``ShellQuery/passesOnWhatItIsHanded`` — a window, a `cat`, a pager, a redirect to a file — so the rule takes only the stages that genuinely drop a line or reorder them, and never silences a lookup whose output an index answer reproduces line for line. It holds wherever ``ShellQuery/windowsWhatItIsHanded`` does, the reading the ranged-read pipeline is judged by, so the two ends of the same pipe cannot disagree about which stages are windows.
        ///
        /// **Asked of every reading stage alike** — a search, a `cat`, and a positional printer (`sed -n '/func /p'`, `awk 'NR>=10&&NR<=40'`) — because what reaches the terminal is what the filter kept, whichever of them printed the lines it kept them from: `sed -n '/func /p' View.swift | sort -u` is `grep -n 'func ' View.swift | sort -u` in another spelling, and one shape draws one reading.
        var outputIsFiltered: Bool {
            stages[(reader + 1)...].contains { !$0.passesOnWhatItIsHanded }
        }
    }
}
