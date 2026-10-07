//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Runs the call an answered shape maps to (``InPlaceShape``), inside the hook and without the MCP server, under the hook's time and size budgets (``InPlaceAnswer``) — and gives the answer only where it is proven exact.
///
/// **Exactness is proven, never assumed.** Where the lookup was a grep, the grep is run in-process over the same files (``ShellGrep``) and the answer is given only if every line it would print falls inside a line range the answer serves as source, or on a line the answer names by its own number (``SiftCore/ExactAnswer``). A whole read of a Swift file is answered only where the file is there at exactly the path named and the digest resolved to that same file. A whole read of a Markdown document is the one read that rests on no proof, because there is none to build — nothing about a `.md` file is indexed — so it is the offer's own answer handed over, read live from disk at exactly the path named (``InPlaceShape``). Anything short of that — a line the answer does not account for, a search that cannot be reproduced exactly — leaves the refusal standing.
///
/// It needs nothing but the binary and the index on disk: the MCP face can drop out of a session while the CLI goes on answering, and this answers through the same engine the CLI opens.
///
/// **Every doubt resolves to the refusal.** No repository behind the call, operands in another repository than the answer's, a shape still inside its back-off there, a sweep in a repository with no index store, an answer that is not exactly the one asked for, a search that cannot be reproduced, a failure, a run past the time budget, a refusal past the size budget: each returns a withholding, and the hook refuses as it always has, naming the call.
///
/// **A repository with no index is indexed on the way, and the time budget is what bounds that.** It used to be a withholding of its own, on the premise that building from nothing inside a hook was out of the question; measured, it costs tenths of a second even for the largest repository on this machine, and the rule cost the hook its voice in every tree an isolated agent works in (`Docs/Design.md`). So the engine is opened and brought up to date whatever is on disk, and a build that runs long is abandoned at the budget exactly as a slow query is — the back-off then holds that shape off in that repository for the window, and the command goes through as it would have without the hook.
///
/// **The cheap checks run first, and the engine opens last.** Opening it and bringing the index up to date is most of what an answer costs, so everything that can refuse without it does so before it: the back-off, then — for a sweep — whether there is an index store at all, then the command's own search, which is stopped as soon as what it prints could not fit in an answer. A refusal decided by any of those costs a file probe or a search, never the engine.
public struct InPlaceAnswerer {
    /// Answers every lookup `match` found: its one call as ``answer(_:from:serverGone:wholeCommand:timeBudget:sizeBudget:backoff:fallbackFollows:oversized:)`` answers it, or several calls together — whole reads, or a compound line's lookups with its literals printed where they fall — in one answer or not at all.
    public static func answer(
        _ match: InPlaceShape.Match,
        serverGone: Bool = false,
        timeBudget: TimeInterval = InPlaceAnswer.timeBudget, deadline: InPlaceDeadline = .wallClock,
        sizeBudget: Int = InPlaceAnswer.sizeBudget,
        backoff: InPlaceBackoff = .standard(),
        oversized: (@Sendable (Int) -> Void)? = nil
    ) -> Outcome {
        // An answer to part of a line whose other statements print what it leaves out saves one statement's
        // output and costs a re-run of the whole line, so the line runs.
        guard !match.runsOtherStatements else { return .withheld(.otherStatementsRun) }
        guard !OperandFile.windowsAConflict(match) else { return .withheld(.conflicted) }
        guard match.calls.count > 1 || !match.literals.isEmpty else {
            // A read exits 0 exactly where its file is there to read, so behind a fallback that could print the
            // file is asked for first: where it is not, the fallback ran and no answer speaks for its output.
            if match.fallbackFollows, let path = match.call.readPath, OperandFile.readable(path, in: match.directory) == nil {
                return .withheld(.notExact)
            }
            return answer(
                match.call,
                from: match.directory,
                serverGone: serverGone,
                wholeCommand: match.isWholeCommand,
                timeBudget: timeBudget,
                deadline: deadline,
                sizeBudget: sizeBudget,
                backoff: backoff,
                fallbackFollows: match.fallbackFollows,
                oversized: oversized
            )
        }
        let conditions = Conditions(
            directory: match.directory,
            serverGone: serverGone,
            wholeCommand: match.isWholeCommand,
            lookups: match.calls.count,
            sizeBudget: sizeBudget,
            backoff: backoff,
            oversized: oversized
        )
        return attempt(several: match.calls, literals: match.literals, under: conditions, timeBudget: timeBudget, deadline: deadline)
    }

    /// The first reading of `match` that `answer` answers, and the reading its outcome is for: the match itself, then — for a compound line whose own answer is withheld — the line as it was always read (``InPlaceShape/Match/ordinary``), whose outcome stands where there is one.
    ///
    /// **Both readings share the one `timeBudget`.** `answer` is handed the time it may take: the whole budget for the match, and what the match left of it for the ordinary reading, so the two together never keep the caller past the budget it gave. Where the match used the budget up, its withholding stands and the ordinary reading is not asked.
    ///
    /// **The ordinary reading's own `otherStatementsRun` never stands in for the match's withholding.** A real compound's ordinary reading almost always leaves a second lookup unaccounted (``InPlaceShape/Match/runsOtherStatements``), so asking the real answerer withholds it under `.otherStatementsRun` before it looks at anything else (``answer(_:serverGone:timeBudget:sizeBudget:backoff:oversized:)``) — a rule that says nothing about why the match itself failed, and would otherwise replace `.failed`, `.overSize`, `.conflicted` or any other real reason in the log. Where the ordinary reading answers that way, the match's own outcome stands instead; any other outcome the ordinary reading reaches — an answer, or a withholding of its own that is not this one — stands as it always has.
    public static func firstAnswered(_ match: InPlaceShape.Match, timeBudget: TimeInterval = InPlaceAnswer.timeBudget, by answer: (InPlaceShape.Match, TimeInterval) -> Outcome) -> (reading: InPlaceShape.Match, outcome: Outcome) {
        let started = Date()
        let outcome = answer(match, timeBudget)
        let remaining = timeBudget - Date().timeIntervalSince(started)
        guard case .withheld = outcome, let ordinary = match.ordinary, remaining > 0 else { return (match, outcome) }
        let ordinaryOutcome = answer(ordinary, remaining)
        guard ordinaryOutcome != .withheld(.otherStatementsRun) else { return (match, outcome) }
        return (ordinary, ordinaryOutcome)
    }

