//
// Copyright © Agulhas Labs
//

import Foundation

/// Reconciles what the shards reported against the tests the plan gave them.
///
/// **Attempts are deduplicated by identity and the last one is the outcome.** A plan that retries re-runs under `Iteration N` — XCTest re-runs the one failing test, Swift Testing re-runs the bundle — so a test that failed and then passed is one test that passed, never two tests and never a duplicate. A second ending *inside* one iteration is the opposite: nothing legitimate prints one, so it is reported as duplicated.
///
/// **Missing is per shard, because a missing test is located by the shard that lost it.** A crash takes the rest of its process with it, so the shard is the first thing to look at and the answer names it beside the test.
///
/// **A conditional test is decided by the run, as ``RunReconciler`` decides it**, so one suite gets one verdict sharded or not: one that ended in no shard at all is undecided and counted in neither direction rather than missing, and a group one name cannot tell apart is owed what ``CountedGroup`` says it is owed.
public struct ShardMerge: Sendable {
    /// Reconciles `outcomes` — one per planned shard, in the plan's order — against `plan`.
    ///
    /// A planned shard with no outcome at all has every test it was given reported missing, so the arithmetic still accounts for the whole expected set rather than quietly shrinking to the shards that answered.
    ///
    /// The other direction is a runner defect and is stated as one: a result beyond the plan's last shard names no tests this reconciliation expected, so it is counted, said in a note, and the run is not green over it — a result nobody read could be a whole shard's worth of tests going unaccounted for.
    public static func reconcile(plan: ShardPlan, outcomes: [ShardOutcome], shardTimeoutSeconds: TimeInterval? = nil) -> ShardReconciliation {
        var tally = Tally()
        var shards: [ShardReconciliation.Shard] = []
        let everyTest = plan.shards.flatMap(\.tests)
        let outsideThePlan = max(0, outcomes.count - plan.shards.count)
        if outsideThePlan > 0 {
            tally.notes.append(outsideThePlan == 1
                ? "1 shard result was outside the plan and was not read"
                : "\(outsideThePlan) shard results were outside the plan and were not read")
        }

        for (offset, planShard) in plan.shards.enumerated() {
            guard offset < outcomes.count else {
                tally.missing.append(contentsOf: planShard.tests.map {
                    ShardReconciliation.Missing(shard: planShard.index, test: $0)
                })
                continue
            }
            let own = Set(planShard.tests)
            let elsewhere = everyTest.filter { !own.contains($0) }
            read(planShard, outcome: outcomes[offset], elsewhere: elsewhere, declared: plan, into: &tally)
        }
        tally.decideConditionals(declared: plan)
        for (planShard, outcome) in zip(plan.shards, outcomes) {
            shards.append(shard(planShard, outcome: outcome, from: tally))
        }

        let duplicated = duplications(in: tally)
        let standing = standingFailures(in: outcomes, plan: plan, ran: tally.ran, failed: tally.failedTests)
        let failures = standing.map(\.failure)
        let counts = ShardReconciliation.Counts(
            expected: plan.testCount - tally.undecided.count - tally.unowed,
            ran: tally.ran.count + tally.countOnlyRan,
            passed: tally.passed,
            failed: tally.failed,
            skipped: tally.skipped,
            missing: tally.missing.count + tally.shortfalls.reduce(0) { $0 + $1.missing },
            duplicated: duplicated.count + tally.countOnlyDuplicated
        )
        return ShardReconciliation(
            counts: counts,
            shards: shards,
            missing: tally.missing,
            shortfalls: tally.shortfalls,
            duplicated: duplicated,
            failed: tally.failedTests.sorted { $0.enumerated < $1.enumerated },
            timings: tally.timings,
            failures: failures,
            notes: tally.notes + countOnlyNotes(tally) + attributionNotes(tally) + foreignEndingNotes(tally) + retriedNotes(shards)
                + endedNotes(plan: plan, outcomes: outcomes, shardTimeoutSeconds: shardTimeoutSeconds) + consoleFallbackNotes(plan: plan, outcomes: outcomes),
            resultsOutsideThePlan: outsideThePlan,
            undecided: (tally.undecided + tally.undecidedInGroups).sorted { $0.enumerated < $1.enumerated },
            undecidedInGroups: tally.undecidedInGroups.sorted { $0.enumerated < $1.enumerated },
            unlisted: tally.unlisted,
            // A test some stream ended is named once, under `unlisted`, as having run.
            neverListed: plan.neverListed.filter { !tally.ranUnlisted.contains($0) },
            unrecordedFailures: tally.failedTests.filter { !covered($0, by: standing, failed: tally.failedTests, declared: plan) }
                .sorted { $0.enumerated < $1.enumerated }
        )
    }
}

// MARK: - One shard

