//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// Covers the rules that stop the hook spending a round trip to say nothing — an offer this context has already taken up, a pipeline whose output a later stage filters — and the one that used to and no longer does: a repository carrying no index of its own, which silenced the hook in every tree an isolated agent works in.
///
/// Each is pinned at the level that decides — the ledger for the first, the classifier's gates for the rest — because what they cost is a whole turn each, and a suggestion built correctly and then refused anyway is indistinguishable from a suggestion never built, from anywhere further out.
@Suite(.temporaryDirectories)
struct RefusalsThatBuyNothingTests {
    private static func ledger(in directory: URL) -> AdviceLedger {
        AdviceLedger(directory: directory)
    }

    /// The shape this rule was written for: the one question the index cannot be asked is whether the index is right.
    ///
    /// A context that ran `where SimilarTarget`, got an empty answer and reached for a grep to find out why is offered `where SimilarTarget` back — the very call whose answer is the thing under investigation.
    @Test
    func anOfferThisContextHasAlreadyMadeIsNotMadeAgain() throws {
        let directory = try TemporaryDirectory.make("bought-nothing")
        let ledger = Self.ledger(in: directory)

        ledger.noteIndexCall(session: "s", calls: ["where SimilarTarget"])

        #expect(ledger.decide(session: "s", command: "grep -rn SimilarTarget Sources", offering: ["where SimilarTarget"]) == .allow)
        // And the call it has *not* made is still worth interrupting for, in the same context and on the
        // strength of the same evidence: what is remembered is the call, never the symbol's neighbourhood.
        #expect(ledger.decide(session: "s", command: "grep -rn SimilarHit Sources", offering: ["where SimilarHit"]) == .advise)
    }

    /// A different call standing on a name already looked up is news, and treating the symbol as the unit would lose exactly the case the hook is for: digest to locate, then ask who calls it.
    @Test
    func aDifferentCallOnTheSameSymbolIsStillOffered() throws {
        let directory = try TemporaryDirectory.make("bought-nothing")
        let ledger = Self.ledger(in: directory)

        ledger.noteIndexCall(session: "s", calls: ["digest SimilarTarget"])

        #expect(ledger.decide(session: "s", command: "grep -rn SimilarTarget Sources", offering: ["where SimilarTarget"]) == .advise)
    }