    /// Answers `call`, whose relative paths resolve against `directory`, or says why not.
    ///
    /// `serverGone` spells the calls the opening line names for Bash (``IndexSuggestion/cliCall``), for a context whose transcript records the MCP server leaving it: the calls the answer claims to have made are named in the one form such a context could have made them in.
    ///
    /// What the answer stands for — the whole of what was asked, or the lookup inside a command that carried other work too — reaches the opening line and nothing else: whether an answer is exact never turns on how much of the caller's command it covers.
    ///
    /// `oversized` is told how many bytes an answer came to wherever one is built and then withheld over `sizeBudget`, which is how far over the budget a replay reports it went; a search stopped at its ceiling before any answer was built tells it nothing.
    ///
    /// `fallbackFollows` says a `||` fallback that could print follows the lookup (``InPlaceShape/Match/fallbackFollows``): the answer then stands only where the lookup's success is proven, and a grep with nothing after it is proven only by the line its own search prints — which every grep shape already requires — so the loose reading below, which runs no search, is tried for it only where the search, run again to its end, prints a line.
    ///
    /// **A word-anchored sweep whose proof fails is asked again as the names shape.** `grep -rnw Depot Sources` is read as the sweep, whose answer has to account for every line the grep prints; where it cannot (`notExact`), the same name is asked as the loose spelling asks it — one plain `where`, rooted and bounded as that shape is, under that shape's own back-off, and inside what is left of the time budget, so the whole attempt still fits the budget the caller gave. A failed proof leaves no proven answer to hand over, and the unproven one is exactly what `grep -rn Depot Sources` is given: without the fallback, writing the search more precisely bought the caller less, which is not a rule anyone could be taught. Only the failed proof falls back — and only where the sweep resolves the name as written: a case-folded sweep (`-i`) does not fall back, since `where` resolves the name as written and the search does not, so the loose answer would not say what the search says. Every other withholding of the anchored reading stands as it is, because each is a bound both shapes share or a budget already spent. The one cost is an engine: a proof the search alone defeats refuses without opening one, and the fallback then opens it, because the names shape has no search to weigh and nothing but the index to answer from.
    public static func answer(
        _ call: InPlaceCall,
        from directory: String?,
        serverGone: Bool = false,
        wholeCommand: Bool = true,
        timeBudget: TimeInterval = InPlaceAnswer.timeBudget, deadline: InPlaceDeadline = .wallClock,
        sizeBudget: Int = InPlaceAnswer.sizeBudget,
        backoff: InPlaceBackoff = .standard(),
        fallbackFollows: Bool = false,
        oversized: (@Sendable (Int) -> Void)? = nil
    ) -> Outcome {
        let started = Date()
        let conditions = Conditions(
            directory: directory,
            serverGone: serverGone,
            wholeCommand: wholeCommand,
            lookups: 1,
            sizeBudget: sizeBudget,
            backoff: backoff,
            oversized: oversized
        )
        let anchored = attempt(call, under: conditions, timeBudget: timeBudget, deadline: deadline)
        // `where` resolves a name as it is spelled; a case-folded sweep does not, so a wrong-cased site the sweep
        // never printed would come back as though it had, and that is not a loose reading of the same question.
        guard case .withheld(.notExact) = anchored, case let .references(name, search) = call,
              !search.options.ignoresCase, !search.options.wholeLine
        else { return anchored }
        // A grep with nothing after it succeeds only where it prints a line, and the loose reading runs no search to
        // show one: behind a fallback that could print, the search is run again, and the fallback ran unless it printed.
        // What the proof did not spend, and nothing more: a proof that used the budget up leaves the refusal
        // standing rather than starting a second wait the hook's own timeout would cut off.
        let remaining = timeBudget - Date().timeIntervalSince(started)
        guard remaining > 0 else { return anchored }
        guard !fallbackFollows || search.cut != nil || FallbackProof.printsALine(search, in: directory, under: referenceCeiling(budget: sizeBudget)) else { return anchored }
        let loose = attempt(.symbols(names: [name], paths: search.paths), under: conditions, timeBudget: timeBudget - Date().timeIntervalSince(started), deadline: deadline)
        guard case let .answered(answered) = loose else { return loose }
        // Timed from the first attempt: what the answer cost is what the caller waited for, the failed proof included.
        return .answered(Answered(
            reason: answered.reason,
            calls: answered.calls,
            root: answered.root,
            milliseconds: Int(Date().timeIntervalSince(started) * 1000)
        ))
    }

    /// One reading answered or withheld, with everything that reading's shape is held to: its rooting, its back-off, its store, its search, and the budgets.
    private static func attempt(_ call: InPlaceCall, under conditions: Conditions, timeBudget: TimeInterval, deadline: InPlaceDeadline = .wallClock) -> Outcome {
        let (directory, sizeBudget, backoff) = (conditions.directory, conditions.sizeBudget, conditions.backoff)
        let root: String
        switch Self.root(for: call, from: directory) {
        case let .success(found):
            root = found
        case let .failure(why):
            return .withheld(why)
        }
        let shape = call.shape
        guard !backoff.isBackingOff(root: root, shape: shape) else { return .withheld(.backingOff) }
        // A `where` answer's callers come from the build's index store alone: with none, no `where` answer lists
        // one, so nothing is searched and nothing is opened to find that out. The names sweep withholds on the
        // same fact as the anchored one rather than answering declarations alone: both shapes hand over the same
        // call, and a stand-in that quietly drops what the offer promised is the one thing it may not be.
        if shape.needsIndexStore, !ReadOnlyIndex.hasIndexStore(atRoot: root) {
            return .withheld(.noStore)
        }
        return settle(root: root, shapes: [shape], under: conditions, timeBudget: timeBudget, deadline: deadline) {
            try await compute(call, root: root, directory: directory, sizeBudget: sizeBudget, spelling: conditions.spelling, cutting: conditions)
        }
    }

    /// Several calls answered together, each held to every bound it is held to alone, and all withheld where any one would be.
    ///
    /// **One root for the lot.** Each call is rooted as it would be alone — a Swift file by the repository it sits in, a document or a name search only inside the caller's own — and the roots have to agree, since one freshness header cannot speak for two trees. The back-off of every shape among them is asked, an index store is required where any of them needs one, and an overrun is noted against every one: what ran long cannot be charged to one call rather than another.
    private static func attempt(several calls: [InPlaceCall], literals: [Int: String], under conditions: Conditions, timeBudget: TimeInterval, deadline: InPlaceDeadline = .wallClock) -> Outcome {
        var roots = Set<String>()
        for read in calls {
            switch root(for: read, from: conditions.directory) {
            case let .success(found):
                roots.insert(CanonicalPath.of(found))
            case let .failure(why):
                return .withheld(why)
            }
        }
        guard roots.count == 1, let root = roots.first else { return .withheld(.outsideRoot) }
        let shapes = Array(Set(calls.map(\.shape)))
        guard !shapes.contains(where: { conditions.backoff.isBackingOff(root: root, shape: $0) }) else { return .withheld(.backingOff) }
        if shapes.contains(where: \.needsIndexStore), !ReadOnlyIndex.hasIndexStore(atRoot: root) {
            return .withheld(.noStore)
        }
        let (directory, sizeBudget) = (conditions.directory, conditions.sizeBudget)
        return settle(root: root, shapes: shapes, under: conditions, timeBudget: timeBudget, deadline: deadline) {
            try await computeParts(calls, literals: literals, root: root, directory: directory, sizeBudget: sizeBudget, spelling: conditions.spelling)
        }
    }

    /// Runs `compute` under the time budget and frames what it computed as the refusal, under the size budget, with every byte charged to a call.
    ///
    /// Where the whole answer is over the size budget and a bounded one was computed beside it — the members line windows overlap, for their files' whole digests — the bounded one is framed instead, held to the same budget.
    private static func settle(
        root: String,
        shapes: [InPlaceCall.Shape],
        under conditions: Conditions,
        timeBudget: TimeInterval, deadline: InPlaceDeadline = .wallClock,
        compute: @escaping @Sendable () async throws -> Computation
    ) -> Outcome {
        let backoff = conditions.backoff
        let started = Date()
        let box = ResultBox()
        let finished = DispatchSemaphore(value: 0)
        // A detached task inherits no task-locals, so the root discovery and the engines a replay bound are carried across by hand.
        let (roots, engines) = (RootDiscovery.current, EngineReuse.current)
        Task.detached {
            await RootDiscovery.$current.withValue(roots) {
                await EngineReuse.$current.withValue(engines) { await box.store(Result { try await compute() }) }
            }
            finished.signal()
        }
        // Past the budget the query is abandoned where it stands: the hook's process ends with the refusal, and an
        // interrupted write is SQLite's to roll back.
        guard finished.wait(timeout: deadline.instant(after: timeBudget)) == .success, let result = box.value else {
            for shape in shapes {
                backoff.noteOverrun(root: root, shape: shape)
            }
            return .withheld(.overTime)
        }
        guard case let .success(computation) = result else { return .withheld(.failed) }
        let candidates: [Computed]
        let paged: Computed?
        switch computation {
        case let .answer(answer, bounded, cut):
            candidates = [answer] + (bounded.map { [$0] } ?? [])
            paged = cut
        case let .withheld(why):
            return .withheld(why)
        }
        let computed: Computed
        let reason: (text: String, served: Int)
        switch chosen(candidates, cut: paged, under: conditions) {
        case let .success(pair):
            (computed, reason) = pair
        case let .failure(why):
            return .withheld(why)
        }
        // Every byte served is charged to some call: each its own text, and the framing to the first.
        let framing = reason.served - computed.calls.reduce(0) { $0 + $1.served }
        let calls = computed.calls.enumerated().map { index, call in
            Call(tool: call.tool, target: call.target, bytes: AnswerBytes(served: call.served + (index == 0 ? framing : 0), source: call.source))
        }
        return .answered(Answered(
            reason: reason.text,
            calls: calls,
            root: computed.root,
            milliseconds: Int(Date().timeIntervalSince(started) * 1000)
        ))
    }