private extension ShardMerge {
    /// Reads one shard's log against the tests it was given.
    static func read(
        _ planShard: ShardPlan.Shard,
        outcome: ShardOutcome,
        elsewhere: [TestIdentifier],
        declared plan: ShardPlan,
        into tally: inout Tally
    ) {
        let index = planShard.index
        // Where the shard wrote an event stream, the tests it declares are settled from it, and the console is read for the rest, which is XCTest.
        let streamed = outcome.eventStream.map { readStreamed(planShard, stream: $0, declared: plan, into: &tally) } ?? []
        let tests = planShard.tests.filter { !streamed.contains($0) }
        let outcomes = outcome.eventStream == nil ? outcome.outcomes : outcome.outcomes.leavingOutSwiftTesting
        let match = TestNameMatch.reconcile(expected: tests, reported: outcomes.names)
        let countOnly = Set(match.byCountOnly.flatMap(\.expected))
        var unreported: [TestIdentifier] = []
        // Only where this shard was given a declarer of the literal: an ending printed anywhere else is unattributed,
        // which never reds, so counting it toward the group would let a surplus there excuse a shortfall.
        let given = Set(tests)
        for name in outcomes.names where name.hasPrefix("\"") && (plan.displayNames[name] ?? []).contains(where: given.contains) {
            tally.literalEndings[name, default: 0] += TestNameMatch.Ambiguity(sharedLiteral: name, declaredBy: []).endings(in: outcomes).count
        }

        for test in tests.sorted(by: { $0.enumerated < $1.enumerated }) where !countOnly.contains(test) {
            let attempts = (match.named[test] ?? []).flatMap { outcomes.attempts[$0] ?? [] }
            guard RunTestOutcomes.lastAttempt(of: attempts) != nil else {
                unreported.append(test)
                continue
            }
            spend(attempts, on: test, shard: index, into: &tally)
        }

        let claimed = readDisplayNamed(
            match,
            outcomes: outcomes,
            declared: plan,
            shard: index,
            unreported: &unreported,
            into: &tally
        )
        readCountOnly(match, outcomes: outcomes, conditional: plan.conditional, shard: index, into: &tally)
        // A conditional test that reported nothing may have been switched off rather than lost, but only the shards
        // still to be read can say it did not end somewhere else, so it waits for `Tally.decideConditionals(declared:)`.
        tally.conditionalUnreported.append(contentsOf: unreported.filter(plan.conditional.contains).map {
            ShardReconciliation.Missing(shard: index, test: $0)
        })
        unreported.removeAll(where: plan.conditional.contains)
        readUnclaimed(
            match.unclaimed.filter { !claimed.contains($0) },
            shard: index,
            elsewhere: elsewhere,
            declared: plan,
            outcomes: outcomes,
            into: &tally
        )
        tally.missing.append(contentsOf: unreported.map {
            ShardReconciliation.Missing(shard: index, test: $0)
        })
    }

    /// Settles every test of this shard its event stream declares, from the stream alone, and answers which those were.
    ///
    /// A declared test with no ending in the stream is missing, as one with no line in a console is. A test the stream ended that this shard was not given is spent here where the plan gave it to another shard, so a second ending there reads as a duplicate, and is named as not listed where the plan has it nowhere: `swift test list` goes through the same lossy relay as the console, and a test the listing lost is otherwise one no shard expected, run and never counted.
    static func readStreamed(
        _ planShard: ShardPlan.Shard,
        stream: ShardEventStream,
        declared plan: ShardPlan,
        into tally: inout Tally
    ) -> Set<TestIdentifier> {
        let index = planShard.index
        let settled = Set(planShard.tests).intersection(stream.declared)
        for test in settled.sorted(by: { $0.enumerated < $1.enumerated }) {
            guard let attempts = stream.attempts[test], !attempts.isEmpty else {
                let missing = ShardReconciliation.Missing(shard: index, test: test)
                if plan.conditional.contains(test) {
                    tally.conditionalUnreported.append(missing)
                } else {
                    tally.missing.append(missing)
                }
                continue
            }
            spend(attempts, on: test, shard: index, into: &tally)
        }
        let planned = Set(plan.shards.flatMap(\.tests))
        for (test, attempts) in stream.attempts.sorted(by: { $0.key.enumerated < $1.key.enumerated }) where !settled.contains(test) {
            if planned.contains(test) {
                spend(attempts, on: test, shard: index, into: &tally)
            } else {
                tally.unlisted.append("shard \(index): \(test.enumerated)")
                tally.ranUnlisted.insert(test)
                // It is in no `ran` or `expected` count, but a failure is a failure wherever it was found: it is tallied and re-run like any other.
                if RunTestOutcomes.lastAttempt(of: attempts)?.ending == .failed {
                    tally.failed += 1
                    tally.failedTests.append(test)
                }
            }
        }
        tally.unlisted.append(contentsOf: stream.unreadable.map { "shard \(index): \($0)" })
        return settled
    }

