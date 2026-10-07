//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// `--verdict`'s terse line, for a probe that would otherwise parse `permissionDecisionReason`'s prose: the same decision `respond` already makes, named in one tab-separated line instead of JSON — and unchanged by the flag's mere existence, since `respond` itself is still exactly what `outcome` returns the `json` half of.
@Suite(.temporaryDirectories)
struct PreToolUseVerdictTests {
    private static var command: String {
        #"grep -n 'static\|case ' Sources/App/Depot.swift"#
    }

    private static func lookup(sourceLocation: SourceLocation = #_sourceLocation) throws -> PreToolUseCommand.Lookup {
        try #require(try PreToolUseCommand.lookup(
            command: command,
            payload: [:],
            in: "/repo",
            noting: SuppressionLog(fileURL: TemporaryDirectory.make("ignored").appendingPathComponent("ignored.jsonl")),
            couldAnswer: { _, _ in true }
        ), sourceLocation: sourceLocation)
    }

    private static func outcome(
        _ lookup: PreToolUseCommand.Lookup,
        in stores: Stores,
        answerer: (InPlaceShape.Match, Bool) -> InPlaceAnswerer.Outcome
    ) -> (json: String?, verdict: PreToolUseCommand.Verdict) {
        PreToolUseCommand.outcome(
            to: lookup,
            session: "s1",
            context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: "a1"),
            payload: ["agent_id": "a1"],
            cwd: "/repo",
            ledger: stores.ledger,
            usage: UsageLog(fileURL: stores.usageLog),
            suppressions: SuppressionLog(fileURL: stores.suppressionLog),
            answerer: { match, gone, _ in answerer(match, gone) }
        )
    }

    /// An answer the hook could hand back, for the one outcome that still denies.
    private static var answered: InPlaceAnswerer.Answered {
        InPlaceAnswerer.Answered(
            reason: "answered",
            calls: [InPlaceAnswerer.Call(tool: "digest", target: "Sources/App/Depot.swift", bytes: AnswerBytes(served: 1, source: 2))],
            root: "/repo",
            milliseconds: 1
        )
    }

    /// Every ledger state file the hook wrote under `stores`, decoded — found by listing rather than by spelling the session key, which is the ledger's own business.
    private static func ledgerStates(in stores: Stores) throws -> [AdviceLedger.State] {
        let advice = stores.directory.appendingPathComponent("advice")
        let files = (try? FileManager.default.contentsOfDirectory(at: advice, includingPropertiesForKeys: nil)) ?? []
        return try files.filter { $0.pathExtension == "json" }.map {
            try JSONDecoder().decode(AdviceLedger.State.self, from: Data(contentsOf: $0))
        }
    }

    /// `respond` is unaffected by `--verdict` existing at all: it is the same computation's `json` half, run once each on two ledgers of its own (the ledger's decision is a write, so a second call on the same one would see the first's re-run allowance rather than repeat the same decision).
    @Test
    func respondIsExactlyTheJSONHalfOfOutcome() throws {
        let viaRespond = try PreToolUseCommand.respond(
            to: Self.lookup(),
            session: "s1",
            context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: "a1"),
            payload: ["agent_id": "a1"],
            cwd: "/repo",
            ledger: Stores().ledger,
            usage: UsageLog(fileURL: Stores().usageLog),
            suppressions: SuppressionLog(fileURL: Stores().suppressionLog)
        ) { _, _, _ in .answered(Self.answered) }

        let viaOutcome = try Self.outcome(Self.lookup(), in: Stores()) { _, _ in .answered(Self.answered) }.json

        #expect(viaRespond == viaOutcome)
        #expect(viaRespond != nil)
    }

    /// A lookup with no answer in it — no in-place attempt is ever made, because the classifying advisor offers none for a `Grep` of one named file — is let through, and the rule says which allow it is.
    ///
    /// Nothing is printed and no call is named: a refusal naming a call costs a round trip worth several times what that call could have saved, so the command runs and the miss is left to the transcript scan to count. The rule is `notAnswerable` rather than the advisor's own tag, because what decided is that there was no answer to give, not which advisor found the lookup — and it is noted in the suppression log under that name, so the rate is visible.
    @Test
    func aLookupWithNoAnswerInItIsLetThroughAndNamedAsSuch() throws {
        let stores = try Stores()
        let lookup = try #require(PreToolUseCommand.lookup(
            command: nil,
            payload: ["tool_name": "Grep", "tool_input": ["output_mode": "content", "pattern": #"static\|case "#, "path": "Sources/App/Depot.swift"]],
            in: "/repo",
            noting: SuppressionLog(fileURL: stores.suppressionLog),
            couldAnswer: { _, _ in true }
        ))
        let outcome = Self.outcome(lookup, in: stores) { _, _ in .withheld(.notExact) }

        #expect(outcome.json == nil)
        #expect(outcome.verdict.token == "allowed")
        #expect(outcome.verdict.call == nil)
        #expect(outcome.verdict.rule == "notAnswerable")
        #expect(outcome.verdict.line == "allowed\t\tnotAnswerable")
        #expect(try Self.lines(of: stores.suppressionLog).contains { $0["rule"] as? String == "notAnswerable" })
    }

    /// An in-place answer names the call its own opening line names — the file path, not the suggestion's shorter `digest Depot` — and the advisor that made it answerable in place.
    @Test
    func anInPlaceAnswerNamesTheCallAndTheAdvisor() throws {
        let stores = try Stores()
        let answered = InPlaceAnswerer.Answered(
            reason: InPlaceAnswer.openingLine(calls: ["digest Sources/App/Depot.swift"], wholeCommand: true, lookups: 1) + "\n\nbody\n\n",
            calls: [InPlaceAnswerer.Call(tool: "digest", target: "Sources/App/Depot.swift", bytes: AnswerBytes(served: 1, source: 2))],
            root: "/repo",
            milliseconds: 1
        )
        let outcome = try Self.outcome(Self.lookup(), in: stores) { _, _ in .answered(answered) }

        #expect(outcome.verdict.token == "in-place")
        #expect(outcome.verdict.call == "digest Sources/App/Depot.swift")
        #expect(outcome.verdict.rule == "ShellAdvice")
    }

    /// A single lookup whose answer covers several matches — a grep of one file hitting more than one declaration — names only the first call its offer made, with how many more the same answer served: a probe reading the line as the whole answer would otherwise believe the rest went unanswered.
    @Test
    func aSeveralMatchAnswerNamesTheFirstCallAndHowManyMore() throws {
        let stores = try Stores()
        let answered = InPlaceAnswerer.Answered(
            reason: "answered",
            calls: (1 ... 11).map {
                InPlaceAnswerer.Call(tool: "digest", target: "Sources/App/Depot.swift:\($0)", bytes: AnswerBytes(served: 1, source: 2))
            },
            root: "/repo",
            milliseconds: 1
        )
        let outcome = try Self.outcome(Self.lookup(), in: stores) { _, _ in .answered(answered) }

        #expect(outcome.verdict.call == "digest Depot (+10 more)")
    }

    /// Several whole reads answered together fold the same way a single call's line does: a control character in a call is folded to a space, so the tab-delimited `--verdict` line stays one record, and the calls are joined exactly as the reason's own opening line names them — never rebuilt as bare `tool target` pairs that skip the fold.
    @Test
    func aMultiReadVerdictLineFoldsAsTheSingleCallLineDoes() throws {
        let stores = try Stores()
        let command = "cat Sources/App/Depot.swift; cat Sources/App/Gizmo.swift"
        let lookup = try #require(PreToolUseCommand.lookup(
            command: command,
            payload: [:],
            in: "/repo",
            noting: SuppressionLog(fileURL: stores.suppressionLog),
            couldAnswer: { _, _ in true }
        ))
        #expect((lookup.inPlace?.calls.count ?? 0) > 1)
        let calls = ["digest Sources/App/Depot.swift", "digest Sources/App/Gi\tzmo.swift"]
        let reason = InPlaceAnswer.openingLine(calls: calls, wholeCommand: true, lookups: 2) + "\n\nbody\n\n"
        let answered = InPlaceAnswerer.Answered(
            reason: reason,
            calls: [
                InPlaceAnswerer.Call(tool: "digest", target: "Sources/App/Depot.swift", bytes: AnswerBytes(served: 1, source: 2)),
                InPlaceAnswerer.Call(tool: "digest", target: "Sources/App/Gizmo.swift", bytes: AnswerBytes(served: 1, source: 2)),
            ],
            root: "/repo",
            milliseconds: 1
        )
        let outcome = Self.outcome(lookup, in: stores) { _, _ in .answered(answered) }

        #expect(outcome.verdict.call == "digest Sources/App/Depot.swift; digest Sources/App/Gi zmo.swift")
    }

    /// Once the server is gone, a reason built from Bash-spelled calls (``InPlaceAnswerer/Call/spelled(serverGone:)``) names them in the verdict line exactly as it names an MCP-spelled reason — a pinning test: the behaviour already holds, so there is no negative gate for it.
    @Test
    func aMultiReadVerdictLineSpellsTheBashCallsTheReasonNames() throws {
        let stores = try Stores()
        let command = "cat Sources/App/Depot.swift; cat Sources/App/Gizmo.swift"
        let lookup = try #require(PreToolUseCommand.lookup(
            command: command,
            payload: [:],
            in: "/repo",
            noting: SuppressionLog(fileURL: stores.suppressionLog),
            couldAnswer: { _, _ in true }
        ))
        let calls = ["sift digest Sources/App/Depot.swift", "sift digest Sources/App/Gizmo.swift"]
        let reason = InPlaceAnswer.openingLine(calls: calls, wholeCommand: true, lookups: 2) + "\n\nbody\n\n"
        let answered = InPlaceAnswerer.Answered(
            reason: reason,
            calls: [
                InPlaceAnswerer.Call(tool: "digest", target: "Sources/App/Depot.swift", bytes: AnswerBytes(served: 1, source: 2)),
                InPlaceAnswerer.Call(tool: "digest", target: "Sources/App/Gizmo.swift", bytes: AnswerBytes(served: 1, source: 2)),
            ],
            root: "/repo",
            milliseconds: 1
        )
        let outcome = Self.outcome(lookup, in: stores) { _, _ in .answered(answered) }

        #expect(outcome.verdict.call == "sift digest Sources/App/Depot.swift; sift digest Sources/App/Gizmo.swift")
    }

    /// A whole read of a Markdown document above the floor reaches the answerer as the document's outline, and the verdict names the `digest` call on the document's own path under the advisor that classified it.
    @Test
    func aReadOfADocumentIsAnsweredInPlaceAsAnOutline() throws {
        let stores = try Stores()
        let document = try MCPTestRepo.make(declaring: "Alpha").appendingPathComponent("Docs/Plan.md")
        try FileManager.default.createDirectory(at: document.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = (1 ... 8).flatMap { section in
            ["## Section \(section)", ""] + (1 ... 20).map { "Paragraph \($0) of section \(section), at the length a real note runs to." } + [""]
        }
        try (["# Plan", ""] + body).joined(separator: "\n").write(to: document, atomically: true, encoding: .utf8)
        let lookup = try #require(PreToolUseCommand.lookup(
            command: nil,
            payload: ["tool_name": "Read", "tool_input": ["file_path": document.path]],
            in: "/repo",
            noting: SuppressionLog(fileURL: stores.suppressionLog),
            couldAnswer: { _, _ in true }
        ))
        let outcome = Self.outcome(lookup, in: stores) { _, _ in .answered(Self.answered) }

        #expect(lookup.inPlace?.call == .documentOutline(path: document.path))
        #expect(outcome.verdict.line == "in-place\tdigest \(document.path)\tReadAdvice")
    }

    /// A withheld in-place attempt allows the call and names why the answer was withheld — the more specific fact of the two — in place of the advisor tag, and spends nothing on the ledger.
    ///
    /// An overrun is the case the budget exists for, and the outcome it resolves to is the command running as it would have without the hook. Nothing was said, so nothing was charged: no key in `denied` (there is no re-run to promise, the command ran) and no refusal counted against the context.
    @Test
    func aWithheldInPlaceAttemptAllowsTheCallAndNamesWhy() throws {
        let stores = try Stores()
        let outcome = try Self.outcome(Self.lookup(), in: stores) { _, _ in .withheld(.overTime) }

        #expect(outcome.json == nil)
        #expect(outcome.verdict.token == "allowed")
        #expect(outcome.verdict.rule == InPlaceAnswerer.Withholding.overTime.rawValue)
        let states = try Self.ledgerStates(in: stores)
        #expect(states.allSatisfy { $0.denied.isEmpty && $0.nudges == 0 })
    }

    /// The answer in place is the one outcome that still denies, so it is the one the ledger records: the key goes into `denied`, which is what the identical re-run the answer offers is allowed on.
    @Test
    func anAnswerInPlaceIsTheOneOutcomeTheLedgerRecords() throws {
        let stores = try Stores()
        let lookup = try Self.lookup()

        let answered = Self.outcome(lookup, in: stores) { _, _ in .answered(Self.answered) }
        let rerun = Self.outcome(lookup, in: stores) { _, _ in .answered(Self.answered) }

        #expect(answered.verdict.token == "in-place")
        let states = try Self.ledgerStates(in: stores)
        #expect(states.contains { $0.denied.contains(AdviceLedger.key(for: lookup.key)) })
        #expect(states.contains { $0.nudges == 1 })
        #expect(rerun.json == nil)
        #expect(rerun.verdict.line == "allowed\t\tledger")
    }

    /// The ledger's `allow` — the identical re-run a refusal promised — offers no call, but names the ledger as the rule: the one `allowed` a probe run without its own `--session` can be surprised by, so it has to read differently from a command that was never a lookup at all.
    @Test
    func aLedgerAllowNamesTheLedgerAsTheRule() throws {
        let stores = try Stores()
        let lookup = try Self.lookup()
        _ = Self.outcome(lookup, in: stores) { _, _ in .answered(Self.answered) }

        let outcome = Self.outcome(lookup, in: stores) { _, _ in .answered(Self.answered) }

        #expect(outcome.verdict.token == "allowed")
        #expect(outcome.verdict.call == nil)
        #expect(outcome.verdict.rule == "ledger")
        #expect(outcome.verdict.line == "allowed\t\tledger")
    }

    /// A ledger allow and a command that was never a lookup at all are both `allowed` tokens: the confusion `--verdict` exists to remove.
    ///
    /// The two lines must differ, and only the rule differs them.
    @Test
    func aLedgerAllowAndANonLookupAllowAreNotTheSameLine() throws {
        let stores = try Stores()
        let lookup = try Self.lookup()
        _ = Self.outcome(lookup, in: stores) { _, _ in .answered(Self.answered) }
        let ledgerAllow = Self.outcome(lookup, in: stores) { _, _ in .answered(Self.answered) }.verdict

        let notALookup = PreToolUseCommand.Verdict(token: "allowed", rule: "noLookup")

        #expect(ledgerAllow.line == "allowed\t\tledger")
        #expect(notALookup.line == "allowed\t\tnoLookup")
        #expect(ledgerAllow.line != notALookup.line)
    }

    /// The wrapping is the one bare refusal left: `RunAdvice` denies a toolchain run with its call, unlike a Swift lookup with no answer in it (``aLookupWithNoAnswerInItIsLetThroughAndNamedAsSuch``), and the identical re-run is allowed on the ledger, exactly as any other denial's re-run is.
    @Test
    func aToolchainRunIsStillDeniedWithItsWrapping() throws {
        let stores = try Stores()
        let lookup = try #require(PreToolUseCommand.lookup(
            command: "swift test",
            payload: [:],
            in: "/repo",
            noting: SuppressionLog(fileURL: stores.suppressionLog),
            couldAnswer: { _, _ in true }
        ))

        let outcome = Self.outcome(lookup, in: stores) { _, _ in .withheld(.notExact) }

        #expect(outcome.json != nil)
        #expect(outcome.verdict.token == "deny")
        #expect(outcome.verdict.call == "sift run -- swift test")
        #expect(outcome.verdict.rule == "RunAdvice")
        #expect((outcome.json ?? "").contains("sift run -- swift test"))

        let rerun = Self.outcome(lookup, in: stores) { _, _ in .withheld(.notExact) }
        #expect(rerun.verdict.token == "allowed")
        #expect(rerun.verdict.rule == "ledger")
    }

    /// The measured sequence: a lookup answered, then that lookup with a new one behind it answered about the new one, and that line run again allowed — a second lookup never inherits the first one's allowance, and the answer never re-sends the first one's.
    @Test
    func aNewLookupBehindAnAllowedOneIsAnsweredAsItself() throws {
        let stores = try Stores()
        let first = #"grep -n 'static\|case ' Sources/App/Depot.swift"#
        let second = #"grep -n 'static\|case ' Sources/App/Gadget.swift"#
        let line = "\(first) && \(second)"

        var aloneAbout = ""
        let alone = try Self.step(first, in: stores, answeredAbout: &aloneAbout)
        #expect(alone.verdict.token == "in-place")
        #expect(aloneAbout.contains("Depot.swift"))

        var compoundAbout = ""
        let compound = try Self.step(line, in: stores, answeredAbout: &compoundAbout)
        #expect(compound.key == second)
        #expect(compound.verdict.token == "in-place")
        #expect(compound.verdict.call?.contains("Gadget") == true)
        #expect(compoundAbout.contains("Gadget.swift") && !compoundAbout.contains("Depot.swift"))

        let again = try Self.step(line, in: stores)
        #expect(again.verdict.token == "allowed")
        #expect(again.verdict.rule == "ledger")
    }

    /// A run of denied wrappings in one context does not quiet the next: the run-based quiet spell is gone, and only the runaway cap opens one.
    @Test
    func twentyDeniedWrappingsStillLeaveTheTwentyFirstDenied() throws {
        let stores = try Stores()
        let verdicts = try (0 ... 20).map { index in
            let lookup = try #require(PreToolUseCommand.lookup(
                command: "swift test --filter F\(index)",
                payload: [:],
                in: "/repo",
                noting: SuppressionLog(fileURL: stores.suppressionLog),
                couldAnswer: { _, _ in true }
            ))
            return Self.outcome(lookup, in: stores) { _, _ in .withheld(.notExact) }.verdict.token
        }

        #expect(verdicts == Array(repeating: "deny", count: 21))
    }

    /// An allow reads no transcript: whether the server has left the context is asked only by an outcome that spells a call for it, and `notAnswerable` and the ledger's `allowed` spell none.
    @Test
    func anAllowNeverReadsTheTranscript() throws {
        let stores = try Stores()
        var reads = 0
        let outcome = { (lookup: PreToolUseCommand.Lookup) in
            PreToolUseCommand.outcome(
                to: lookup,
                session: "s1",
                context: AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: "a1"),
                payload: ["agent_id": "a1", "transcript_path": "/nowhere.jsonl"],
                cwd: "/repo",
                ledger: stores.ledger,
                usage: UsageLog(fileURL: stores.usageLog),
                suppressions: SuppressionLog(fileURL: stores.suppressionLog),
                answerer: { _, _, _ in .answered(Self.answered) },
                serverPresence: { _, _ in
                    reads += 1
                    return false
                }
            ).verdict
        }
        let notAnswerable = try #require(PreToolUseCommand.lookup(
            command: nil,
            payload: ["tool_name": "Grep", "tool_input": ["output_mode": "content", "pattern": #"static\|case "#, "path": "Sources/App/Depot.swift"]],
            in: "/repo",
            noting: SuppressionLog(fileURL: stores.suppressionLog),
            couldAnswer: { _, _ in true }
        ))

        #expect(outcome(notAnswerable).rule == "notAnswerable")
        #expect(reads == 0)

        let answerable = try Self.lookup()
        #expect(outcome(answerable).token == "in-place")
        #expect(reads == 1)
        #expect(outcome(answerable).line == "allowed\t\tledger")
        #expect(reads == 1)
    }

    /// A line whose every lookup has already been answered is allowed, as the re-run of any one of them is.
    @Test
    func aLineOfLookupsAllAlreadyAllowedIsAllowed() throws {
        let stores = try Stores()
        let first = #"grep -n 'static\|case ' Sources/App/Depot.swift"#
        let second = #"grep -n 'static\|case ' Sources/App/Gadget.swift"#

        #expect(try Self.step(first, in: stores).verdict.token == "in-place")
        #expect(try Self.step(second, in: stores).verdict.token == "in-place")
        let both = try Self.step("\(first); \(second)", in: stores)
        #expect(both.verdict.token == "allowed")
        #expect(both.verdict.rule == "ledger")
    }

    /// A compound line of several whole reads is answered in place under one key, and its identical re-run is one ask, not one refusal per read behind the first: the ledger has to remember every read the answer covered, not only the one it was filed under.
    @Test
    func aCompoundLineOfWholeReadsIsOneAskOnItsIdenticalReRun() throws {
        let stores = try Stores()
        let first = "cat Sources/App/Depot.swift"
        let second = "cat Sources/App/Gadget.swift"
        let line = "\(first) && \(second)"

        let answered = try Self.step(line, in: stores)
        #expect(answered.verdict.token == "in-place")

        let rerun = try Self.step(line, in: stores)
        #expect(rerun.verdict.token == "allowed")
        #expect(rerun.verdict.rule == "ledger")
    }

    /// A line of one lookup never asks the ledger which keys it allows: there is no choice to make, so its key, its answer and its record are exactly what they were.
    @Test
    func aLineOfOneLookupNeverAsksWhichKeysAreAllowed() throws {
        var asked = 0
        let lookup = try #require(PreToolUseCommand.lookup(
            command: "echo checking && \(Self.command)",
            payload: [:],
            in: "/repo",
            noting: SuppressionLog(fileURL: TemporaryDirectory.make("ignored").appendingPathComponent("ignored.jsonl")),
            couldAnswer: { _, _ in true },
            allowed: { _ in
                asked += 1
                return []
            }
        ))

        #expect(asked == 0)
        #expect(lookup.key == Self.command)
    }

    /// A lookup answered in front of a `||` whose fallback is a lookup too is re-run on the ledger, like every other answered line: the fallback never ran, so it is not a new lookup the re-run asks about.
    @Test
    func theRerunOfALookupAnsweredInFrontOfAFallbackLookupIsAllowedOnTheLedger() throws {
        let stores = try Stores()
        // A tree holding Swift source, so the fallback's search is a lookup of the line's too.
        let root = try TemporaryDirectory.make("fallback-tree")
        let file = root.appendingPathComponent("Sources/App/Depot.swift")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "struct Depot {\n    func stock3() {}\n}\n".write(to: file, atomically: true, encoding: .utf8)
        let line = "grep -n 'func stock3()' Sources/App/Depot.swift || grep -rn stock3 Sources"

        let first = try Self.step(line, in: stores, from: root.path)
        #expect(first.verdict.token == "in-place")

        let again = try Self.step(line, in: stores, from: root.path)
        #expect(again.verdict.token == "allowed")
        #expect(again.verdict.rule == "ledger")
    }

    /// A compound line whose own answer is withheld, answered as its reads alone, is recorded under exactly those reads — never the name grep the reads dropped — and its identical re-run is let through rather than answered about the grep.
    @Test
    func aLineAnsweredAsItsReadsIsRecordedUnderThoseReadsAlone() throws {
        let stores = try Stores()
        let line = "grep -n stock3 Sources/App/Depot.swift; cat Sources/App/Gadget.swift; cat Sources/App/Gizmo.swift"
        let context = AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: "a1")
        func run(sourceLocation: SourceLocation = #_sourceLocation) throws -> PreToolUseCommand.Verdict {
            let lookup = try #require(PreToolUseCommand.lookup(
                command: line,
                payload: [:],
                in: "/repo",
                noting: SuppressionLog(fileURL: stores.suppressionLog),
                couldAnswer: { _, _ in true },
                allowed: { stores.ledger.rerunsAllowed(session: context.key, among: $0) }
            ), sourceLocation: sourceLocation)
            // The whole line is withheld, as it is where it runs over the size budget, and any other reading answered.
            return Self.outcome(lookup, in: stores) { match, _ in match.calls.count == 3 ? .withheld(.overTime) : .answered(Self.answered) }.verdict
        }

        #expect(try run().token == "in-place")
        let denied = try Self.ledgerStates(in: stores).flatMap(\.denied)
        #expect(Set(denied) == ["cat Sources/App/Gadget.swift", "cat Sources/App/Gizmo.swift"])

        #expect(try run().token == "allowed")
    }
}