    /// The repository a call is answered from: the one holding the file a digest names, which is not always the one the caller stands in, or the one every operand of a sweep names — a worktree for a worktree, and never one repository for another's files.
    private static func root(for call: InPlaceCall, from directory: String?) -> Result<String, Withholding> {
        switch call {
        case let .members(search):
            // Every operand's repository, asked of the directory a file or a glob stands in, and one for them all.
            let roots = search.paths.map { path in
                OperandFile.absolute(path, in: directory).flatMap { CallerRoot.root(forCallerIn: SearchOperand(path: $0).directory) }.map(CanonicalPath.of)
            }
            guard let first = roots.first, let root = first else { return .failure(.noRepository) }
            guard roots.allSatisfy({ $0 == root }) else { return .failure(.outsideRoot) }
            return .success(root)
        case let .fileDigest(path, _), let .declarations(path, _), let .memberRange(path, _):
            guard let file = OperandFile.absolute(path, in: directory),
                  let root = CallerRoot.root(forCallerIn: URL(fileURLWithPath: file).deletingLastPathComponent().path)
            else {
                return .failure(.noRepository)
            }
            return .success(root)
        case let .documentOutline(path):
            // The caller's own repository, and the document inside it — the names shape's rule, for a reason of
            // its own. An outline consults no index, but the engine that renders it opens a store, and a store
            // is made in a checkout only where the caller stands in it: a document in another repository is
            // left to the read rather than answered at the price of a `.sift/` directory nobody there asked for.
            guard let directory, let root = CallerRoot.root(forCallerIn: directory).map(CanonicalPath.of) else { return .failure(.noRepository) }
            guard let file = OperandFile.absolute(path, in: directory),
                  CallerRoot.root(forCallerIn: URL(fileURLWithPath: file).deletingLastPathComponent().path).map(CanonicalPath.of) == root
            else {
                return .failure(.outsideRoot)
            }
            return .success(root)
        case let .references(_, search):
            let roots = search.paths.map { path in
                OperandFile.absolute(path, in: directory).flatMap { CallerRoot.root(forCallerIn: $0) }.map(CanonicalPath.of)
            }
            guard let first = roots.first, let root = first else { return .failure(.noRepository) }
            guard roots.allSatisfy({ $0 == root }) else { return .failure(.outsideRoot) }
            return .success(root)
        case let .symbols(_, paths, _, _, _):
            // Rooted by the search's own operands, as a sweep's are — and, unlike a sweep's, required to be the
            // caller's own repository too. What licenses this shape is the hook's assertion that `where` answers
            // it, and that assertion was made against the directory the command runs in (`PreToolUseCommand.lookup`
            // asks `couldAnswer` of it): answering a search of *another* repository's files out of an index nothing
            // checked would hand over an answer verified nowhere, and would index a stranger's checkout to do it.
            guard let directory, let root = CallerRoot.root(forCallerIn: directory).map(CanonicalPath.of) else { return .failure(.noRepository) }
            // A file or a glob is asked of the directory it stands in, which is the one a repository can be asked of.
            let operands = paths.map { path in
                OperandFile.absolute(path, in: directory).flatMap { CallerRoot.root(forCallerIn: SearchOperand(path: $0).directory) }.map(CanonicalPath.of)
            }
            guard operands.allSatisfy({ $0 == root }) else { return .failure(.outsideRoot) }
            return .success(root)
        }
    }

    /// The lines the command's own search prints, or why no answer can account for them — worked out before the engine is opened, since it needs nothing but the files.
    ///
    /// A whole read — of a Swift file or of a document — makes no search, and prints nothing this has to account for. A search that prints nothing is not answered: an answer would name lines the command never showed. A sweep's search runs under a ceiling (``referenceCeiling(budget:)``) and stops at the first line no `where` answer could locate, or once locating them all would cost more than the whole refusal may.
    ///
    /// A names search runs only where it carries a proof (``InPlaceCall/symbols(names:paths:uncovered:proof:)``), and under a ceiling that stops at a line outside Swift source but spends nothing, since the references it is proven against are never served. Printing nothing leaves it the names search it is, which is answered without a search at all.
    private static func printedLines(of call: InPlaceCall, from directory: String?, sizeBudget: Int) -> Result<[ShellGrep.PrintedLine], Withholding> {
        let search: ShellGrep
        switch call {
        case .fileDigest, .documentOutline, .symbols(_, _, _, nil, _), .memberRange:
            return .success([])
        case let .declarations(_, grep), let .members(grep), let .references(_, grep), let .symbols(_, _, _, grep?, _):
            search = grep
        }
        let ceiling: ShellGrep.Ceiling? = switch call.shape {
        case .sweep:
            referenceCeiling(budget: sizeBudget)
        case .symbols:
            ShellGrep.Ceiling(admits: ExactAnswer.whereAnswerLocates(linesOf:), cost: { _, _ in 0 }, budget: 0)
        default:
            nil
        }
        let namedFiles = call.shape == .members || call.shape == .symbols && search.paths.contains { $0.hasSuffix(".swift") }
        return switch search.run(in: directory, ceiling: ceiling, namedFiles: namedFiles) {
        case let .printed(lines) where lines.isEmpty && call.shape == .symbols:
            .success(lines)
        case let .printed(lines) where lines.isEmpty:
            .failure(.notExact)
        case let .printed(lines):
            .success(lines)
        case .undecided:
            .failure(.unchecked)
        case .pastCeiling(.unaccounted):
            .failure(.notExact)
        case .pastCeiling(.overBudget):
            .failure(.overSize)
        }
    }

    /// The most a sweep's search may print: lines only of files a `where` answer lists lines of, and no more of them than the fewest bytes that locate them fit inside `budget`.
    private static func referenceCeiling(budget: Int) -> ShellGrep.Ceiling {
        ShellGrep.Ceiling(admits: ExactAnswer.whereAnswerLocates(linesOf:), cost: ExactAnswer.leastSpentLocating(_:ofFileAt:), budget: budget)
    }