    /// One shard's own line of the answer, built once every shard has been read, so the tests it is missing include a conditional test that turned out to have ended in another shard.
    static func shard(_ planShard: ShardPlan.Shard, outcome: ShardOutcome, from tally: Tally) -> ShardReconciliation.Shard {
        let index = planShard.index
        let outcomes = outcome.outcomes
        let missingHere = tally.missing.filter { $0.shard == index }.count
            + tally.shortfalls.filter { $0.shard == index }.reduce(0) { $0 + $1.missing }
        // A failed test's own wait is what would inflate its history, a skip never ran at all, and the
        // timings beside either in the same shard were not touched by whatever the failure was — so only
        // the passed tests are offered.
        let excludedHere = Set(tally.failedTests).union(tally.skippedTests)
        var shard = ShardReconciliation.Shard(
            index: index,
            testCount: planShard.tests.count,
            iterations: outcomes.iterations,
            wallSeconds: outcome.wallSeconds,
            executionSeconds: executionSeconds(of: outcomes),
            predictedSeconds: planShard.predictedSeconds,
            exitCode: outcome.exitCode,
            logPath: outcome.logPath,
            recording: TestDurationStore.Recording(
                observations: tally.timings.filter { $0.shard == index && !excludedHere.contains($0.test) }.map {
                    TestDurationStore.Timing(identifier: $0.test.enumerated, seconds: $0.seconds, iteration: 1)
                } + outcome.suiteSeconds.sorted { $0.key < $1.key }.map {
                    TestDurationStore.Timing(identifier: SuiteSpans.storeKey(for: $0.key), seconds: $0.value, iteration: 1)
                },
                retried: outcomes.iterations > 1,
                missing: missingHere
            ),
            closedWithRunSummary: outcome.closedWithRunSummary
        )
        let runs = outcomes.swiftTestingRuns
        let unclosed = runs.indices.filter { runs[$0].ending == nil }
        if runs.count > 1, unclosed.count == 1, let position = unclosed.first {
            shard.unclosedSwiftTestingRun = (position: position + 1, of: runs.count)
        }
        return shard
    }

    /// Records one test by the attempts that ended it: its last attempt is its outcome, its first attempt is the only one worth timing, and two endings inside one iteration are a duplication.
    ///
    /// Shared by the two ways a shard can reach a test — the identifier the log named it by and the literal it declared — so an attribution made on a display name is counted, timed and checked for repeats exactly as one made on an identifier is, rather than being counted and quietly left untimed.
    ///
    /// A repeat is not this test's own where the endings were printed under a literal another planned test declares too: a second ending is then a surplus no name can be given to, which the caller counts, and not this test's duplicate.
    static func spend(
        _ attempts: [RunTestOutcomes.Attempt],
        on test: TestIdentifier,
        shard index: Int,
        repeatsAreItsOwn: Bool = true,
        into tally: inout Tally
    ) {
        guard let last = RunTestOutcomes.lastAttempt(of: attempts) else {
            return
        }
        tally.record(test, ending: last.ending, in: index)
        if let seconds = attempts.first(where: { $0.iteration == 1 })?.seconds {
            tally.timings.append(ShardReconciliation.Timing(shard: index, test: test, seconds: seconds))
        }
        if repeatsAreItsOwn, RunTestOutcomes.repeatWithinAnIteration(of: attempts) != nil {
            tally.duplicatedWithinShard.insert(test)
        }
    }

    /// Spends each quoted ending on the test that declares that literal, where the plan carries the literal and the shard was given a test still waiting to report under it.
    ///
    /// **This is the join a plan of identifiers cannot make on its own.** Swift Testing prints a test carrying `@Test("…")` under its literal, which no `Target/Type/function` identifier spells, so the ending claims nothing and the test that ran claims nothing — and the shard reports a test that passed as missing. The literal the declaration wrote is the only thing that says the two are one test, and ``ShardPlan/displayNames`` is how it reaches here.
    ///
    /// **The ending is still spent only on a test the log named**, now that the log's name is readable: the literal identifies the test as surely as an identifier does, and nothing is paired by count in either direction. A literal naming no test this shard is still waiting on — another shard's test, another bundle's, a stray suite's — is left unclaimed, and every test that reported nothing stays missing.
    ///
    /// **A literal more than one of this shard's waiting tests declares is reconciled by count**, as ``RunReconciler`` does it: the log names none of them by anything but the literal, so claiming one would name the other missing on a guess.
    ///
    /// **More endings of a literal than the one waiting test declaring it, where another planned test declares it too, are one surplus with no name to give.** A second ending is either that test running twice or another declarer running here, in the wrong shard, and the log cannot say which. Naming the waiting test duplicated tells the first story and leaves the second to be told again about the other declarer, so the surplus is counted once, as a count-only group's is, and the note names every declarer. The other declarer is decided in its own shard, as its own disposition says.
    ///
    /// Answers with the names it spent, so the ending is not counted a second time as unattributed.
    static func readDisplayNamed(
        _ match: TestNameMatch,
        outcomes: RunTestOutcomes,
        declared plan: ShardPlan,
        shard index: Int,
        unreported: inout [TestIdentifier],
        into tally: inout Tally
    ) -> Set<String> {
        var claimed: Set<String> = []
        var shared: [String] = []
        let planned = Set(plan.shards.flatMap(\.tests))
        for name in match.unclaimed where name.hasPrefix("\"") {
            let attempts = outcomes.attempts[name] ?? []
            let declaring = Set(plan.displayNames[name] ?? [])
            let waiting = unreported.filter(declaring.contains)
            // Checked before the test leaves `unreported`: a name the log started and never ended is no ending at
            // all, and a test taken out of the missing set on one would be counted in neither direction.
            guard RunTestOutcomes.lastAttempt(of: attempts) != nil, let test = waiting.first else {
                continue
            }
            unreported.removeAll(where: waiting.contains)
            if waiting.count > 1 {
                readByCount(
                    TestNameMatch.Ambiguity(sharedLiteral: name, declaredBy: waiting),
                    outcomes: outcomes,
                    conditional: plan.conditional,
                    shard: index,
                    into: &tally
                )
                shared.append(name)
            } else if declaring.count(where: planned.contains) > 1 {
                let surplus = TestNameMatch.Ambiguity(sharedLiteral: name, declaredBy: [test]).endings(in: outcomes).count - 1
                spend(attempts, on: test, shard: index, repeatsAreItsOwn: false, into: &tally)
                if surplus > 0 {
                    tally.countOnlyDuplicated += surplus
                    let declarers = declaring.filter(planned.contains).map(\.enumerated).sorted().joined(separator: ", ")
                    tally.notes.append("shard \(index): \(name): the shard ended this name \(surplus) time\(surplus == 1 ? "" : "s") more than the 1 test it was given that declares it. \(declarers) declare it, and the log cannot say whether one of them ran twice or another ran in the wrong shard, so the surplus is counted as duplicated with no name to give.")
                }
            } else {
                spend(attempts, on: test, shard: index, into: &tally)
            }
            claimed.insert(name)
        }
        if !shared.isEmpty {
            tally.reconciledByCount(shared, shard: index, cause: TestNameMatch.sharedLiteralCause)
        }
        return claimed
    }