    /// An offer of several calls says nothing new only when every one of them has been made; answered in part, it still carries the part that was not.
    @Test
    func anOfferAnsweredInPartIsStillMade() throws {
        let directory = try TemporaryDirectory.make("bought-nothing")
        let ledger = Self.ledger(in: directory)

        ledger.noteIndexCall(session: "s", calls: ["where SimilarTarget"])

        #expect(ledger.decide(
            session: "s",
            command: "grep -rn 'SimilarTarget|SimilarHit' Sources",
            offering: ["where SimilarTarget", "where SimilarHit"]
        ) == .advise)
    }

    /// The whole path, from the payload of an index call to the verdict on a grep the same context runs afterwards — which is where the two spellings have to meet, and the only place a mismatch between them would show.
    @Test
    func theHookAllowsAGrepItWouldAnswerWithACallTheContextAlreadyMade() throws {
        let directory = try TemporaryDirectory.make("bought-nothing")
        let ledger = Self.ledger(in: directory)
        let context = AdviceContext.resolve(sessionID: "s", transcriptPath: nil)
        let usage = UsageLog(fileURL: directory.appendingPathComponent("usage.jsonl"))
        let noted = SuppressionLog(fileURL: directory.appendingPathComponent("suppressions.jsonl"))
        let callers = CallAttribution(directory: directory.appendingPathComponent("callers", isDirectory: true))
        let taken: [String: Any] = [
            "tool_name": "\(IndexToolName.prefix)where",
            "tool_input": ["symbol": "SimilarTarget"],
        ]

        _ = PreToolUseCommand.adviceTaken(
            session: "s",
            context: context,
            payload: taken,
            cwd: nil,
            ledger: ledger,
            callers: callers
        )

        let answered = try #require(PreToolUseCommand.lookup(
            command: #"grep -rn "SimilarTarget" Sources"#,
            payload: [:],
            in: FileManager.default.currentDirectoryPath,
            noting: noted,
            couldAnswer: { _, _ in true }
        ))
        #expect(answered.suggestion.call == "where SimilarTarget")
        let verdict = PreToolUseCommand.outcome(
            to: answered,
            session: "s",
            context: context,
            payload: [:],
            cwd: nil,
            ledger: ledger,
            usage: usage,
            suppressions: noted
        )
        #expect(verdict.json == nil)
        #expect(verdict.verdict.token == "allowed")

        // The same context, a lookup the hook answers with a call it has not made: refused as ever.
        let fresh = try #require(PreToolUseCommand.lookup(
            command: #"grep -rn "SimilarHit" Sources"#,
            payload: [:],
            in: FileManager.default.currentDirectoryPath,
            noting: noted,
            couldAnswer: { _, _ in true }
        ))
        let refused = PreToolUseCommand.outcome(
            to: fresh,
            session: "s",
            context: context,
            payload: [:],
            cwd: nil,
            ledger: ledger,
            usage: usage,
            suppressions: noted
        )
        // Both outcomes are `allowed` now — the hook answers in place or lets the call through — so what
        // tells rule 1's allow from an ordinary one is the rule: `ledger` only where the offer bought nothing.
        #expect(refused.verdict.rule != "ledger")
    }

    /// A call is named by the key its own tool reads, not by an unrelated argument riding beside it: `where symbol:A target:B` resolves `A`, and the record of that call must say so — never the `target` it never looked at.
    @Test
    func aCallIsNamedByTheKeyItsOwnToolRead() {
        let calls = IndexSuggestion.callsMade(
            toolName: "\(IndexToolName.prefix)where",
            input: ["symbol": "ShardMerge", "target": "RunLauncher"],
            root: nil
        )

        #expect(calls == ["where ShardMerge"])
    }

    /// A call recorded against one repository does not silence the offer of the same call in a different one — rule 1's premise is that the offer is *circular*, and a call answered from another tree never answered this one.
    @Test
    func aCallRecordedAgainstOneRootDoesNotSilenceItInAnother() throws {
        let directory = try TemporaryDirectory.make("bought-nothing")
        let ledger = Self.ledger(in: directory)
        let context = AdviceContext.resolve(sessionID: "s", transcriptPath: nil)
        let usage = UsageLog(fileURL: directory.appendingPathComponent("usage.jsonl"))
        let noted = SuppressionLog(fileURL: directory.appendingPathComponent("suppressions.jsonl"))
        let callers = CallAttribution(directory: directory.appendingPathComponent("callers", isDirectory: true))
        let checkout = FileManager.default.currentDirectoryPath
        let otherRepo = try TemporaryDirectory.make("other-repo")
        try FileManager.default.createDirectory(at: otherRepo.appendingPathComponent(".git"), withIntermediateDirectories: true)

        // `where` is made against a different repository entirely.
        _ = PreToolUseCommand.adviceTaken(
            session: "s",
            context: context,
            payload: [
                "tool_name": "\(IndexToolName.prefix)where",
                "tool_input": ["symbol": "ShardMerge", "root": otherRepo.path],
            ],
            cwd: nil,
            ledger: ledger,
            callers: callers
        )

        // A grep for the same symbol in this checkout is a question that call never answered.
        let inCheckout = try #require(PreToolUseCommand.lookup(
            command: #"grep -rn "ShardMerge" Sources"#,
            payload: [:],
            in: checkout,
            noting: noted,
            couldAnswer: { _, _ in true }
        ))
        let deniedAcrossRepos = PreToolUseCommand.outcome(
            to: inCheckout, session: "s", context: context, payload: [:], cwd: nil,
            ledger: ledger, usage: usage, suppressions: noted
        )
        #expect(deniedAcrossRepos.verdict.rule != "ledger")

        // The same `where`, this time amended to the checkout the grep actually runs in: now circular, and allowed.
        _ = PreToolUseCommand.adviceTaken(
            session: "s",
            context: context,
            payload: [
                "tool_name": "\(IndexToolName.prefix)where",
                "tool_input": ["symbol": "ShardMerge", "root": checkout],
            ],
            cwd: nil,
            ledger: ledger,
            callers: callers
        )
        let sameCheckout = try #require(PreToolUseCommand.lookup(
            command: #"grep -rn "ShardMerge" Sources"#,
            payload: [:],
            in: checkout,
            noting: noted,
            couldAnswer: { _, _ in true }
        ))
        let allowedInSameTree = PreToolUseCommand.outcome(
            to: sameCheckout, session: "s", context: context, payload: [:], cwd: nil,
            ledger: ledger, usage: usage, suppressions: noted
        )
        #expect(allowedInSameTree.verdict.token == "allowed")

        // And a grep for a different symbol in that same checkout is still news.
        let differentSymbol = try #require(PreToolUseCommand.lookup(
            command: #"grep -rn "Depot" Sources"#,
            payload: [:],
            in: checkout,
            noting: noted,
            couldAnswer: { _, _ in true }
        ))
        let deniedForDifferentSymbol = PreToolUseCommand.outcome(
            to: differentSymbol, session: "s", context: context, payload: [:], cwd: nil,
            ledger: ledger, usage: usage, suppressions: noted
        )
        #expect(deniedForDifferentSymbol.verdict.rule != "ledger")
    }

    /// A path-bearing search aimed explicitly at another checkout is refused whatever the caller's own cwd happens to be, and its anchor names that checkout — which is what roots the offer on the tree the search is actually pointed at rather than on wherever the session's shell is standing.
    @Test
    func aPathBearingSearchAimedAtAnotherRepositoryIsAnchoredOnIt() throws {
        let indexed = try TemporaryDirectory.make("indexed-target")
        try FileManager.default.createDirectory(at: indexed.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let cache = SiftPaths.cache(in: indexed)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data().write(to: cache.appendingPathComponent(SiftPaths.indexFileName))
        let sources = indexed.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data("struct Gizmo {}\n".utf8).write(to: sources.appendingPathComponent("Gizmo.swift"))

        // A reviewer's own worktree: a repository of its own, but never built or queried, so it carries no
        // index — the everyday shape, and not merely a loose directory.
        let unindexedCwd = try TemporaryDirectory.make("unindexed-cwd")
        try FileManager.default.createDirectory(at: unindexedCwd.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let noted = SuppressionLog(fileURL: unindexedCwd.appendingPathComponent("suppressions.jsonl"))

        let grep = try #require(PreToolUseCommand.lookup(
            command: nil,
            payload: ["tool_name": "Grep", "tool_input": ["output_mode": "content", "pattern": "ShardMerge", "path": sources.path]],
            in: unindexedCwd.path,
            noting: noted,
            couldAnswer: { _, _ in true }
        ))
        #expect(grep.anchor == sources.path)

        let shellGrep = try #require(PreToolUseCommand.lookup(
            command: "grep -rn ShardMerge \(sources.path)",
            payload: [:],
            in: unindexedCwd.path,
            noting: noted,
            couldAnswer: { _, _ in true }
        ))
        #expect(shellGrep.anchor == sources.path)
    }

    /// A ledger written before the record of what a context asked existed must decode as the state it still has: losing `denied` would refuse a whole run of commands this context has already been refused.
    @Test
    func aLedgerFromBeforeTheCallsItRecordsStillLoads() throws {
        let directory = try TemporaryDirectory.make("bought-nothing")
        let ledger = Self.ledger(in: directory)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let older = """
        {"denied":["grep -n foo A.swift"],"nudges":3,"unheededRun":2,"quiets":0,"refusals":3,\
        "reached":true,"diagnosed":false}
        """
        try Data(older.utf8).write(to: directory.appendingPathComponent("s.json"))

        #expect(ledger.decide(session: "s", command: "grep -n foo A.swift") == .allow)
        // The new field defaulted to empty, so an offer is still an offer: nothing was decoded that could
        // make this context look as though it had already asked.
        #expect(ledger.decide(session: "s", command: "grep -rn SimilarTarget Sources", offering: ["where SimilarTarget"]) == .advise)
    }

    /// A repository with no index of its own draws the nudge like any other, and the index is built on demand by whatever answers.
    ///
    /// *No index, no nudge* used to withhold here, under `unindexedTree`. It silenced the hook for every isolated subagent, each of which runs in a `.claude/worktrees/<agent>/` nothing has ever indexed, and the premise it stood on — that the offered call must index a whole checkout first — was measured in tenths of a second, not minutes (`Docs/Design.md`). So the lookup is returned, with the same offer an indexed repository would draw, and nothing is withheld to log.
    @Test
    func aReadInARepositoryWithNoIndexIsRefusedLikeAnyOther() throws {
        let repository = try TemporaryDirectory.make("unindexed")
        let sources = repository.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        // A `.git` of its own is what makes this a repository rather than a loose directory, and a linked
        // worktree carries it as a file — which is the shape the old rule was written for.
        try Data("gitdir: /elsewhere\n".utf8).write(to: repository.appendingPathComponent(".git"))
        let file = sources.appendingPathComponent("Gizmo.swift")
        let body = (1 ... 80).map { "    let value\($0) = \($0)" }.joined(separator: "\n")
        try Data("struct Gizmo {\n\(body)\n}\n".utf8).write(to: file)

        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }
        let noted = recording.log
        let payload: [String: Any] = ["tool_name": "Read", "tool_input": ["file_path": file.path]]

        let unindexed = try #require(PreToolUseCommand.lookup(
            command: nil,
            payload: payload,
            in: repository.path,
            noting: noted,
            couldAnswer: { _, _ in true }
        ))
        #expect(unindexed.suggestion.call == "digest Gizmo")
        // Nothing was withheld, so nothing is logged: a rule that no longer fires must not leave a fire rate
        // behind for `Docs/Design.md`'s accounting to read.
        #expect(recording.rules.isEmpty)

        // The same read, once that repository has an index of its own: the identical offer.
        let cache = SiftPaths.cache(in: repository)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data().write(to: cache.appendingPathComponent(SiftPaths.indexFileName))

        let indexed = try #require(PreToolUseCommand.lookup(
            command: nil,
            payload: payload,
            in: repository.path,
            noting: noted,
            couldAnswer: { _, _ in true }
        ))
        #expect(indexed.suggestion.call == "digest Gizmo")
        #expect(recording.rules.isEmpty)
    }

    /// The whole hook in the tree the old rule silenced — a real repository nobody has indexed, which is what every isolated agent works in: the read is denied, and the index the answer needs is built on the way.
    ///
    /// Pinned through `respond` rather than at the classifier, because the claim is about the turn the hook spends: without the fix the lookup is never built, so there is no payload to deny with and the agent reads its whole run's Swift files unrefused.
    @Test
    func theHookDeniesAReadInAnUnindexedRepositoryAndIndexesItOnDemand() async throws {
        let repository = try MCPTestRepo.make(declaring: "Gizmo")
        let file = repository.appendingPathComponent("Sources/App/Gizmo.swift")
        let body = (1 ... 60).map { "    func value\($0)() -> Int {\n        let doubled = \($0) * 2\(WorthAnsweringFixture.comment)\n        return doubled + \($0)\n    }" }.joined(separator: "\n")
        try Data("struct Gizmo {\n\(body)\n}\n".utf8).write(to: file)
        #expect(!FileManager.default.fileExists(atPath: SiftPaths.cache(in: repository).path))

        let scratch = try TemporaryDirectory.make("hook-unindexed")
        let noted = SuppressionLog(fileURL: scratch.appendingPathComponent("suppressions.jsonl"))
        let payload: [String: Any] = ["tool_name": "Read", "tool_input": ["file_path": file.path]]

        let lookup = try #require(PreToolUseCommand.lookup(
            command: nil,
            payload: payload,
            in: repository.path,
            noting: noted
        ))
        // A budget and a back-off of this test's own: what is under test is that the answerer is reached and
        // builds what it needs, not how a second of it is spent on a machine running the rest of the suite.
        let backoff = InPlaceBackoff(directory: scratch.appendingPathComponent("backoff", isDirectory: true))
        // On a thread of its own: the answerer blocks its caller on work it hands the concurrency pool.
        let denial = await InPlaceAnswerTests.onItsOwnThread {
            PreToolUseCommand.respond(
                to: lookup,
                session: "unindexed",
                context: AdviceContext.resolve(sessionID: "unindexed", transcriptPath: nil),
                payload: ["tool_name": "Read", "tool_input": ["file_path": file.path]],
                cwd: repository.path,
                ledger: Self.ledger(in: scratch),
                usage: UsageLog(fileURL: scratch.appendingPathComponent("usage.jsonl")),
                suppressions: noted,
                answerer: { match, serverGone, _ in
                    InPlaceAnswerer.answer(
                        match.call,
                        from: match.directory,
                        serverGone: serverGone,
                        wholeCommand: match.isWholeCommand,
                        timeBudget: 60,
                        deadline: .unbounded,
                        backoff: backoff
                    )
                }
            )
        }

        let json = try #require(denial)
        #expect(json.contains("\"permissionDecision\":\"deny\""))
        // Whatever answered built the index it needed, in the repository the lookup itself named.
        #expect(FileManager.default.fileExists(
            atPath: SiftPaths.cache(in: repository).appendingPathComponent(SiftPaths.indexFileName).path
        ))
    }

    // MARK: - A reading stage behind a filter

    /// A read or search whose output a later stage of the same pipeline *filters* is let through, and scored out of the share by the scan on the same rule — `sort -u`, `cut -d:`, a second `grep`, an `awk` field.
    ///
    /// What the caller asked for is what that stage kept of the lines the read printed, and no index answer prints those lines for it to keep: `where`'s resolved sites are neither the text a `cut` takes a field out of nor the order a `sort` puts them in, and a digest is not the file a downstream `grep` is picking lines from. There is no answer to hand back in place either, and there never was — ``InPlaceShape`` answers a pipeline of two stages whose second is a `head` or a `tail` cut, and no other pipeline at all — so the refusal could only ever cost the round trip and buy nothing.
    ///
    /// Measured over two days of transcripts: 227 refusals cost 1,645,977 tokens of re-sent context, and 41 of them were followed by the identical command re-run — the hook refused, the context paid a full re-send, and the command ran anyway. Letting these through records the miss and keeps the tokens, which is the whole of the rule commit `599474be` established: never refuse a call no index answer could reproduce.
    @Test(arguments: [
        "grep -rn UsageWindow Sources --include=*.swift | sort -u",
        "grep -rn UsageWindow Sources --include=*.swift | cut -d: -f1",
        "grep -rn UsageWindow Sources --include=*.swift | grep -v Tests",
        "grep -rn UsageWindow Sources --include=*.swift | awk -F: '{print $1}'",
        "cat Sources/App/Depot.swift | grep -n stock | head -5",
        "sed -n '/stock/p' Sources/App/Depot.swift | sort -u",
        "awk 'NR>=10&&NR<=40' Sources/App/Depot.swift | cut -d: -f1",
    ])
    func aReadingStageBehindAFilterIsAllowedAndStillCountedAMiss(command: String) throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }

        #expect(Self.lookup(command, noting: recording.log) == nil, "\(command)")
        #expect(recording.rules == ["filteredOutput"], "\(command)")

        // Allowing is not forgetting: the scan scores the call out of the share under the same rule, on the
        // half that says the index records this and could have answered it — a name a pipeline's own filter
        // defeats, not a name the index never held — and never on the other.
        let tally = TranscriptFixture.tally([TranscriptFixture.toolUse("Bash", input: ["command": command])])
        #expect(tally.textSearches == 0, "\(command)")
        #expect(tally.withheldOnWorth == 1, "\(command)")
        #expect(tally.total == 0, "\(command)")
    }

    /// A line *window* after the read is not a filter and keeps its refusal: `head` prints the opening of the very answer the refusal offers, so the answer stands in for what the command would have shown and the hook hands it back in place.
    ///
    /// The control on the rule above. A widening that swallowed this would delete an answer rather than a useless nudge, which is the error this hook's rules are all biased against.
    @Test(arguments: [
        "grep -rnw UsageWindow Sources --include=*.swift | head -20",
        "grep -rnw UsageWindow Sources --include=*.swift | tail -5",
    ])
    func aWindowAfterTheReadKeepsTheAnswerItStandsFor(command: String) throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }

        #expect(Self.lookup(command, noting: recording.log)?.suggestion.call == "where UsageWindow", "\(command)")
        #expect(recording.rules.isEmpty, "\(command)")
        #expect(InPlaceShape.match(forShell: command, in: nil) != nil, "\(command)")
    }

    /// A line window on the file itself stays the ranged read it is while only windows follow it: `head` keeps some of the lines the window chose, and filters none, so the positional printer is not withheld as a filtered read.
    ///
    /// The control on widening the rule to every reading stage: a window piped into a `cut` is filtered, and the same window piped into a `head` must not be.
    @Test
    func aWindowOnTheFileBehindAWindowStaysAWindow() throws {
        let command = "sed -n '10,40p' Sources/App/Depot.swift | head -5"
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }

        #expect(Self.lookup(command, noting: recording.log)?.suggestion.call == "digest Depot")
        #expect(recording.rules.isEmpty)
        #expect(ShellInspection.windowedReadPath(command, holdsSource: nil) == "Sources/App/Depot.swift")
    }

    /// A stage that only passes the read's lines on is not a filter either, and the read keeps the verdict it gets unpiped: `| cat`, a pager, and a window writing to a file all print the answer the refusal offers, line for line.
    ///
    /// The other control on the rule, and the one its hard constraint rests on: no lookup the index *can* answer may be silenced. `where UsageWindow | cat` prints what `grep -rn UsageWindow Sources | cat` prints, so treating a `cat` as a filter would drop a nudge that costs nothing and buys the sweep.
    @Test(arguments: [
        "grep -rn UsageWindow Sources --include=*.swift | cat",
        "grep -rn UsageWindow Sources --include=*.swift | cat -n",
        "grep -rn UsageWindow Sources --include=*.swift | less",
        "grep -rn UsageWindow Sources --include=*.swift | more",
        "grep -rn UsageWindow Sources --include=*.swift | head -20 > out.txt",
    ])
    func aStageThatOnlyPassesTheLinesOnIsNotAFilter(command: String) throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }

        #expect(Self.lookup(command, noting: recording.log)?.suggestion.call == "where UsageWindow", "\(command)")
        #expect(recording.rules.isEmpty, "\(command)")
        // The verdict the unpiped command gets, which is the whole of what "not a filter" means here.
        #expect(Self.lookup("grep -rn UsageWindow Sources --include=*.swift", noting: recording.log)?.suggestion.call == "where UsageWindow")
    }

    /// The hook's classification of one shell command, against a probe that answers for every name, as `NeverRefusedShapesTests` asks it.
    private static func lookup(_ command: String, noting log: SuppressionLog) -> PreToolUseCommand.Lookup? {
        PreToolUseCommand.lookup(
            command: nil,
            payload: ["tool_name": "Bash", "tool_input": ["command": command]],
            in: nil,
            noting: log
        ) { _, _ in true }
    }
}