private extension PreToolUseVerdictTests {
    /// One call through the hook as `run` makes it — classified against the ledger's allowed keys, then decided — with an answerer that answers whatever it is handed, reporting the key and the verdict, and what the answer was about through its last argument.
    static func step(
        _ command: String,
        in stores: Stores,
        from directory: String = "/repo",
        answeredAbout: inout String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> (key: String, verdict: PreToolUseCommand.Verdict) {
        let context = AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: "a1")
        let lookup = try #require(PreToolUseCommand.lookup(
            command: command,
            payload: [:],
            in: directory,
            noting: SuppressionLog(fileURL: stores.suppressionLog),
            couldAnswer: { _, _ in true },
            allowed: { stores.ledger.rerunsAllowed(session: context.key, among: $0) }
        ), sourceLocation: sourceLocation)
        var about = ""
        let verdict = outcome(lookup, in: stores) { match, _ in
            about = String(describing: match.calls)
            return .answered(answered)
        }.verdict
        answeredAbout = about
        return (lookup.key, verdict)
    }

    /// The same, where what the answer was about does not matter.
    static func step(
        _ command: String,
        in stores: Stores,
        from directory: String = "/repo",
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> (key: String, verdict: PreToolUseCommand.Verdict) {
        var ignored = ""
        return try step(command, in: stores, from: directory, answeredAbout: &ignored, sourceLocation: sourceLocation)
    }
}

private extension PreToolUseVerdictTests {
    /// Everything the hook writes, somewhere this test owns.
    struct Stores {
        let directory: URL

        init() throws {
            directory = try TemporaryDirectory.make("verdict").appendingPathComponent("verdict")
        }

        var ledger: AdviceLedger {
            AdviceLedger(directory: directory.appendingPathComponent("advice"))
        }

        var usageLog: URL {
            directory.appendingPathComponent("usage.jsonl")
        }

        var suppressionLog: URL {
            directory.appendingPathComponent("suppressions.jsonl")
        }
    }
}

private extension PreToolUseVerdictTests {
    /// The JSON lines a log this test owns holds.
    static func lines(of url: URL) throws -> [[String: Any]] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }
}