    /// Reconciles the groups one function name could not be told apart by: enough endings is nothing missing, too few is a shortfall with no name to give, and more than the whole group could account for is a duplication with none.
    ///
    /// The endings are spent worst first, because nothing in the log says which of the group an ending belonged to: taking them in the order they were printed makes the verdict depend on whether the failure ran before or after the passes, and drops it entirely when it ran last. The same arithmetic the unsharded reconciliation does, over the one group this shard was given — see ``RunReconciler``.
    static func readCountOnly(
        _ match: TestNameMatch,
        outcomes: RunTestOutcomes,
        conditional: Set<TestIdentifier>,
        shard index: Int,
        into tally: inout Tally
    ) {
        for ambiguity in match.byCountOnly {
            readByCount(ambiguity, outcomes: outcomes, conditional: conditional, shard: index, into: &tally)
        }
        for framework in TestNameMatch.Ambiguity.Framework.allCases {
            let names = match.byCountOnly.filter { $0.framework == framework }.map(\.function)
            if !names.isEmpty {
                tally.reconciledByCount(names, shard: index, cause: framework.countOnlyCause)
            }
        }
    }

    /// One group reconciled by count, whichever name it could not be told apart by — a function name several suites declare, or a `@Test("…")` literal several tests share.
    ///
    /// A conditional member is owed an ending like the rest unless every member is conditional — ``CountedGroup``, the arithmetic ``RunReconciler`` does over the same group. Where every member is conditional and the endings do not reach them all, the count cannot say which reported nothing, so every member is named undecided beside the note saying how many.
    static func readByCount(
        _ ambiguity: TestNameMatch.Ambiguity,
        outcomes: RunTestOutcomes,
        conditional: Set<TestIdentifier>,
        shard index: Int,
        into tally: inout Tally
    ) {
        let endings = RunTestOutcomes.worstFirst(ambiguity.endings(in: outcomes))
        let expected = ambiguity.expected.count
        let group = CountedGroup(members: expected, conditional: ambiguity.expected.count(where: conditional.contains), endings: endings.count)
        tally.countOnlyRan += group.ran
        tally.unowed += expected - group.owed
        for ending in endings.prefix(group.ran) {
            tally.count(ending)
        }
        if let note = group.unowedNote(function: ambiguity.function) {
            tally.notes.append("shard \(index): \(note)")
            tally.undecidedInGroups.append(contentsOf: ambiguity.expected.filter(conditional.contains))
        }
        let surplus = endings.count - expected
        if surplus > 0 {
            tally.countOnlyDuplicated += surplus
            tally.notes.append("shard \(index): \(ambiguity.function): the run ended this name \(surplus) time\(surplus == 1 ? "" : "s") more than there are tests declaring it, which no retry explains, so the surplus is counted as duplicated with no name to give.")
        }
        if group.missing > 0 {
            tally.shortfalls.append(ShardReconciliation.Shortfall(
                shard: index,
                function: ambiguity.function,
                missing: group.missing,
                expected: group.owed,
                conditional: group.conditional
            ))
        }
    }