    /// The answer, computed against an engine on `root` brought up to date for it — opened for this answer, or kept by a bound ``EngineReuse`` — or on `shared`, already brought up to date, where several calls share one — or why it is withheld.
    private static func compute(
        _ call: InPlaceCall,
        root: String,
        directory: String?,
        sizeBudget: Int,
        spelling: CallSpelling,
        shared: (engine: SiftEngine, freshness: Freshness)? = nil,
        cutting conditions: Conditions? = nil
    ) async throws -> Computation {
        // Before the engine is brought up to date, and without bringing it up to date at all: a document's
        // outline consults no index, so indexing a Swift tree to answer a question about prose would be pure
        // waste — and a build that ran past the budget doing it would back the shape off for the window.
        if case let .documentOutline(path) = call {
            return try documentOutline(at: path, root: root, directory: directory)
        }
        let printed: [ShellGrep.PrintedLine]
        switch printedLines(of: call, from: directory, sizeBudget: sizeBudget) {
        case let .success(lines):
            printed = lines
        case let .failure(why):
            return .withheld(why)
        }
        // In a tree that cannot be written, a parse of the whole tree for this one answer: the read runs instead.
        guard let engine = try shared?.engine ?? EngineReuse.freshenable(on: root) else { return .withheld(.treeNotWritable) }
        defer {
            if shared == nil {
                EngineReuse.release(engine, root: root)
            }
        }
        let freshness = if let shared {
            shared.freshness
        } else {
            try await engine.ensureFresh()
        }
        let answeredFrom = engine.repoRoot.path
        switch try FileDigestParts.readingWhole(call, in: directory, engine: engine) {
        case .documentOutline:
            // Answered above, out of the engine's store alone and before any of this: it is the one shape the
            // index says nothing about, so reaching here at all would mean it had been brought up to date for
            // a document, which is the waste this case's absence from the freshening path exists to avoid.
            return .withheld(.notExact)
        case let .fileDigest(path, windows):
            return try digestAnswer(path, windows: windows, in: directory, engine: engine, freshness: freshness, spelling: spelling, cutting: conditions)
        case let .declarations(path, search):
            guard let file = try OperandFile.indexed(path, in: directory, engine: engine),
                  let digest = try ExactAnswer.fileDigest(in: engine, path: file.relative, spelling: spelling),
                  let located = try declarationLines(byDigest: digest.text, of: file, search: search, in: engine),
                  printed.allSatisfy({ located.contains($0.line) })
            else {
                return .withheld(.notExact)
            }
            return try .answer(Computed(
                calls: [ComputedCall(tool: "digest", target: file.relative, served: digest.text.utf8.count, source: file.bytes)],
                root: answeredFrom,
                answer: engine.framing(freshness).headerLine + "\n" + digest.text,
                standsIn: "this answer did not weigh itself against the grep's output"
            ))
        case let .members(search):
            guard let parts = try memberAnswers(search, printed: printed, in: directory, engine: engine) else { return .withheld(.notExact) }
            return try .answer(Computed(
                calls: parts.flatMap(\.calls),
                root: answeredFrom,
                answer: engine.framing(freshness).headerLine + "\n" + parts.map(\.text).joined(separator: "\n\n"),
                standsIn: "a member's source is served as it stands"
            ))
        case let .memberRange(path, range):
            return try memberRange(path, range: range, in: directory, engine: engine, freshness: freshness)
        case let .references(name, _):
            guard let text = try await ExactAnswer.references(in: engine, of: name, freshness: freshness) else {
                return .withheld(.notExact)
            }
            guard locates(ExactAnswer.locations(inWhereAnswer: text), every: printed, in: engine) else { return .withheld(.notExact) }
            return .answer(Computed(
                calls: [ComputedCall(tool: "where", target: name, served: text.utf8.count, source: nil, references: true)],
                root: answeredFrom,
                answer: text,
                standsIn: "a `where` answer stands in for a search's output, which was never produced"
            ))
        case let .symbols(names, paths, uncovered, proof, unchecked):
            // The offer's own answer, handed over: one `where` per name, exactly the calls the refusal would
            // have listed. Nothing is proven against the search's output because no search was run — the hook
            // asserts `where` answers this shape at the moment it offers it, and all a refusal adds is the round
            // trip the context pays to come back for the same text.
            var headers: [String] = []
            var bodies: [String] = []
            var calls: [ComputedCall] = []
            var locatedPerName: [Set<ExactAnswer.Location>] = []
            for name in names {
                guard let answer = try await ExactAnswer.lookup(in: engine, of: name, freshness: freshness) else {
                    return .withheld(.notExact)
                }
                // Kept per name rather than over the lot: an alternation asks about each name, so one name found
                // inside the paths searched says nothing about another found only outside them.
                locatedPerName.append(ExactAnswer.locations(inWhereAnswer: answer.body))
                headers.append(answer.header)
                bodies.append(answer.body)
                calls.append(ComputedCall(tool: "where", target: name, served: answer.body.utf8.count, source: nil))
            }
            guard let header = headers.first else { return .withheld(.notExact) }
            // Checked before the headers agree: a name whose every site falls outside the paths searched is why
            // this is withheld, whatever its header reads — a name declared only under a target the semantic
            // store never built (a test target) carries a header of its own, and blaming that mismatch first
            // would name the wrong reason for an alternation this search was never going to hold anyway.
            guard locatedPerName.allSatisfy({ Self.searchHolds($0, within: paths, from: directory, engine: engine) }) else {
                return .withheld(.outsideSearch)
            }
            // One header for the lot: it is a fact about the tree every one of these answers came from, and
            // repeating it between them prices the freshness contract once per name. Every answer here comes
            // from one engine at one freshness, so a header that still differed once every name is inside the
            // paths searched would mean the answers did too.
            guard headers.allSatisfy({ $0 == header }) else { return .withheld(.notExact) }
            // A tree searched with a Swift file named beside it prints lines the answer cannot be checked against, so
            // the search runs. This is decided only once every bound above has held, so a file that is not there is
            // still withheld as outside the search.
            if unchecked {
                return .withheld(.unchecked)
            }
            // A name read through `T.Type`, `T.self` or `Self.x` stands in for the search only where every line it
            // prints is a site the names' references locate: a comment or a string literal spelling the expression
            // is a line no store records, and the name's answer says nothing about it.
            if proof != nil {
                var located = Set<ExactAnswer.Location>()
                for name in names {
                    guard let text = try await ExactAnswer.references(in: engine, of: name, freshness: freshness) else { return .withheld(.notExact) }
                    located.formUnion(ExactAnswer.locations(inWhereAnswer: text))
                }
                guard locates(located, every: printed, in: engine) else { return .withheld(.notExact) }
            }
            // The prose an alternation carried beside its names is named straight under the header, before any
            // name's sites, so what the answer leaves to a search is read before what it covers.
            let caveat = InPlaceAnswer.caveat(uncovered: uncovered).map { $0 + "\n\n" } ?? ""
            return .answer(Computed(
                calls: calls,
                root: answeredFrom,
                answer: header + "\n" + caveat + bodies.joined(separator: "\n\n"),
                standsIn: "a `where` answer stands in for a search's output, which was never produced"
            ))
        }
    }

    /// The heading outline of the document at `path`, or why it is withheld — the offer's own answer, read live from disk and handed over rather than proven.
    ///
    /// **The cheap checks run first here too, and no index is consulted at all.** The path has to name a regular file that is there, which costs a file probe; the engine is then opened for the store alone, to place that path inside the repository and render the outline through `digest`'s own renderer. Nothing calls `ensureFresh`: no part of this answer comes from the index, so there is nothing about it a stale index could make wrong.
    ///
    /// **No freshness header over it, deliberately.** The outline's own first line already says the document was read live from disk and that nothing in it is indexed; a tree line above that would price an index state nothing here consulted, and would read as a claim that this answer came from it.
    private static func documentOutline(at path: String, root: String, directory: String?) throws -> Computation {
        guard let file = OperandFile.existing(path, in: directory) else { return .withheld(.notExact) }
        let engine = try EngineReuse.engine(on: root)
        defer { EngineReuse.release(engine, root: root) }
        guard let outline = try outline(ofFile: file, in: engine) else { return .withheld(.notExact) }
        // An outline past a third of the document is a table of contents nearly as long as the text, and costs
        // the turn a re-run takes to read it anyway: the read runs.
        return outline.call.served * 3 > outline.call.source ?? .max ? .withheld(.outlineTooLarge) : .answer(Computed(
            calls: [outline.call],
            root: engine.repoRoot.path,
            answer: outline.text,
            standsIn: "an outline stands in for the document"
        ))
    }

    /// The heading outline of the document at `file`, with the call that served it, or `nil` where the outline would not stand in for the read.
    private static func outline(ofFile file: String, in engine: SiftEngine) throws -> (call: ComputedCall, text: String)? {
        guard let relative = ExactAnswer.repositoryRelativePath(of: file, in: engine),
              let outline = try ExactAnswer.documentOutline(in: engine, path: relative)
        else {
            return nil
        }
        return (ComputedCall(tool: "digest", target: relative, served: outline.text.utf8.count, source: outline.bytes?.source), outline.text)
    }

    /// Whether every line in `printed` is one of the sites `located`, placed against `engine`'s repository.
    private static func locates(_ located: Set<ExactAnswer.Location>, every printed: [ShellGrep.PrintedLine], in engine: SiftEngine) -> Bool {
        printed.allSatisfy { line in
            ExactAnswer.repositoryRelativePath(of: line.file, in: engine).map { located.contains(ExactAnswer.Location(path: $0, line: line.line)) } ?? false
        }
    }

