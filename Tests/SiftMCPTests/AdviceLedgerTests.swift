//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// Covers the bounds that make refusing a command defensible: a retry always passes and spends no budget, the advice quiets itself when it is landing on nothing, and the quiet is a spell rather than a verdict.
@Suite(.temporaryDirectories)
struct AdviceLedgerTests {
    /// A ledger under a throwaway directory.
    static func temporary() throws -> Harness {
        let root = try TemporaryDirectory.make("advice")
        let advice = root.appendingPathComponent("advice", isDirectory: true)
        let clock = Clock(Date(timeIntervalSince1970: 2_000_000))
        return Harness(
            ledger: AdviceLedger(directory: advice, now: { clock.current }),
            clock: clock,
            adviceDirectory: advice,
            cleanup: { try? FileManager.default.removeItem(at: root) }
        )
    }

    /// One file per session and nothing ever removing them is how a state directory becomes a reason to uninstall a tool.
    @Test
    func sessionsAreForgottenOnceTheyAreOldEnough() throws {
        let harness = try Self.temporary()
        let ledger = harness.ledger
        defer { harness.cleanup() }

        #expect(ledger.refuse(session: "old", command: "grep -n foo A.swift") == .advise)
        let stale = harness.adviceDirectory.appendingPathComponent("old.json")
        try FileManager.default.setAttributes(
            [.modificationDate: harness.clock.current.addingTimeInterval(-AdviceLedger.retention - 60)],
            ofItemAtPath: stale.path
        )

        // The prune runs on a session's first denial, which is the one moment a listing is already worth it.
        #expect(ledger.refuse(session: "new", command: "grep -n bar B.swift") == .advise)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: harness.adviceDirectory.appendingPathComponent("new.json").path))
    }