    /// Places `names`, the endings that claimed no test this shard was given: a test another shard owns, a test the listing lost that ran here all the same, or nothing this answer can attribute.
    ///
    /// **An ending is spent on a test only where it names that test.** Nothing is paired by count. An unclaimed ending is a name no expected test answered to, and a shard's log offers no second reading of it: an ending from a bundle the plan never named, a stray suite, a file-scope test and a line from some other run all arrive here looking alike. Handing any of them to a test the shard reported nothing for is how a crash is covered up — the test that crashed is counted as having run, on an ending that was never its own, and the run reads green over it. So every unreported test is missing, and every unclaimed ending is counted into ``Tally`` and stated in the notes instead of being spent.
    ///
    /// **A quoted display name is read before this, not here.** A Swift Testing test declaring its own literal logs under that literal, which matches no enumerated identifier, so attributing the ending needs the literal the declaration wrote — carried into the plan from the inventory and spent by ``readDisplayNamed(_:outcomes:declared:shard:unreported:into:)``. What reaches here is what that could not place: a plan with no inventory behind it, a literal naming no test this shard is still waiting on, or a name that is not quoted at all.
    static func readUnclaimed(
        _ names: [String],
        shard index: Int,
        elsewhere: [TestIdentifier],
        declared plan: ShardPlan,
        outcomes: RunTestOutcomes,
        into tally: inout Tally
    ) {
        // An ending naming a test another shard was given is that test running in the wrong shard, which is only
        // visible from here: its own shard's reconciliation never sees this log. Recorded so a test ending in two
        // shards is reported as duplicated, and counted by the shard that owns it or by neither. A name the log
        // repeated is recorded once per ending, because that is how often the shard ended it. A quoted name is also
        // the literal a test declared, which is the only name the log gives a test that declares one.
        var unclaimed: [String] = []
        for name in names {
            let declaring = Set(plan.displayNames[name] ?? [])
            let owners = elsewhere.filter { matches($0, name) || declaring.contains($0) }
            let lost = plan.neverListed.filter { matches($0, name) || declaring.contains($0) }
            // A test the listing lost can still run — an XCTest method its class's filter selects — and is named once, as the stream names one, under `unlisted`.
            if owners.isEmpty, lost.count == 1, let test = lost.first {
                let line = "shard \(index): \(test.enumerated)"
                if !tally.unlisted.contains(line) {
                    tally.unlisted.append(line)
                    // Named once, so a failure is counted once: it is in no `ran` or `expected` count, but is tallied and re-run like any other.
                    if RunTestOutcomes.lastAttempt(of: outcomes.attempts[name] ?? [])?.ending == .failed {
                        tally.failed += 1
                        tally.failedTests.append(test)
                    }
                }
                tally.ranUnlisted.insert(test)
                continue
            }
            guard owners.count == 1, let test = owners.first else {
                unclaimed.append(name)
                continue
            }
            tally.endedIn[test, default: []].append(index)
        }

        tally.unattributed += unclaimed.count
    }
}

// MARK: - Reading a shard's log

private extension ShardMerge {
    /// Whether a reported name names this test, asking the framework the name was printed by.
    static func matches(_ test: TestIdentifier, _ name: String) -> Bool {
        TestIdentifier.xctestLogName(name) == nil
            ? test.matches(swiftTestingLogName: name)
            : test.matches(xctestLogName: name)
    }

    /// Whether a failure record names this test: the event stream's by the identifier it was recorded under, a display-named test's by the literal the plan says it declares — only where the record came from the shard that test was given, since another shard's test declaring the same literal is not the one that printed it — and the console's by the name its framework printed.
    static func names(_ failure: RunTestFailure, _ test: TestIdentifier, declared plan: ShardPlan, givenTo shard: Set<TestIdentifier>) -> Bool {
        failure.name == test.enumerated
            || (plan.displayNames[failure.name]?.contains(test) == true && shard.contains(test))
            || matches(test, failure.name)
    }

    /// Whether some record among `standing` accounts for this failed test.
    ///
    /// **A name that carries no suite covers a test only where it cannot be mistaken for another**: a Swift Testing console line prints `same()` and nothing more, so one record for it cannot say which of two failed `same()` tests in different suites it belongs to. It covers them all only when there are records enough, one apiece; otherwise none of them, and each is named on its own rather than one being left out of the answer.
    static func covered(_ test: TestIdentifier, by standing: [StandingFailure], failed: [TestIdentifier], declared plan: ShardPlan) -> Bool {
        let naming = standing.filter { names($0.failure, test, declared: plan, givenTo: $0.shard) }
        let bare = naming.filter { record in
            let name = record.failure.name
            return name != test.enumerated && plan.displayNames[name] == nil && TestIdentifier.xctestLogName(name) == nil
        }
        guard !naming.isEmpty else {
            return false
        }
        guard bare.count == naming.count else {
            return true
        }
        let name = bare[0].failure.name
        return standing.filter { $0.failure.name == name }.count >= failed.filter { matches($0, name) }.count
    }

    /// Every attempt's own seconds, summed — the number wall clock is compared against.
    static func executionSeconds(of outcomes: RunTestOutcomes) -> Double {
        outcomes.attempts.values.reduce(0) { total, attempts in
            total + attempts.compactMap(\.seconds).reduce(0, +)
        }
    }
}

// MARK: - What the shards add up to