    /// Whether the files and subtrees `paths` names hold any of the sites one name's answer located — the one bound on a shape nothing else proves.
    ///
    /// A search narrower than the repository asks a narrower question, and the `where` answer standing in for it does not: `grep -rn Depot Sources` asks whether `Depot` is used in `Sources`, and an answer listing its declaration under `Tests` reads as a yes where the search itself would have printed nothing. So where every site falls outside the operands the answer is withheld and the search runs, printing the nothing that is the truth. It is asked of one name's sites at a time, and an alternation is answered only where every name has a site inside: one name found inside is no evidence about another found only outside, and dropping that one would hand back a partial answer that reads as complete. Where a name has a site inside, its answer stands whole rather than narrowed to it, since dropping the rest would be a narrowing nobody could see.
    ///
    /// An operand may be a tree, a Swift file or a shell glob of them (``SearchOperand``): a file holds only a site in that file, and a glob only a site in a file it matches as the shell matches it. An operand that *is* the repository bounds nothing (its scope is empty), and neither does a call carrying no operands — a `Grep` with no path searches everything under the caller. An operand with no scope at all — a file that is not there, a path that resolves nowhere in the repository — holds nothing, so an answer is never handed over for a search that would only have printed an error.
    private static func searchHolds(_ located: Set<ExactAnswer.Location>, within paths: [String], from directory: String?, engine: SiftEngine) -> Bool {
        guard !paths.isEmpty else { return true }
        let searched = paths.compactMap { OperandFile.absolute($0, in: directory) }
        let operands = searched.map(SearchOperand.init(path:))
        let scopes = operands.compactMap { operand in operand.scope(inRepositoryAt: engine.repoRoot.path).map { (operand, $0) } }
        guard scopes.count == paths.count else { return false }
        guard !scopes.contains(where: \.1.isEmpty) else { return true }
        return located.contains { site in
            scopes.contains { $0.holds(site.path, scope: $1) }
        }
    }
}

private extension InPlaceAnswerer {
    /// Every call's answer in command order under one freshness header, with a compound line's literals printed where they fall, or the first withholding among them — and, where any call is a window whose lines can be read, the same with each such window answered by the members it overlaps.
    ///
    /// **One engine for the lot, brought up to date once**, and the documents probed on disk before it opens. A document's outline sits under the header as it stands: its own first line says it was read live from disk, so the header prices only the index the answers beside it came from. With nothing but documents there is no header, as for a document read alone. Every other call is computed as it would be alone, on the shared engine: an answer that opens on that engine's header stands under the one header above them all, and one that opens on any other — a `where`, whose header states the semantic store's freshness too — keeps its own, so no part stands under a header that does not speak for it; the header above them all is printed only where some part stands under it. A part identical to one before it, the same call with the same text, is not repeated, and where a literal was printed between the two the line is withheld, since the one copy cannot sit on both sides of it.
    ///
    /// **Nothing is loosened inside a line.** A call is held to exactly what it is held to alone, and the word-anchored sweep's loose reading is never tried here: a failed proof withholds the whole line.
    static func computeParts(
        _ calls: [InPlaceCall],
        literals: [Int: String],
        root: String,
        directory: String?,
        sizeBudget: Int,
        spelling: CallSpelling
    ) async throws -> Computation {
        var documents: [String: String] = [:]
        for case let .documentOutline(path) in calls {
            guard let file = OperandFile.existing(path, in: directory) else { return .withheld(.notExact) }
            documents[path] = file
        }
        // Outlines alone parse nothing; anything else would parse the whole of a tree whose index lives in memory.
        guard let engine = try calls.allSatisfy({ $0.shape == .outline }) ? EngineReuse.engine(on: root) : EngineReuse.freshenable(on: root) else { return .withheld(.treeNotWritable) }
        defer { EngineReuse.release(engine, root: root) }
        let freshness = calls.contains { $0.shape != .outline } ? try await engine.ensureFresh() : nil
        var parts: [(calls: [ComputedCall], text: String)] = []
        var boundedParts: [(calls: [ComputedCall], text: String)] = []
        // One entry per file whose windows stood in for its whole digest, named beside the ranges shown —
        // several files on one line share no single call the opening line's note could qualify, so the note
        // names each bounded file's path itself, and the scan matches a call back to it by that path.
        var boundedFiles: [(path: String, lines: String)] = []
        // The files among them whose members stand in for their digests in the whole answer too.
        var setAsideFiles: [(path: String, lines: String)] = []
        // Why each was set aside: no smaller than its windows, a first page that stops short of them, or a digest
        // naming them on their type's line alone.
        var setAsideWhy: [String] = []
        // Whether any part stands under the one header above them all rather than under its own.
        var sharesHeader = false
        // A literal is part of what the line printed, served by no call: its bytes are the framing's.
        let literal = { (index: Int) -> (calls: [ComputedCall], text: String)? in
            literals[index].map { (calls: [], text: $0) }
        }
        for (index, call) in try calls.map({ try FileDigestParts.readingWhole($0, in: directory, engine: engine) }).enumerated() {
            if let text = literal(index) {
                parts.append(text)
                boundedParts.append(text)
            }
            let part: (calls: [ComputedCall], text: String)
            switch call {
            case let .fileDigest(path, windows):
                guard try !unparsed(path, in: directory, engine: engine) else { return .withheld(.parseError) }
                guard try !readsLinesNoDigestShows(path, windows: windows, in: directory, engine: engine, spelling: spelling) else { return .withheld(.linesNotShown) }
                guard let digest = try FileDigestParts.wholeFileDigest(path, windows: windows, in: directory, engine: engine, spelling: spelling) else { return .withheld(.notExact) }
                part = (calls: [digest.call], text: digest.text)
            case let .documentOutline(path):
                guard let outline = try documents[path].flatMap({ try outline(ofFile: $0, in: engine) }) else { return .withheld(.notExact) }
                part = (calls: [outline.call], text: outline.text)
            default:
                guard let freshness else { return .withheld(.notExact) }
                let computation = try await compute(call, root: root, directory: directory, sizeBudget: sizeBudget, spelling: spelling, shared: (engine, freshness))
                guard case let .answer(computed, _, _) = computation else {
                    if case let .withheld(why) = computation {
                        return .withheld(why)
                    }
                    return .withheld(.notExact)
                }
                // An answer opening on the shared header sits under the one header above them all; any other keeps
                // its own — a `where`'s states the semantic store's freshness as well — so every part's is stated.
                let header = try engine.framing(freshness).headerLine + "\n"
                if computed.answer.hasPrefix(header) {
                    part = (calls: computed.calls, text: String(computed.answer.dropFirst(header.count)))
                    sharesHeader = true
                } else {
                    part = (calls: computed.calls, text: computed.answer)
                }
            }
            if case .fileDigest = call {
                sharesHeader = true
            }
            if let earlier = parts.firstIndex(where: { $0.text == part.text && $0.calls.map(\.target) == part.calls.map(\.target) && $0.calls.map(\.tool) == part.calls.map(\.tool) }) {
                // Said once, where it was first said — unless a literal was printed since, which the repeat follows
                // and the one copy cannot: a literal is the one part no call serves.
                guard !parts[(earlier + 1)...].contains(where: \.calls.isEmpty) else { return .withheld(.notExact) }
                continue
            }
            guard case let .fileDigest(path, windows) = call, let whole = part.calls.first,
                  let members = try FileDigestParts.windowAnswers(path, windows: windows, in: directory, engine: engine, spelling: spelling)
            else {
                // A window with no members to stand in, one that prints no lines, is still weighed on its own.
                if case .fileDigest = call, let whole = part.calls.first, whole.weighsWindow, whole.served >= whole.source ?? 0 || !whole.standsInForWindow {
                    return .withheld(whole.standsInForWindow ? .notSmaller : .notExact)
                }
                parts.append(part)
                boundedParts.append(part)
                continue
            }
            let memberParts = members.map { (calls: [$0.call], text: $0.text) }
            let bounded = (path: whole.target, lines: members.map { String($0.call.target.dropFirst(whole.target.count + 1)) }.joined(separator: ", "))
            boundedParts += memberParts
            boundedFiles.append(bounded)
            // Each window is weighed against its own lines, so a whole read's saving beside it never pays for a
            // digest bigger than the window: where the digest is not smaller, the members stand in for it, and
            // where they are not smaller either, the line is not answered.
            guard whole.weighsWindow, let window = whole.source, whole.served >= window || !whole.standsInForWindow else {
                parts.append(part)
                continue
            }
            guard members.reduce(0, { $0 + $1.call.served }) < window else { return .withheld(.notSmaller) }
            // Members leave the `import` lines the window prints without a trace: the whole digest's own
            // withholding stands.
            guard !members.contains(where: \.call.overlapsImports) else { return .withheld(whole.standsInForWindow ? .notSmaller : .notExact) }
            parts += memberParts
            setAsideFiles.append(bounded)
            setAsideWhy.append(whole.standsInForWindow ? Computed.digestNoSmallerThanItsLines : FileDigestParts.whyNotStandingIn(whole))
        }
        if let text = literal(calls.count) {
            parts.append(text)
            boundedParts.append(text)
        }
        let note = { (files: [(path: String, lines: String)]) in
            files.isEmpty ? nil : "only members of " + files.map { "\($0.path) lines \($0.lines)" }.joined(separator: "; ") + " are shown"
        }
        let header = try sharesHeader ? freshness.map { try engine.framing($0).headerLine } : nil
        let computed = { (parts: [(calls: [ComputedCall], text: String)], note: String?) in
            let body = CompoundAnswerBody.joined(parts.map { (isLiteral: $0.calls.isEmpty, text: $0.text) })
            return Computed(
                calls: parts.flatMap(\.calls),
                root: engine.repoRoot.path,
                answer: header.map { $0 + "\n" + body } ?? body,
                standsIn: "these answers did not weigh themselves against their sources",
                note: note
            )
        }
        let wholeNote = note(setAsideFiles).map { "\($0); \(Computed.joined(reasons: setAsideWhy))" }
        // The members answer shows those files' members too, so its note owes their reasons as well as its own.
        var bounded = boundedFiles.isEmpty ? nil : computed(boundedParts, note(boundedFiles))
        bounded?.setAsideWhy = setAsideWhy
        return .answer(computed(parts, wholeNote), bounded: bounded)
    }
}