    /// The `reuse` subdirectory is a file per nudge given and nothing else ever removes them — the same shape of leak the ledger guards against — so the prune sweeps it in the same pass, by mtime rather than by the `.json` extension a session's own state uses.
    @Test
    func aStaleReuseMarkIsPrunedAndAFreshOneKept() throws {
        let harness = try Self.temporary()
        let ledger = harness.ledger
        defer { harness.cleanup() }
        let reuseDirectory = harness.adviceDirectory.appendingPathComponent("reuse", isDirectory: true)
        let marks = ReuseNudgeMarks(directory: reuseDirectory)

        #expect(marks.claim(context: "old", file: "A.swift", declaration: "A.f()"))
        let stale = try #require(FileManager.default.contentsOfDirectory(at: reuseDirectory, includingPropertiesForKeys: nil).first)
        try FileManager.default.setAttributes(
            [.modificationDate: harness.clock.current.addingTimeInterval(-AdviceLedger.retention - 60)],
            ofItemAtPath: stale.path
        )
        #expect(marks.claim(context: "new", file: "B.swift", declaration: "B.g()"))
        let fresh = try #require(FileManager.default.contentsOfDirectory(at: reuseDirectory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent != stale.lastPathComponent })

        ledger.pruneSessions(olderThan: AdviceLedger.retention)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    /// The property everything else rests on: nothing this does can make a command unavailable.
    @Test
    func theSameCommandIsDeniedOnceAndThenAllowed() throws {
        let harness = try Self.temporary()
        let ledger = harness.ledger
        defer { harness.cleanup() }

        #expect(ledger.refuse(session: "s", command: "grep -n foo A.swift") == .advise)
        #expect(ledger.refuse(session: "s", command: "grep -n foo A.swift") == .allow)
        #expect(ledger.refuse(session: "s", command: "grep -n foo A.swift") == .allow)
    }

    /// Formatting is not identity: a re-run that differs only in spacing is the same command asking again.
    @Test
    func whitespaceDoesNotMakeACommandNew() throws {
        let harness = try Self.temporary()
        let ledger = harness.ledger
        defer { harness.cleanup() }

        #expect(ledger.refuse(session: "s", command: "grep -n foo A.swift") == .advise)
        #expect(ledger.refuse(session: "s", command: "grep  -n   foo    A.swift") == .allow)
    }

    /// The re-run a refusal promises is recognised by the grep stage alone — pattern, flags and paths — never by the whole line, so a retry that only changes what rides beside the grep in a compound command (an `echo` label ahead of it) is still the same ask; a different pattern is not.
    ///
    /// The classification runs against the checkout this suite is in, because the reading it exercises is of real paths; both judgements that would otherwise be read off that checkout are stated instead. A verdict that turned on whether this clone had been built, or indexed, lately is a verdict that passes or fails by accident.
    @Test
    func aRetryThatChangesOnlyWhatRidesBesideTheGrepIsTheSameCommand() throws {
        let directory = try TemporaryDirectory.make("ledger").appendingPathComponent("ledger")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = AdviceLedger(directory: directory)
        let noted = SuppressionLog(fileURL: directory.appendingPathComponent("suppressions.jsonl"))
        let cwd = FileManager.default.currentDirectoryPath
        let first = try #require(PreToolUseCommand.lookup(
            command: #"echo "=== a ==="; grep -rn "SimilarTarget" Sources"#,
            payload: [:],
            in: cwd,
            noting: noted,
            couldAnswer: { _, _ in true }
        ))
        let second = try #require(PreToolUseCommand.lookup(
            command: #"echo "=== b ==="; grep -rn "SimilarTarget" Sources"#,
            payload: [:],
            in: cwd,
            noting: noted,
            couldAnswer: { _, _ in true }
        ))
        let different = try #require(PreToolUseCommand.lookup(
            command: #"grep -rn "SimilarHit" Sources"#,
            payload: [:],
            in: cwd,
            noting: noted,
            couldAnswer: { _, _ in true }
        ))

        #expect(first.key == second.key)
        #expect(first.key != different.key)
        #expect(ledger.refuse(session: "s1", command: first.key) == .advise)
        #expect(ledger.refuse(session: "s1", command: second.key) == .allow)
        #expect(ledger.refuse(session: "s1", command: different.key) == .advise)
    }

    /// A `cat` carries no pattern, so the pattern of the stage it feeds is part of the ask: two different patterns down one `cat` are two asks, and the second is not waved through on the first one's allowance.
    @Test
    func twoPatternsDownOneCatAreTwoAsks() throws {
        let harness = try Self.temporary()
        let ledger = harness.ledger
        defer { harness.cleanup() }

        let first = try #require(ShellAdvice.lookupKey(for: #"cat Sources/SiftMCP/TextSearch.swift | grep -n "isProse""#, holdsSource: nil))
        let second = try #require(ShellAdvice.lookupKey(for: #"cat Sources/SiftMCP/TextSearch.swift | grep -n "alternation""#, holdsSource: nil))

        #expect(first != second)
        #expect(ledger.refuse(session: "s", command: first) == .advise)
        #expect(ledger.refuse(session: "s", command: second) == .advise)
    }

    /// The finer key never costs the escape hatch: the identical `cat`-piped grep, run again — with only an `echo` label beside it changed — is the same ask and passes, and a window after the grep is not part of what it asks.
    @Test
    func theIdenticalCatPipedGrepIsStillOneAsk() throws {
        let harness = try Self.temporary()
        let ledger = harness.ledger
        defer { harness.cleanup() }

        let first = try #require(ShellAdvice.lookupKey(for: #"echo a; cat Sources/SiftMCP/TextSearch.swift | grep -n "isProse""#, holdsSource: nil))
        let again = try #require(ShellAdvice.lookupKey(for: #"echo b; cat  Sources/SiftMCP/TextSearch.swift | grep -n "isProse""#, holdsSource: nil))
        let windowed = try #require(ShellAdvice.lookupKey(for: #"cat Sources/SiftMCP/TextSearch.swift | grep -n "isProse" | head -5"#, holdsSource: nil))

        #expect(first == again)
        #expect(first == windowed)
        #expect(ledger.refuse(session: "s", command: first) == .advise)
        #expect(ledger.refuse(session: "s", command: again) == .allow)
    }

    /// A reading stage with a pattern of its own is keyed on that stage alone, exactly as before the `cat` rule: what rides after it in the pipe does not make the key any finer.
    @Test
    func aSearchingReaderIsKeyedOnItselfAlone() {
        let key = ShellAdvice.lookupKey(for: "grep -n isProse Sources/SiftMCP/TextSearch.swift | grep -v let", holdsSource: nil)

        #expect(key == "grep -n isProse Sources/SiftMCP/TextSearch.swift")
    }

    /// Sessions do not share a ledger: two running at once would otherwise silence each other.
    @Test
    func sessionsAreIndependent() throws {
        let harness = try Self.temporary()
        let ledger = harness.ledger
        defer { harness.cleanup() }

        #expect(ledger.refuse(session: "one", command: "grep -n foo A.swift") == .advise)
        #expect(ledger.refuse(session: "two", command: "grep -n foo A.swift") == .advise)
    }

    /// A subagent must not be born mute because its parent has been quieted.
    ///
    /// The keys come from `AdviceContext` rather than being written out, because the hazard is not in the ledger's own logic — it is that a subagent's payload hands it the parent's session id, so both ends of the fix have to hold for this to mean anything.
    @Test
    func aQuietedParentDoesNotQuietItsSubagents() throws {
        let harness = try Self.temporary()
        let ledger = harness.ledger
        defer { harness.cleanup() }

        let parent = AdviceContext.resolve(sessionID: "s", transcriptPath: "/p/s.jsonl")
        for index in 0 ..< AdviceLedger.nudgeCap {
            #expect(ledger.refuse(session: parent.key, command: "grep -n foo P\(index).swift") == .advise)
        }
        #expect(ledger.refuse(session: parent.key, command: "grep -n foo D.swift") == .allow)

        // The subagent has been told nothing and spent nothing, so it is still owed its first word.
        let subagent = AdviceContext.resolve(sessionID: "s", transcriptPath: "/p/s/subagents/agent-aaa.jsonl")
        #expect(ledger.refuse(session: subagent.key, command: "grep -n foo D.swift") == .advise)
    }

    /// The escape hatch is this hook's own protocol, and taking it must spend no budget.
    ///
    /// Every refusal ends by offering the exact re-run as the way through — so a ledger that counted those re-runs as proof the advice was unwanted would go silent for the rest of the run after a handful of them. Following the stated protocol would be scored as defying it, and unrecoverably: the re-run lands immediately after the denial, leaving no room between them for the index call that is the only thing that clears the count.
    @Test
    func sanctionedReRunsNeverSpendTheBudget() throws {
        let harness = try Self.temporary()
        let ledger = harness.ledger
        defer { harness.cleanup() }

        // The exact shape that would end it: distinct commands, each denied and then re-run as invited,
        // with no index call anywhere — because the re-run leaves nowhere to put one.
        let decisions = ["A", "B", "C", "D", "E"].flatMap { name in
            [
                ledger.refuse(session: "s", command: "grep -n foo \(name).swift"),
                ledger.refuse(session: "s", command: "grep -n foo \(name).swift"),
            ]
        }

        #expect(decisions == [.advise, .allow, .advise, .allow, .advise, .allow, .advise, .allow, .advise, .allow])
        #expect(ledger.refuse(session: "s", command: "grep -n foo F.swift") == .advise)
    }

    /// Re-running one denied command five times is still one first sighting and nothing more.
    @Test
    func repeatsOfOneCommandAreOneFirstSighting() throws {
        let harness = try Self.temporary()
        let ledger = harness.ledger
        defer { harness.cleanup() }

        #expect(ledger.refuse(session: "s", command: "grep -n foo A.swift") == .advise)
        for _ in 0 ..< 5 {
            #expect(ledger.refuse(session: "s", command: "grep -n foo A.swift") == .allow)
        }
        #expect(ledger.refuse(session: "s", command: "grep -n foo B.swift") == .advise)
    }

    /// A run of denials that draws no index call does not quiet the advice: every denial the hook prints carries an answer or a build's wrapping, so a context drawing them is being served, and only the runaway cap opens a spell.
    @Test
    func aRunOfDenialsDrawingNoIndexCallDoesNotQuietTheAdvice() throws {
        let harness = try Self.temporary()
        defer { harness.cleanup() }

        let decisions = (0 ..< 20).map { harness.ledger.refuse(session: "s", command: "swift test --filter F\($0)") }

        #expect(decisions.allSatisfy { $0 == .advise })
    }

    /// The quiet is a spell, not a verdict.
    ///
    /// A latch is the wrong instrument for a signal this noisy: it is fed by whatever phase of work the context happens to be in, and once thrown there is no way back inside a run. A context that sweeps a directory for twenty minutes and then starts writing code has changed its mind about the advice; the ledger has to be able to change its mind back.
    @Test
    func aQuietSpellExpiresAndTheAdviceComesBack() throws {
        let harness = try Self.temporary()
        let ledger = harness.ledger
        defer { harness.cleanup() }

        for index in 0 ..< AdviceLedger.nudgeCap {
            #expect(ledger.refuse(session: "s", command: "grep -n foo F\(index).swift") == .advise)
        }
        #expect(ledger.refuse(session: "s", command: "grep -n foo during.swift") == .allow)

        // Still inside the spell, one second short of its end.
        harness.clock.advance(by: AdviceLedger.baseQuietPeriod - 1)
        #expect(ledger.refuse(session: "s", command: "grep -n foo stillQuiet.swift") == .allow)

        harness.clock.advance(by: 2)
        #expect(ledger.refuse(session: "s", command: "grep -n foo after.swift") == .advise)
    }

    /// Each spell is twice the last, so a context that genuinely prefers its own greps is interrupted a logarithmic number of times rather than an unbounded one — and is never permanently deaf to a tool it may want again.
    @Test
    func eachQuietSpellIsLongerThanTheLast() throws {
        let harness = try Self.temporary()
        let ledger = harness.ledger
        defer { harness.cleanup() }

        var round = 0
        for spell in 1 ... 3 {
            for _ in 0 ..< AdviceLedger.nudgeCap {
                #expect(ledger.refuse(session: "s", command: "grep -n foo F\(round).swift") == .advise)
                round += 1
            }
            // The previous spell's length is not enough to clear this one.
            if spell > 1 {
                harness.clock.advance(by: AdviceLedger.quietPeriod(after: spell - 1))
                #expect(ledger.refuse(session: "s", command: "grep -n foo probe\(spell).swift") == .allow)
                harness.clock.advance(by: AdviceLedger.quietPeriod(after: spell) - AdviceLedger.quietPeriod(after: spell - 1))
            } else {
                harness.clock.advance(by: AdviceLedger.quietPeriod(after: spell))
            }
        }

        #expect(AdviceLedger.quietPeriod(after: 1) == AdviceLedger.baseQuietPeriod)
        #expect(AdviceLedger.quietPeriod(after: 2) == AdviceLedger.baseQuietPeriod * 2)
        // And it stops growing, so an all-day session is still re-offered the advice periodically.
        #expect(AdviceLedger.quietPeriod(after: 12) == AdviceLedger.maximumQuietPeriod)
    }

    /// The absolute guard is still there behind the run limit, for a classification bug rather than for ordinary work — and it too is a spell, because a context still working after a hundred *distinct* lookups is doing an enormous amount of work rather than looping.
    @Test
    func theTotalCapOpensAQuietSpellRatherThanEndingIt() throws {
        let harness = try Self.temporary()
        let ledger = harness.ledger
        defer { harness.cleanup() }

        for index in 0 ..< AdviceLedger.nudgeCap {
            _ = ledger.refuse(session: "s", command: "grep -n foo F\(index).swift")
            harness.recordIndexCall(session: "s")
        }

        #expect(ledger.refuse(session: "s", command: "grep -n foo last.swift") == .allow)

        harness.clock.advance(by: AdviceLedger.maximumQuietPeriod + 1)
        #expect(ledger.refuse(session: "s", command: "grep -n foo later.swift") == .advise)

        // And the spell is a pause, not a new standing rate. A count that only ever rose would re-enter the
        // cap branch on every denial past the hundredth and open another spell: one nudge, then two hours
        // of silence, then one nudge, for the rest of the session.
        for index in 0 ..< 5 {
            harness.recordIndexCall(session: "s")
            #expect(ledger.refuse(session: "s", command: "grep -n foo after\(index).swift") == .advise)
        }
    }

    /// A ledger written by an older version can carry a `silenced` latch, an `ignoredKeys` set and a `usageStamp` that no longer mean anything; it must decode as the state it still has rather than as nothing at all.
    ///
    /// The `denied` set is the load-bearing half — losing it would make every command a first sighting and refuse a whole run of them again.
    @Test
    func aLedgerFromBeforeTheQuietSpellsKeepsWhatItKnew() throws {
        let harness = try Self.temporary()
        let ledger = harness.ledger
        defer { harness.cleanup() }

        try FileManager.default.createDirectory(at: harness.adviceDirectory, withIntermediateDirectories: true)
        let legacy = """
        {"silenced":true,"ignoredKeys":["grep -n foo A.swift"],"denied":["grep -n foo A.swift"],\
        "nudges":3,"unheededRun":2,"usageStamp":1786672047.8697877}
        """
        try Data(legacy.utf8).write(to: harness.adviceDirectory.appendingPathComponent("s.json"))

        // The command it already refused is still remembered, so the retry passes as it always did.
        #expect(ledger.refuse(session: "s", command: "grep -n foo A.swift") == .allow)
        // And the latch it was wrongly holding is gone: this context can be advised again.
        #expect(ledger.refuse(session: "s", command: "grep -n foo B.swift") == .advise)
    }

    /// A ledger written before the diagnosis and the run-based quiet spell were retired carries `unheededRun`, `refusals`, `reached` and `diagnosed`; it loads with what it still has, and none of them silences it.
    @Test
    func aLedgerCarryingTheRetiredFieldsLoads() throws {
        let harness = try Self.temporary()
        defer { harness.cleanup() }

        try FileManager.default.createDirectory(at: harness.adviceDirectory, withIntermediateDirectories: true)
        let legacy = """
        {"denied":["grep -n foo A.swift"],"nudges":3,"unheededRun":14,"refusals":40,"reached":false,"diagnosed":true,\
        "calls":["digest Gizmo"]}
        """
        try Data(legacy.utf8).write(to: harness.adviceDirectory.appendingPathComponent("s.json"))

        #expect(harness.ledger.refuse(session: "s", command: "grep -n foo A.swift") == .allow)
        #expect(harness.ledger.refuse(session: "s", command: "grep -n foo B.swift", offering: ["digest Gizmo"]) == .allow)
        #expect(harness.ledger.refuse(session: "s", command: "grep -n foo C.swift") == .advise)
        #expect(harness.ledger.refuse(session: "s", command: "grep -n foo D.swift") == .advise)
    }

    /// Two hook processes writing at once must not take each other's writes back out.
    ///
    /// One assistant message holding `mcp__sift__digest Foo` and `Read Bar.swift` as parallel calls — the shape this tool's own guidance asks for — starts two `pre-tool-use` processes against the same session. Each does a load, a mutation and a save; the save is atomic and the three of them together are not, so without a lock around them one saves the snapshot it loaded before the other's write and erases it. What is lost is evidence: a denial the ledger no longer remembers is a command refused a second time, and a compliance it no longer remembers walks a context that *is* using the index towards the futility floor.
    ///
    /// Asserted on the `denied` set because that is the half a re-run can interrogate: every command refused here must be allowed when it comes back, which is the property nothing in this file may cost.
    @Test
    func concurrentWritersDoNotTakeEachOthersWritesBackOut() throws {
        let harness = try Self.temporary()
        let ledger = harness.ledger
        defer { harness.cleanup() }

        // Rounds rather than one long run, because the window is narrow — a competitor only writes when a
        // denial has something for it to clear — and one round is one sample of it.
        for round in 0 ..< 25 {
            let session = "s\(round)"
            // A round far shorter than the cap, in a session of its own, so no quiet spell can open
            // however the two threads interleave: a spell allows a command for a reason that has nothing
            // to do with what is being measured, and would hide a lost write behind it.
            let commands = (0 ..< 14).map { "grep -n foo R\(round)F\($0).swift" }

            let deciding = Flag()
            let started = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                started.signal()
                var made = 0
                while deciding.isSet {
                    ledger.noteIndexCall(session: session, calls: ["digest Gizmo\(made)"])
                    made += 1
                }
                finished.signal()
            }
            // Waited for, so the two really are writing at the same time. A round whose competitor had not
            // started yet would pass whatever the ledger does, and a green run that proved nothing is the
            // worst outcome available to a test about a race.
            started.wait()
            let decisions = commands.map { ledger.refuse(session: session, command: $0) }
            deciding.clear()
            finished.wait()

            #expect(decisions.allSatisfy { $0 == .advise })
            // Every one of them remembered, so the re-run each refusal offers is allowed — the property
            // nothing in this file may cost, and the one a lost `denied` insertion takes away.
            #expect(commands.map { ledger.refuse(session: session, command: $0) }.allSatisfy { $0 == .allow })
        }
    }

    /// A refusal the ledger could not write down is not issued at all.
    ///
    /// The state directory being usable is not the same as this session's file being writable, and the refusal's promise rests on the second. Every refusal says the identical re-run will be allowed; the `denied` set is the only thing that can keep that, so a decision whose save did not land would print a promise nothing on disk could honour — which, from inside a session, looks like identical re-runs refused a second time. ``AdviceLedger/concurrentWritersDoNotTakeEachOthersWritesBackOut()`` closes the race that produces it; this closes the case where the write simply fails.
    ///
    /// The failure is arranged rather than simulated: a directory standing where the session's `.json` file goes cannot be replaced by an atomic write.
    @Test
    func aRefusalTheLedgerCouldNotRememberIsNotIssued() throws {
        let harness = try Self.temporary()
        defer { harness.cleanup() }
        try FileManager.default.createDirectory(
            at: harness.adviceDirectory.appendingPathComponent("s.json"),
            withIntermediateDirectories: true
        )

        #expect(harness.ledger.refuse(session: "s", command: "grep -n foo A.swift") == .allow)
        // And a session whose file *is* writable is unaffected, so what is under test is the failed write
        // and not the ledger having given up.
        #expect(harness.ledger.refuse(session: "t", command: "grep -n foo A.swift") == .advise)
    }

    /// An unwritable state directory means no memory of what was denied, which would make every command a first sighting and every one refused.
    ///
    /// Off is the only safe reading.
    @Test
    func anUnusableStateDirectoryTurnsTheAdviceOff() throws {
        let file = try TemporaryDirectory.make("advice-blocker").appendingPathComponent("advice-blocker")
        try Data("not a directory".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        // A path under a regular file cannot be created as a directory.
        let ledger = AdviceLedger(directory: file.appendingPathComponent("advice", isDirectory: true))

        #expect(ledger.refuse(session: "s", command: "grep -n foo A.swift") == .allow)
    }

    /// Asked about several keys at once, the ledger names those a re-run is already allowed for — the ones a denial was recorded under in this session, and no other — and spends nothing in the asking.
    @Test
    func itSaysWhichOfSeveralKeysAReRunIsAlreadyAllowedFor() throws {
        let harness = try Self.temporary()
        let ledger = harness.ledger
        defer { harness.cleanup() }
        let keys = ["grep -n foo A.swift", "grep -n bar B.swift"]

        #expect(ledger.rerunsAllowed(session: "s", among: keys).isEmpty)
        #expect(ledger.refuse(session: "s", command: keys[0]) == .advise)
        #expect(ledger.rerunsAllowed(session: "s", among: keys) == [keys[0]])
        #expect(ledger.rerunsAllowed(session: "other", among: keys).isEmpty)
        #expect(ledger.refuse(session: "s", command: keys[1]) == .advise)
        #expect(ledger.rerunsAllowed(session: "s", among: keys) == Set(keys))
    }
}