private extension ShardMerge {
    /// Every test that ended more than once, once each: a shard that ended it twice in one iteration, two shards that both ended it, or both at once.
    static func duplications(in tally: Tally) -> [ShardReconciliation.Duplication] {
        let twice = Set(tally.endedIn.filter { $0.value.count > 1 }.keys)
        return tally.duplicatedWithinShard.union(twice)
            .sorted { $0.enumerated < $1.enumerated }
            .map { test in
                ShardReconciliation.Duplication(
                    test: test,
                    shards: (tally.endedIn[test] ?? []).sorted(),
                    withinIteration: tally.duplicatedWithinShard.contains(test)
                )
            }
    }

    /// The failure detail the logs carried, less the failures a later attempt overtook — a first attempt that failed before a retry passed is an attempt, not a failure, and listing it under a line reading `failed 0` would be two answers in one.
    ///
    /// **A failure is dropped only where the reconciliation watched its test run and end some other way**, which is the one reading that makes it an attempt rather than a result. Everything else is kept, because everything else is the only sentence the answer has about a test the counts could not account for: a planned test that recorded an assertion and then crashed prints no ending at all, so it is missing rather than failed, and a test inside a count-only group never ends under an identity `ran` could hold. Dropping either leaves the run's one explanation of a missing test discarded, or `✘ 1 failed` standing over an empty failure section.
    ///
    /// A test whose event stream says it failed without starting — its condition threw — has no failure in the console the filter reads, so its message comes from the stream, and without it the answer would count the failure and never say what it was.
    static func standingFailures(in outcomes: [ShardOutcome], plan: ShardPlan, ran: Set<TestIdentifier>, failed: [TestIdentifier]) -> [StandingFailure] {
        outcomes.enumerated().flatMap { offset, outcome in
            let shard = offset < plan.shards.count ? Set(plan.shards[offset].tests) : []
            let records = outcome.failures + (outcome.eventStream?.failedBeforeStarting ?? [:]).sorted { $0.key.enumerated < $1.key.enumerated }.map {
                RunTestFailure(name: $0.key.enumerated, location: nil, message: $0.value)
            }
            return records.map { StandingFailure(failure: $0, shard: shard) }
        }.filter { record in
            let overtaken = ran.contains { names(record.failure, $0, declared: plan, givenTo: record.shard) }
                && !failed.contains { names(record.failure, $0, declared: plan, givenTo: record.shard) }
            return !overtaken
        }
    }

    /// A failure record beside the tests of the shard that printed it.
    struct StandingFailure {
        let failure: RunTestFailure
        let shard: Set<TestIdentifier>
    }

    /// One sentence per shard that repeated anything, so a green run that needed a second attempt does not read like one that did not.
    static func retriedNotes(_ shards: [ShardReconciliation.Shard]) -> [String] {
        shards.filter { $0.iterations > 1 }.map {
            "shard \($0.index) repeated tests, up to attempt \($0.iterations) — a test counts as its last attempt ended, and no duration was recorded from this shard"
        }
    }

    /// The sentences the answer owes about shards that were stopped rather than finished.
    ///
    /// The counts need nothing here — a test no shard reported an ending for is missing whether the shard was ended at its bound, never started, or crashed — but "missing" on its own sends a reader to the crash reports for tests that were simply never reached. Each sentence names the shard, so the reader knows which of its tests to distrust.
    ///
    /// **Iterates `outcomes`, never `zip(plan.shards, outcomes)`.** A `zip` truncates to the shorter of the two, so a result beyond the plan's last shard — already counted in ``resultsOutsideThePlan`` — would have its own `timedOut` or `launchFailure` silently dropped here instead of stated: the count elsewhere says a result went unread, this is what it would have said.
    ///
    /// `shardTimeoutSeconds` names the bound in the sentence only where a caller lowered it with `--shard-timeout`: the default floor is already explained in `sift help test-output`, and a run that never touched it does not need told which reading it got.
    static func endedNotes(plan: ShardPlan, outcomes: [ShardOutcome], shardTimeoutSeconds: TimeInterval? = nil) -> [String] {
        var notes: [String] = []
        for (offset, outcome) in outcomes.enumerated() {
            let subject = offset < plan.shards.count
                ? "shard \(plan.shards[offset].index)"
                : "the shard result outside the plan"
            if outcome.timedOut {
                let bound = shardTimeoutSeconds.map { " (bound \(ShardSeconds.text($0)), set by --shard-timeout)" } ?? ""
                notes.append("\(subject) was ended after \(ShardSeconds.text(outcome.wallSeconds)) with no result\(bound) — its unreported tests are missing")
            }
            if let failure = outcome.launchFailure {
                notes.append("\(subject) never started — \(failure); its tests are missing")
            }
        }
        return notes
    }

    /// One sentence per reason a shard whose console shows Swift Testing ran had no event stream to reconcile it from, naming the shards, since those tests were then read from a relay that drops lines under load.
    static func consoleFallbackNotes(plan: ShardPlan, outcomes: [ShardOutcome]) -> [String] {
        var shardsByReason: [String: [Int]] = [:]
        for (planShard, outcome) in zip(plan.shards, outcomes) where !outcome.outcomes.swiftTestingNames.isEmpty {
            if let reason = outcome.eventStreamAbsence {
                shardsByReason[reason, default: []].append(planShard.index)
            }
        }
        return shardsByReason.sorted { $0.key < $1.key }.map { reason, shards in
            let subject = shards.count == 1 ? "shard \(shards[0])" : "shards \(shards.map(String.init).joined(separator: ", "))"
            return "\(subject): \(reason), so Swift Testing was read from the console, which can drop lines under load"
        }
    }