extension InPlaceAnswerer {
    /// A read of one Swift file, whole or through windows, answered with its digest and — where the windows' lines can be read — the members they overlap beside it, or why it is withheld.
    ///
    /// Where `conditions` is given, a whole digest whose refusal runs past the size budget is answered beside with its first page cut to fit (``pageCut(of:bounded:digest:read:engine:under:onRender:)``).
    static func digestAnswer(_ path: String, windows: [LineWindow], in directory: String?, engine: SiftEngine, freshness: Freshness, spelling: CallSpelling, cutting conditions: Conditions? = nil, onRender: (() -> Void)? = nil) throws -> Computation {
        guard try !unparsed(path, in: directory, engine: engine) else { return .withheld(.parseError) }
        guard try !readsLinesNoDigestShows(path, windows: windows, in: directory, engine: engine, spelling: spelling) else { return .withheld(.linesNotShown) }
        guard let digest = try FileDigestParts.wholeFileDigest(path, windows: windows, in: directory, engine: engine, spelling: spelling) else { return .withheld(.notExact) }
        // Framed once the digests have read: the one that found the file stale is the one that reparsed it.
        let bounded = try FileDigestParts.windowAnswers(path, windows: windows, in: directory, engine: engine, spelling: spelling).map { parts -> Computed in
            let lines = parts.map { String($0.call.target.dropFirst(digest.call.target.count + 1)) }.joined(separator: ", ")
            let text = try engine.framing(freshness).headerLine + "\n" + DigestRenderer.joinedAnswers(parts.map(\.text))
            return Computed(calls: parts.map(\.call), root: engine.repoRoot.path, answer: text, standsIn: "these member lines did not weigh themselves against the lines asked for", note: "only the members of lines \(lines) are shown")
        }
        let whole = try Computed(calls: [digest.call], root: engine.repoRoot.path, answer: engine.framing(freshness).headerLine + "\n" + digest.text, standsIn: "this digest did not weigh itself against the file's source")
        // A page that stops short of a window's members, or a digest naming them on their type's line alone,
        // accounts for none of what the window prints there: the members stand in, or the read runs — as it does
        // where the window prints `import` lines, which the members leave without a trace.
        guard digest.call.standsInForWindow else {
            guard var members = bounded, !members.calls.contains(where: \.overlapsImports) else { return .withheld(.notExact) }
            members.note = members.note.map { "\($0); \(FileDigestParts.whyNotStandingIn(digest.call))" }
            return .answer(members, bounded: nil)
        }
        return try .answer(whole, bounded: bounded, cut: conditions.flatMap { try pageCut(of: whole, bounded: bounded, digest: digest, read: DigestRead(path: path, windows: windows, directory: directory), engine: engine, under: $0, onRender: onRender) })
    }

    /// The source of the one member a pattern range prints, where the lines it prints from the file are proven to be exactly that member's first line through its closing one, served verbatim — or why it is withheld.
    private static func memberRange(_ path: String, range: RangeRead, in directory: String?, engine: SiftEngine, freshness: Freshness) throws -> Computation {
        guard let file = try OperandFile.indexed(path, in: directory, engine: engine), let lines = range.printedLines(of: file.lines),
              let sources = try ExactAnswer.memberSources(in: engine, file: file.relative, declaredOn: [lines.lowerBound], source: file.lines),
              sources.count == 1, sources[0].lines == lines
        else {
            return .withheld(.notExact)
        }
        let answer = memberAnswer(sources, rest: [], of: file)
        return try .answer(Computed(
            calls: answer.calls,
            root: engine.repoRoot.path,
            answer: engine.framing(freshness).headerLine + "\n" + answer.text,
            standsIn: "a member's source is served as it stands"
        ), bounded: nil)
    }

    /// The candidate answer served, framed as the refusal carrying it, or why none may be: the whole answer over the size budget, or no candidate smaller than the window it stands in for.
    ///
    /// `cut` is the whole digest's first page cut to fit the size budget, served only where nothing else is and it saves enough (``servedCut(_:under:)``).
    static func chosen(_ candidates: [Computed], cut: Computed? = nil, under conditions: Conditions) -> Result<(Computed, (text: String, served: Int)), Withholding> {
        let sizeBudget = conditions.sizeBudget
        let frame = { (computed: Computed, note: String?) in framed(computed, note: note, under: conditions) }
        // A whole answer whose closing line can state no size that is its own is withheld outright where it fits,
        // since a bounded answer's note could name no true reason for setting it aside.
        guard let whole = candidates.first.map({ frame($0, $0.note) }), whole.1.served > sizeBudget || whole.1.statesItsSize else { return .failure(.notSmaller) }
        // A bounded answer's note says why the whole digest was set aside, which only the whole's own framing decides:
        // the first check `servable` finds it failing.
        let setAside = whole.0.whySetAside(whole.0.shortfall(as: whole.1, sizeBudget: sizeBudget, weighed: whole.0.weighsRead), served: whole.1.served)
        let framed = [whole] + candidates.dropFirst().map { bounded in
            frame(bounded, bounded.note.map { "\($0); \(Computed.joined(reasons: bounded.setAsideWhy + [setAside]))" })
        }
        // A bounded answer wins only where the whole refusal it would be framed as — opening line, freshness
        // header and closing line included, not the member listing alone — is still smaller than the windows'
        // own source, a part that weighs none left out of both sides: a listing that reads short on its own can
        // still lose to what naming it and pricing it costs, and that framing is what the caller actually pays
        // for choosing this candidate over the whole digest's own withholding. Failing that, the whole answer's
        // own withholding stands.
        // The whole answer is held to the same test where it stands in for a window: a digest bigger than the
        // lines asked for costs more than letting them print, whatever it saves against the whole file.
        // Smaller means smaller as stated, too: a refusal whose own closing line says it saved nothing —
        // where the line claiming the saving would have made it no smaller than the window — is not served.
        // So is a whole read's: an answer no smaller than the file it stands in for is not worth serving, and nor
        // is any refusal whose closing line states a size that is not its own.
        // And a window's answer that does not show the lines it asks for saves at least the floor, or the re-run
        // that follows it costs more than it saved: one that would otherwise be served makes the window run as
        // `linesNotShown`, whatever else is set aside.
        var belowFloor = false
        // No candidate is served whose members leave the `import` lines a window prints without a trace, which
        // only the whole digest's `imports:` line accounts for: where that digest is not served, the read runs,
        // for the whole answer's own reason.
        let servable = { (index: Int, pair: (Computed, InPlaceAnswer.Refusal)) in
            guard !pair.0.calls.contains(where: \.overlapsImports), pair.1.statesItsSize else { return false }
            let shortfall = pair.0.shortfall(as: pair.1, sizeBudget: sizeBudget, weighed: index > 0 || pair.0.weighsRead)
            belowFloor = belowFloor || shortfall == .belowFloor
            return shortfall == nil
        }
        // A whole digest that would be served still gives way to the members its windows overlap where they are
        // strictly smaller, both as listed and as the refusal the caller reads: the digest answers a question
        // about the file, the members the one the window asked. The listings are weighed too, so two answers
        // whose notes alone differ — a line of several files whose every window's digest was already set aside —
        // or that tie keep the whole digest. A line of several files is weighed once, all its windows' members
        // against the digests it would otherwise serve, since the framing, notices included, is shared. A window
        // over a file's imports keeps the whole digest, since its members are never servable.
        if servable(0, whole), let bounded = candidates.dropFirst().first,
           bounded.answer.utf8.count < whole.0.answer.utf8.count
        {
            let members = frame(bounded, bounded.note.map { "\($0); \(Computed.joined(reasons: bounded.setAsideWhy + [FileDigestParts.larger]))" })
            if members.1.served < whole.1.served, servable(1, members) {
                return .success((members.0, (members.1.text, members.1.served)))
            }
        }
        guard let chosen = framed.enumerated().first(where: servable).map(\.element) else {
            guard !belowFloor else { return .failure(.linesNotShown) }
            guard whole.1.served > sizeBudget else { return .failure(.notSmaller) }
            if let page = servedCut(cut, under: conditions) {
                return .success(page)
            }
            conditions.oversized?(whole.1.served)
            return .failure(.overSize)
        }
        return .success((chosen.0, (chosen.1.text, chosen.1.served)))
    }
}