extension AdviceLedgerTests {
    /// A ledger under a throwaway directory, the clock its spells are measured on, and the tidy-up for both.
    struct Harness {
        let ledger: AdviceLedger
        let clock: Clock
        let adviceDirectory: URL
        let cleanup: () -> Void

        /// This context making an index call, as the hook sees one — an `mcp__sift__…` tool call in its own payload.
        func recordIndexCall(session: String, sourceLocation: SourceLocation = #_sourceLocation) {
            record(
                session: session,
                payload: ["tool_name": "mcp__sift__digest", "tool_input": ["target": "SummaryState"]],
                sourceLocation: sourceLocation
            )
        }

        /// The other half of compliance: a build wrapped in `sift run`, which reaches the hook as Bash text rather than as a tool of this server's.
        func recordWrappedRun(session: String, sourceLocation: SourceLocation = #_sourceLocation) {
            record(
                session: session,
                payload: ["tool_name": "Bash", "tool_input": ["command": "sift run -- swift test"]],
                sourceLocation: sourceLocation
            )
        }

        /// Exactly what the hook does with a call it recognises as the advice being taken — recognition included, so a helper cannot go on crediting a shape the hook has stopped recognising.
        private func record(session: String, payload: [String: Any], sourceLocation: SourceLocation) {
            guard PreToolUseCommand.takesTheAdvice(command: nil, payload: payload) else {
                Issue.record("the hook did not read \(payload) as the advice being taken", sourceLocation: sourceLocation)
                return
            }
            ledger.noteIndexCall(session: session)
        }
    }