    /// One sentence for each reason some groups were reconciled by count, naming every such group under the shard that reconciled it, so a reason shared by several shards is said once.
    static func countOnlyNotes(_ tally: Tally) -> [String] {
        tally.countOnlyCauses.map { cause in
            TestNameMatch.countOnlyNote(byShard: tally.countOnlyGroups[cause] ?? [], cause: cause)
        }
    }

    /// The sentences the answer owes about a test that is missing from the shard it was given and ended in another one.
    ///
    /// The counts need nothing here — its own shard reported no ending, so it is missing by the ordinary rule and the run is not green — but "missing" on its own sends a reader to the crash reports for a test that plainly ran. Each sentence names the test and the shard that did end it, which is where the wrong `-only-testing:` argument went.
    static func foreignEndingNotes(_ tally: Tally) -> [String] {
        tally.missing.compactMap { missing in
            let elsewhere = (tally.endedIn[missing.test] ?? []).sorted()
            guard !elsewhere.isEmpty else {
                return nil
            }
            let named = elsewhere.map(String.init).joined(separator: ", ")
            let subject = elsewhere.count == 1 ? "shard \(named)" : "shards \(named)"
            return "\(missing.test.enumerated) reported nothing in shard \(missing.shard), which was given it, but ended in \(subject) — it ran in the wrong shard rather than not at all"
        }
    }

    /// The sentences the answer owes about endings it could attribute to no test.
    ///
    /// The second sentence is owed only where this shard is in fact missing a test. It explains a missing test by an ending that arrived here with nothing to match it on, and a shard missing nothing has no such test to explain: said unconditionally it reports a state the run is not in, over an answer that is otherwise green. It is worded as the rule it is rather than as a claim about the ending in hand, because an unattributed ending is as likely to be an XCTest name from a bundle this shard was not given, which Swift Testing's quoted form says nothing about.
    ///
    /// It names the inventory, because the inventory is what a reader can do something about: a quoted ending whose literal the plan carried has already been spent on the test that declares it, so one that is still here is an ending from a run whose repository has no index to read, or one no declaration in that index claims.
    static func attributionNotes(_ tally: Tally) -> [String] {
        guard tally.unattributed > 0 else {
            return []
        }
        let count = tally.unattributed
        let stated = """
        \(count) reported ending\(count == 1 ? "" : "s") named no test the shard was given; counted here and nowhere else, \
        never spent on a test the shard reported nothing for, and not on their own a reason to fail the run.
        """
        guard !tally.missing.isEmpty else {
            return [stated]
        }
        return [
            """
            \(stated) A Swift Testing test that declares its own quoted name logs under it, which matches no enumerated \
            identifier: where the index declared that literal the ending has already been counted onto the test that \
            wrote it, so one still standing here is a name no inventory this run could read accounts for, and a test \
            of this shard's is reported missing rather than counted by it.
            """,
        ]
    }
}

// MARK: - The running count

private extension ShardMerge {
    /// What the merge accumulates while it walks the shards, before it becomes a reconciliation.
    struct Tally {
        /// Every test some shard reported an ending for, so a test that ended in two shards is still one test that ran.
        var ran: Set<TestIdentifier> = []
        var passed = 0
        var failed = 0
        var skipped = 0
        var failedTests: [TestIdentifier] = []
        /// Every test some shard reported a skip for, so its timing (an XCTest skip can carry one) never reaches the duration store as though it had run.
        var skippedTests: [TestIdentifier] = []
        var missing: [ShardReconciliation.Missing] = []
        var shortfalls: [ShardReconciliation.Shortfall] = []
        var timings: [ShardReconciliation.Timing] = []
        var notes: [String] = []

        /// Every test a shard's event stream ended that the listing never named, as `shard N: identifier`.
        var unlisted: [String] = []
        /// The tests behind ``unlisted`` — those a stream ended whose spelling could be read, and those a console ending named — so a test the index declares is not named a second time as never listed.
        var ranUnlisted: Set<TestIdentifier> = []

        /// Which shards reported an ending for each test — more than one of them is a duplicate.
        var endedIn: [TestIdentifier: [Int]] = [:]

        /// The tests one shard ended twice inside a single iteration.
        var duplicatedWithinShard: Set<TestIdentifier> = []

        /// How many endings named no test the shard was given, and were therefore attributed to none — see ``ShardMerge/readUnclaimed(_:shard:elsewhere:declared:unreported:into:)``.
        var unattributed = 0

        /// The reasons some names were reconciled by count, in the order they were first met.
        var countOnlyCauses: [String] = []

        /// The names each shard reconciled by count, under the reason it could not tell them apart, in the order the shards were read.
        var countOnlyGroups: [String: [(shard: Int, names: [String])]] = [:]