private extension InPlaceAnswerer {
    /// Whether any of `windows` on the file at `path` reads lines no digest shows — only lines of a declaration's leading doc comment, which a digest carries the summary of at most, or lines whose members answer would name one member and nothing else, which the reader who chose the window already knew — so that window is never answered in place, whatever an answer would save.
    private static func readsLinesNoDigestShows(_ path: String, windows: [LineWindow], in directory: String?, engine: SiftEngine, spelling: CallSpelling) throws -> Bool {
        guard !windows.isEmpty,
              let file = try OperandFile.indexed(path, in: directory, engine: engine),
              let ranges = LineWindow.ranges(of: windows, in: file.lines, byteLengths: file.byteLengths)
        else {
            return false
        }
        return try ranges.contains { try engine.liesInLeadingDocComment($0, inFile: file.relative) || engine.namesOneMember($0, inFile: file.relative, options: DigestOptions(spelling: spelling)) }
    }

    /// The lines a declaration grep's digest accounts for — every declaration's first line it lists, its attribute lines and name line too where the search is one of the closed vocabulary spellings (``DeclarationVocabularyGrep``), and, where the pattern asks for column-0 braces, the ends of its top-level declarations' ranges — or `nil` where a brace in the file is not one of those ends.
    ///
    /// Every column-0 brace is asked of, printed or cut away: one the digest does not name is a sign the file is not what the digest's ranges make it look like.
    static func declarationLines(byDigest text: String, of file: OperandFile.Indexed, search: ShellGrep, in engine: SiftEngine) throws -> Set<Int>? {
        let located = try search.linesLocated(byDigest: text, of: file, in: engine)
        guard InPlaceShape.asksForClosers(search.pattern, patternWasQuoted: search.patternWasQuoted) else { return located }
        return try ExactAnswer.closersLocated(byDigest: text, of: file.relative, source: file.lines, in: engine).map { located.union($0) }
    }

    /// A member grep's answer file by file in operand order, each proven as a grep of that file alone would be, or `nil` where any file named is not one the index holds or prints a line the proof cannot account for: no part of the call is answered alone.
    static func memberAnswers(_ search: ShellGrep, printed: [ShellGrep.PrintedLine], in directory: String?, engine: SiftEngine) throws -> [(calls: [ComputedCall], text: String)]? {
        guard let named = search.namedFiles(in: directory) else { return nil }
        var parts: [(calls: [ComputedCall], text: String)] = []
        var seen = Set<String>()
        for path in named where seen.insert(path).inserted {
            guard let file = try OperandFile.indexed(path, in: directory, engine: engine) else { return nil }
            let lines = printed.filter { $0.file == path }
            guard !lines.isEmpty else { continue }
            guard let part = try memberAnswer(printed: lines, of: file, in: engine) else { return nil }
            parts.append(part)
        }
        return !parts.isEmpty && printed.allSatisfy { seen.contains($0.file) } ? parts : nil
    }

    /// A member grep's answer for the lines it prints of one file, or `nil` where they are not every one a line of a member served or context around one: every match has to be a served member's declaration.
    static func memberAnswer(printed: [ShellGrep.PrintedLine], of file: OperandFile.Indexed, in engine: SiftEngine) throws -> (calls: [ComputedCall], text: String)? {
        let matched = ShellGrep.matchedLines(printed).map(\.line)
        guard !matched.isEmpty,
              let sources = try ExactAnswer.memberSources(in: engine, file: file.relative, declaredOn: matched, source: file.lines)
        else {
            return nil
        }
        // A match has to be a declaration served, not merely a line inside one's body: a string literal or a
        // local that happens to spell the pattern is text the grep found for another reason.
        let declared = matched.allSatisfy { line in sources.contains { $0.lines != nil && $0.declaration.contains(line) } }
        guard declared else { return nil }
        // Every other printed line is context around one of those declarations. Inside a member served it is
        // served there; past a member's end or before its start — the context's count was a guess at the
        // member's length — it is served verbatim beside the member, by its own number.
        let served = sources.compactMap(\.lines)
        let rest = printed.map(\.line).filter { line in !served.contains { $0.contains(line) } }
        guard rest.allSatisfy({ file.lines.indices.contains($0 - 1) }) else { return nil }
        return memberAnswer(sources, rest: rest, of: file)
    }

    /// A member grep's answer: every member's source, and each run of the lines its context printed outside them, verbatim and numbered, beside the member it follows — with the calls that served it.
    ///
    /// The runs are lines the context's count reached past a member's end or before its start, a whole following member's lines included: they are served as the lines they are, never as a member, so nothing about them needs proving but that they are the file's own. A run is charged to the member it follows, or to the first where it comes before them all, so every byte but the joins between parts is some call's.
    static func memberAnswer(_ sources: [ExactAnswer.ServedSource], rest: [Int], of file: OperandFile.Indexed) -> (calls: [ComputedCall], text: String) {
        var runs: [ClosedRange<Int>] = []
        for line in rest {
            if let last = runs.last, last.upperBound + 1 == line {
                runs[runs.count - 1] = last.lowerBound ... line
            } else {
                runs.append(line ... line)
            }
        }
        let starts = sources.map { $0.lines?.lowerBound ?? $0.declaration.lowerBound }
        var parts = sources.enumerated().map { index, source in (start: starts[index], owner: index, text: source.answer.text) }
        for run in runs {
            let span = run.count == 1 ? "\(run.lowerBound)" : "\(run.lowerBound)-\(run.upperBound)"
            let lines = run.map { "\($0)-\(file.lines[$0 - 1])" }.joined(separator: "\n")
            let owner = starts.lastIndex { $0 < run.lowerBound } ?? 0
            parts.append((run.lowerBound, owner, "\(file.relative):\(span), the rest of the lines the context asked for:\n\(lines)"))
        }
        parts.sort { $0.start < $1.start }
        let calls = sources.enumerated().map { index, source in
            let served = parts.filter { $0.owner == index }.reduce(0) { $0 + $1.text.utf8.count }
            return ComputedCall(tool: "digest", target: source.target, served: served, source: nil)
        }
        return (calls, parts.map(\.text).joined(separator: "\n\n"))
    }
}