    /// A latch one thread clears and another reads, so a background writer runs for exactly as long as the work it is competing with.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func clear() {
            lock.lock()
            defer { lock.unlock() }
            value = false
        }
    }

    /// A clock the test moves by hand, because a quiet spell is measured in wall time and waiting fifteen real minutes is not a test.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) {
            self.value = value
        }

        var current: Date {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func advance(by interval: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            value = value.addingTimeInterval(interval)
        }
    }
}

extension AdviceLedger {
    /// The ledger driven the way the hook drives it: the decision, and — where the hook would go on to print a denial — the record of that denial.
    ///
    /// The two are separate calls in the hook because only one of its outcomes still denies a command: a lookup it answers in place is denied and recorded, and a lookup it has no answer for is let through and recorded nowhere. A test about what a *refused* command costs a context therefore has to make both calls, exactly as ``SiftCLI/PreToolUseCommand/outcome(to:session:context:payload:cwd:ledger:usage:suppressions:answerer:)`` does — including its fallback, since a denial whose record did not land is not made.
    func refuse(session: String, command: String, offering calls: [String] = []) -> Decision {
        let decision = decide(session: session, command: command, offering: calls)
        guard decision == .advise else { return decision }
        return noteDenial(session: session, command: command) ? .advise : .allow
    }
}