        /// Records that shard `shard` reconciled `names` by count for `cause`.
        mutating func reconciledByCount(_ names: [String], shard: Int, cause: String) {
            if countOnlyGroups[cause] == nil {
                countOnlyCauses.append(cause)
            }
            countOnlyGroups[cause, default: []].append((shard: shard, names: names))
        }

        /// How many of a count-only group's tests were accounted for by the endings it printed.
        var countOnlyRan = 0

        /// The conditional tests a shard was given that reported nothing, which are counted in neither direction.
        var undecided: [TestIdentifier] = []

        /// The conditional tests a shard was given that reported nothing there, waiting on every other shard's log before they are undecided or missing.
        var conditionalUnreported: [ShardReconciliation.Missing] = []

        /// How many members of an all-conditional count-only group reported nothing, which are counted in neither direction.
        var unowed = 0

        /// Every member of an all-conditional count-only group whose endings did not reach them all, named undecided because the count cannot say which reported nothing.
        ///
        /// ``unowed`` is how many did, so these are named and not counted again.
        var undecidedInGroups: [TestIdentifier] = []

        /// How many endings each quoted name printed across the shards read so far that were given a test declaring it, counted per shard the way a count-only group's are.
        ///
        /// A shard given no declarer is left out: its ending of the literal is unattributed, which never reds, so a surplus printed there is counted nowhere, and letting it reach the group's size would excuse a shortfall it cannot stand in for.
        var literalEndings: [String: Int] = [:]

        /// How many endings a count-only group printed beyond the tests declaring its name, which is duplicated with no name to give.
        var countOnlyDuplicated = 0

        /// Decides each conditional test that reported nothing in its own shard, once every shard has been read.
        ///
        /// One that ended in another shard ran, so it was not switched off: it is missing from the shard it was given, as an unconditional test would be, and ``ShardMerge/foreignEndingNotes(_:)`` names where it went. Only one that ended nowhere is undecided.
        ///
        /// **Unless it shares its `@Test("…")` literal with an unconditional test in the plan, and the literal ended somewhere, fewer times than the group has members.** The unsharded run reads every test declaring a literal as one group, owed an ending for each member once any member is unconditional — see ``CountedGroup``. A shard reads only its own waiting tests, so a group split across shards left the conditional member undecided beside the unconditional one's ending, and read green where the unsharded run of the same suite reads a shortfall. The ending in the other shard cannot be told from this test's own run there, in the wrong shard, with the unconditional test lost. So the member is owed, and a shortfall in its own shard with the whole group's sentence, not named missing: which of the group never reported is not something the logs say.
        ///
        /// Both conditions are what make an ending elsewhere a stand-in. A literal that ended nowhere has no ending that could be this test's, so the test is undecided as a lone conditional test is, and an unconditional member that reported nothing is missing by name. A literal that ended as often as the group has members loses no member however its endings are shared out, so the test is undecided and any surplus is counted where it was printed.
        mutating func decideConditionals(declared plan: ShardPlan) {
            let planned = Set(plan.shards.flatMap(\.tests))
            var owed: [ShardReconciliation.Shortfall] = []
            for waiting in conditionalUnreported {
                if !endedIn[waiting.test, default: []].isEmpty {
                    missing.append(waiting)
                } else if let (literal, group) = Self.mixedLiteralGroup(of: waiting.test, in: plan, planned: planned),
                          (1 ..< group.count).contains(literalEndings[literal, default: 0])
                {
                    if let index = owed.firstIndex(where: { $0.shard == waiting.shard && $0.function == literal }) {
                        let counted = owed[index]
                        owed[index] = ShardReconciliation.Shortfall(
                            shard: counted.shard,
                            function: literal,
                            missing: counted.missing + 1,
                            expected: counted.expected,
                            conditional: counted.conditional
                        )
                    } else {
                        owed.append(ShardReconciliation.Shortfall(
                            shard: waiting.shard,
                            function: literal,
                            missing: 1,
                            expected: group.count,
                            conditional: group.count(where: plan.conditional.contains)
                        ))
                    }
                } else {
                    undecided.append(waiting.test)
                }
            }
            shortfalls.append(contentsOf: owed)
            conditionalUnreported = []
        }

        /// The literal `test` declares and every planned test declaring it, where at least one of them is unconditional; `nil` otherwise.
        static func mixedLiteralGroup(
            of test: TestIdentifier,
            in plan: ShardPlan,
            planned: Set<TestIdentifier>
        ) -> (literal: String, group: [TestIdentifier])? {
            for (literal, declaring) in plan.displayNames where declaring.contains(test) {
                let group = declaring.filter(planned.contains)
                if group.contains(where: { !plan.conditional.contains($0) }) {
                    return (literal, group)
                }
            }
            return nil
        }

        mutating func record(_ test: TestIdentifier, ending: RunTestOutcomes.Ending, in shard: Int) {
            ran.insert(test)
            endedIn[test, default: []].append(shard)
            count(ending)
            if ending == .failed {
                failedTests.append(test)
            } else if ending == .skipped {
                skippedTests.append(test)
            }
        }

        mutating func count(_ ending: RunTestOutcomes.Ending) {
            switch ending {
            case .passed: passed += 1
            case .failed: failed += 1
            case .skipped: skipped += 1
            }
        }
    }
}