extension InPlaceAnswerer {
    /// What an attempt is made under: where the call was made, how its answer is framed, and the bounds it is held to.
    ///
    /// Everything here is shared by a fallback and the reading it stands in for. The time left over is what differs between them, so it rides beside this rather than inside it.
    struct Conditions: Sendable {
        let directory: String?
        let serverGone: Bool
        let wholeCommand: Bool
        /// How many of the command's statements the answer covers, which the opening line names them by.
        let lookups: Int
        let sizeBudget: Int
        let backoff: InPlaceBackoff
        /// Told how many bytes an answer came to where it was built and then withheld over ``sizeBudget``.
        var oversized: (@Sendable (Int) -> Void)?

        /// The face the answer's own advice is spelled for: the one the opening line names its calls in.
        var spelling: CallSpelling {
            serverGone ? .commandLine : .toolCall
        }
    }

    /// One call's part of a computed answer.
    struct ComputedCall: Sendable {
        let tool: String
        let target: String
        /// The bytes of the answer this call contributed.
        let served: Int
        let source: Int?
        /// Whether the call lists every reference site, which its spelling says.
        var references = false
        /// How the opening line names this call, where it differs from `target` — a bounded window's real call is the file's whole digest, `digest F.swift`, and it is that call the line and the ledger disagree on: the line says what was served, the ledger keeps `target` so a later whole read is still answered (``DigestedFiles/isDigested(_:among:resolve:)`` needs a whole-file target).
        var displayTarget: String?
        /// Whether `source` is the bytes of the lines a window prints rather than the whole file's.
        var weighsWindow = false
        /// The line count of the whole file a read prints, where `source` is that file's size on disk, and `nil` where it is not.
        var fileLines: Int?
        /// The text of every non-blank line the window this call weighs prints, without indentation, or none for a call that weighs no window.
        var windowText: [String] = []
        /// Whether the whole-file digest this call serves for a window lists the members the window reaches — false where a paged digest's first page stops short of them, so it accounts for none of the lines the window prints there.
        var reachesWindow = true
        /// Whether the whole-file digest this call serves for a window lists every member the window overlaps on a line of its own, with its line range — false where it names a nested type's members on that type's line alone, which places none of the lines the window prints there.
        var placesWindow = true
        /// Whether the window this call's members answer overlaps an `import` declaration's lines, which the whole-file digest accounts for on its `imports:` line and the members answer leaves without a trace.
        var overlapsImports = false

        /// Whether the whole-file digest this call serves may stand in for the window it weighs: its first page reaches the window, and it places every member there by its lines.
        var standsInForWindow: Bool {
            reachesWindow && placesWindow
        }

        /// The call as a refusal would name it — for Bash, once the transcript records the server gone — with every reference site asked for in that form's own spelling: the CLI's flag, or the tool's argument.
        ///
        /// A target holding whitespace is quoted in the tool's spelling too, as the transcript scan reads it back, since unquoted it reads as two targets.
        func spelled(serverGone: Bool) -> String {
            spelled(target: target, serverGone: serverGone)
        }

        /// The call as the opening line names it: `displayTarget` where the answer served less than it seems to offer, `target` otherwise.
        func displaySpelled(serverGone: Bool) -> String {
            spelled(target: displayTarget ?? target, serverGone: serverGone)
        }

        private func spelled(target: String, serverGone: Bool) -> String {
            if serverGone {
                return "sift \(tool) \(ShellWord.quoted(target))\(references ? InPlaceAnswer.referencesFlag : "")"
            }
            let named = target.contains(where: \.isWhitespace) ? ShellWord.quoted(target) : target
            return "\(tool) \(named)\(references ? InPlaceAnswer.referencesArgument : "")"
        }
    }
}

extension InPlaceAnswerer {
    /// What a call computed, before it is framed as a refusal.
    struct Computed: Sendable {
        let calls: [ComputedCall]
        let root: String
        let answer: String
        let standsIn: String
        /// The aside the opening line carries outside its backticks, where a call's display hides something the line still owes the reader — the lines a bounded window's members stand in for.
        var note: String?
        /// Why the whole digests of files on a line of several were already set aside for their windows' members, in the line's order: a members answer showing those members owes these reasons as well as its own.
        var setAsideWhy: [String] = []
        /// Whether some call weighed itself against what a read prints — a window's lines or a whole file — so the whole answer has to be smaller than what it weighed.
        var weighsRead: Bool {
            calls.contains { $0.weighsWindow || $0.fileLines != nil }
        }

        /// Whether a refusal of `served` bytes costs less than the source its calls weighed, the calls that weighed none left out of both sides.
        func undercutsWhatItWeighs(served: Int) -> Bool {
            let weighed = calls.compactMap(\.source).reduce(0, +)
            let unweighed = calls.filter { $0.source == nil }.reduce(0) { $0 + $1.served }
            return served - unweighed < weighed
        }

        /// Whether a refusal of `served` bytes stands in for a window whose lines its answer does not all show, while saving less than ``InPlaceAnswer/windowSavingFloor`` against the source its calls weighed — or while some file whose windows it does not show saves less than that on its own.
        ///
        /// On a line of several parts the whole line's saving never pays for a file's hidden windows: each such file's calls are weighed against that file's own windows' bytes, as listed, the framing the line shares left out. A window that runs alone can still be denied beside a large read for that reason, since alone it is weighed with the framing it would carry on its own.
        func savesTooLittleForWhatItHides(served: Int) -> Bool {
            let windows = calls.map(\.windowText).filter { !$0.isEmpty }
            guard calls.contains(where: \.weighsWindow), !windows.allSatisfy({ InPlaceAnswer.answer(answer, showsRunOf: $0) }) else { return false }
            return lineSavesTooLittle(served: served) || fileSavingTooLittleForWhatItHides != nil
        }

        /// Whether a refusal of `served` bytes saves less than ``InPlaceAnswer/windowSavingFloor`` across the whole line against the source its calls weighed.
        func lineSavesTooLittle(served: Int) -> Bool {
            let weighed = calls.compactMap(\.source).reduce(0, +)
            let unweighed = calls.filter { $0.source == nil }.reduce(0) { $0 + $1.served }
            return weighed - (served - unweighed) < InPlaceAnswer.windowSavingFloor
        }

        /// The first file whose windows this answer does not all show and which saves less than ``InPlaceAnswer/windowSavingFloor`` against those windows' own lines, its calls' listings weighed without the framing the line shares, with that saving; `nil` where none does.
        var fileSavingTooLittleForWhatItHides: (file: String, saving: Int)? {
            let windowed = Dictionary(grouping: calls.filter(\.weighsWindow)) { $0.displayTarget ?? $0.target }
            for (name, file) in windowed.sorted(by: { $0.key < $1.key }) {
                let hides = !file.allSatisfy { $0.windowText.isEmpty || InPlaceAnswer.answer(answer, showsRunOf: $0.windowText) }
                let saving = file.reduce(0) { $0 + ($1.source ?? 0) - $1.served }
                if hides, saving < InPlaceAnswer.windowSavingFloor {
                    return (name, max(0, saving))
                }
            }
            return nil
        }

        /// The source the answer stands in for, where every call weighed its own: their sum.
        var source: Int? {
            let weighed = calls.compactMap(\.source)
            return !weighed.isEmpty && weighed.count == calls.count ? weighed.reduce(0, +) : nil
        }
    }

    enum Computation: Sendable {
        /// The answer, a bounded one to hand over in its place where it is over the size budget, and where no bounded one stands in, its first page cut to fit.
        case answer(Computed, bounded: Computed? = nil, cut: Computed? = nil)
        case withheld(Withholding)
    }

    /// Where the detached computation leaves its result for the thread waiting on it.
    final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Computation, any Error>?

        var value: Result<Computation, any Error>? {
            lock.withLock { result }
        }

        func store(_ result: Result<Computation, any Error>) {
            lock.withLock { self.result = result }
        }
    }
}
