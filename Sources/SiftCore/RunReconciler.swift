//
// Copyright © Agulhas Labs
//

import Foundation

/// Joins what an ordinary run reported to what the index says was supposed to run.
///
/// The sharded path gets its expected set from a plan enumeration, which needs a build; this one takes it from the inventory, which needs nothing, and is bounded by the container the run was made in instead of by the shard it was handed.
public struct RunReconciler {
    /// Reconciles one run's outcomes against the inventory, inside `scope`.
    public static func reconcile(
        inventory: TestInventory,
        outcomes: RunTestOutcomes,
        scope: RunReconciliation.Scope
    ) -> RunReconciliation {
        var population = population(of: inventory, in: scope)
        var match = TestNameMatch.reconcile(expected: population.identified, reported: outcomes.names)
        // A line under a compiled-out test's name proves its clause compiled after all — a log from another platform or
        // architecture — so the population is read again with that test owed as a compiled one is.
        let proven = provenCompiled(population, unclaimed: match.unclaimed)
        if !proven.isEmpty {
            population = Self.population(of: inventory, in: scope, provenCompiled: proven)
            match = TestNameMatch.reconcile(expected: population.identified, reported: outcomes.names)
        }
        let countOnly = Set(match.byCountOnly.flatMap(\.expected))
        var tally = Tally()

        read(population.expected.subtracting(countOnly), outcomes: outcomes, match: match, into: &tally)
        readConditional(population.conditional.subtracting(countOnly), outcomes: outcomes, match: match, population: population, into: &tally)
        readExcluded(population.excluded.subtracting(countOnly), outcomes: outcomes, match: match, into: &tally)
        readCountOnly(match, population: population, outcomes: outcomes, into: &tally)
        readUnclaimed(match, population: population, outcomes: outcomes, into: &tally)

        var reconciliation = RunReconciliation(
            counts: tally.counts,
            scope: scope,
            iterations: outcomes.iterations,
            missing: tally.missing.sorted { $0.enumerated < $1.enumerated },
            shortfalls: tally.shortfalls,
            lost: tally.lost.sorted { $0.enumerated < $1.enumerated },
            lostByCount: tally.lostByCount,
            duplicated: tally.duplicated.sorted { $0.test.enumerated < $1.test.enumerated },
            failed: tally.failedTests.sorted { $0.enumerated < $1.enumerated },
            excluded: tally.excluded.sorted { $0.test.enumerated < $1.test.enumerated },
            undecided: tally.undecided.sorted { $0.enumerated < $1.enumerated },
            undecidedInGroups: tally.undecidedInGroups.filter(tally.undecided.contains).sorted { $0.enumerated < $1.enumerated },
            unclaimed: tally.unclaimed,
            outsideScope: population.outside,
            notes: population.notes + tally.notes(match) + iterationNotes(outcomes)
        )
        reconciliation.compiledOut = population.compiledOut.sorted { $0.enumerated < $1.enumerated }
        reconciliation.skipped = tally.skippedTests.sorted { $0.enumerated < $1.enumerated }
        return reconciliation
    }
}

// MARK: - The expected set

private extension RunReconciler {
    /// What the index declares, split by what each declaration promises about the run and bounded by the run's own container.
    struct Population {
        var expected: Set<TestIdentifier> = []
        var conditional: Set<TestIdentifier> = []
        var excluded: Set<TestIdentifier> = []
        var outside: [RunReconciliation.OutsideScope] = []
        var compiledOut: [TestIdentifier] = []
        var notes: [String] = []

        /// The tests whose declaration carries a `@Test("…")` literal, under the name the log prints them by, which is the only thing that can say whose an ending carrying one is.
        var displayNames: [String: [TestIdentifier]] = [:]

        /// The quoted name each such test logs under, the other way round, so a start line under it can be read as that test's.
        var logNames: [TestIdentifier: String] = [:]

        /// The compiled-out tests carrying such a literal, under it, so a line under it can prove one compiled.
        var compiledOutLogNames: [String: [TestIdentifier]] = [:]

        /// Every test in scope, a file-scope one under ``PackageShardPlanner/fileScopeType``, which is the population a reported name is matched against.
        var identified: [TestIdentifier] {
            Array(expected.union(conditional).union(excluded))
        }
    }

    /// The population, with `provenCompiled` — compiled-out tests the log printed a line for — owed as compiled tests are.
    static func population(of inventory: TestInventory, in scope: RunReconciliation.Scope, provenCompiled: Set<TestIdentifier> = []) -> Population {
        var population = Population()
        let admitted = Set(scope.targets)
        var outside: [String: Int] = [:]

        for test in inventory.tests {
            guard admitted.contains(test.target) else {
                outside[test.target, default: 0] += 1
                continue
            }
            guard let identifier = reconciledIdentifier(of: test) else {
                continue
            }
            // A test the platform provably never compiles is lifted out and named; one inside a condition the host cannot
            // decide is owed an ending as a conditional test is, so an ending counts it and silence leaves it undecided.
            let proven = provenCompiled.contains(identifier)
            if case .compiledOut = test.compilation, !proven {
                population.compiledOut.append(identifier)
                if let logName = test.logName {
                    population.compiledOutLogNames[logName, default: []].append(identifier)
                }
                continue
            }
            let undecidedHere = test.compilation != .compiled && !proven
            switch test.disposition {
            case .runs, .disabled, .skips:
                if undecidedHere {
                    population.conditional.insert(identifier)
                } else {
                    population.expected.insert(identifier)
                }
            case .conditional:
                population.conditional.insert(identifier)
            case .excludedByXCTFail:
                population.excluded.insert(identifier)
            }
            if let logName = test.logName {
                population.displayNames[logName, default: []].append(identifier)
                population.logNames[identifier] = logName
            }
        }

        population.displayNames = population.displayNames.mapValues { $0.sorted { $0.enumerated < $1.enumerated } }
        population.outside = outside.map { RunReconciliation.OutsideScope(target: $0.key, declared: $0.value) }
            .sorted { $0.target < $1.target }
        population.notes = notes(scope: scope, inventory: inventory)
        // A test `#if` and `#else` both declare is one identifier, which the compiled clause already owes.
        let reconciled = Set(population.identified)
        population.compiledOut.removeAll(where: reconciled.contains)
        return population
    }

    /// The compiled-out tests the log printed a line for under a name no compiled test claimed, by identifier or by a literal no compiled test carries: the line proves the clause compiled.
    static func provenCompiled(_ population: Population, unclaimed: [String]) -> Set<TestIdentifier> {
        guard !population.compiledOut.isEmpty else {
            return []
        }
        let proof = TestNameMatch.reconcile(expected: population.compiledOut, reported: unclaimed)
        var proven = Set(proof.named.filter { !$0.value.isEmpty }.keys).union(proof.byCountOnly.flatMap(\.expected))
        for name in unclaimed where population.displayNames[name] == nil {
            proven.formUnion(population.compiledOutLogNames[name] ?? [])
        }
        return proven
    }

    /// The identifier a test is reconciled under: its suite's, or ``PackageShardPlanner/fileScopeType`` for a test declared at file scope, which Swift Testing logs by its function or its literal as it does a suite's.
    ///
    /// Made from its three parts rather than parsed, so a raw-identifier function holding a `/` is one test and never a file-scope one.
    static func reconciledIdentifier(of test: DeclaredTest) -> TestIdentifier? {
        TestIdentifier(target: test.target, type: test.suite.isEmpty ? PackageShardPlanner.fileScopeType : test.suite, function: test.function)
    }

    /// What the answer owes about how the container was read.
    static func notes(scope: RunReconciliation.Scope, inventory: TestInventory) -> [String] {
        var notes: [String] = []
        if scope.conditionalTargets {
            notes.append("A .testTarget in \(scope.manifest) sits inside an #if, so the targets above are one configuration's rather than the package's.")
        }
        let guessed = inventory.guessedTargets.filter { scope.targets.contains($0) }
        if !guessed.isEmpty {
            notes.append("Module attribution was guessed for: \(guessed.sorted().joined(separator: ", ")). A count assembled from a guess can be wrong about which bundle a test is in.")
        }
        return notes
    }
}

// MARK: - Reading the run

private extension RunReconciler {
    /// The tests expected to report an ending: what ran, what failed, and what never reported at all.
    static func read(_ tests: Set<TestIdentifier>, outcomes: RunTestOutcomes, match: TestNameMatch, into tally: inout Tally) {
        for test in tests {
            tally.expected += 1
            let attempts = attempts(of: test, outcomes: outcomes, match: match)
            guard let last = RunTestOutcomes.lastAttempt(of: attempts) else {
                recordNoEnding(test, outcomes: outcomes, match: match, into: &tally)
                continue
            }
            tally.record(test, ending: last.ending)
            tally.recordDuplication(test, attempts: attempts)
        }
    }

    /// A test owed an ending that printed none: lost where its suite and run summaries vouch for it, and never reported otherwise.
    static func recordNoEnding(_ test: TestIdentifier, outcomes: RunTestOutcomes, match: TestNameMatch, into tally: inout Tally) {
        if lostItsResultLine(test, outcomes: outcomes, match: match) {
            tally.lost.append(test)
        } else {
            tally.missing.append(test)
        }
    }

    /// Whether `test`'s own result line was lost: it printed a Swift Testing start line and no ending inside a run whose summary passed, and that same run printed its suite's pass line.
    ///
    /// A suite ends only once every test in it has finished, and passes only where none of them failed, so the suite's pass line accounts for the test and the lost line hides no failure. It has to be the run the test started in: a run that crashed printed no summary, and another run's suite of the same printed name is another target's.
    static func lostItsResultLine(_ test: TestIdentifier, outcomes: RunTestOutcomes, match: TestNameMatch) -> Bool {
        guard outcomes.summariesVouch, let suite = printedSuiteName(of: test) else {
            return false
        }
        let names = match.named[test] ?? []
        return outcomes.swiftTestingRuns.contains { run in
            run.vouches(forSuite: suite) && names.contains { run.unfinished($0) > 0 }
        }
    }

    /// The name Swift Testing prints on the ending of the suite declaring `test`, which for a nested suite is its innermost type alone, or `nil` for a test no suite declares.
    static func printedSuiteName(of test: TestIdentifier) -> String? {
        guard test.type != PackageShardPlanner.fileScopeType else {
            return nil
        }
        return test.type.split(separator: ".").last.map(String.init)
    }

    /// How many of the group's start lines no ending followed that a run accounts for, counted only in runs whose summary passed, that printed a pass line for a suite declaring the name and a failing line for none of them.
    static func lostStarts(of ambiguity: TestNameMatch.Ambiguity, outcomes: RunTestOutcomes) -> Int {
        let suites = ambiguity.expected.map(printedSuiteName(of:))
        guard outcomes.summariesVouch, !suites.contains(nil) else {
            return 0
        }
        let printed = Set(suites.compactMap(\.self))
        return outcomes.swiftTestingRuns.reduce(0) { total, run in
            guard printed.contains(where: run.vouches(forSuite:)), !printed.contains(where: { run.suiteEndings[$0] == .failed }) else {
                return total
            }
            return total + ambiguity.reported.reduce(0) { $0 + run.unfinished($1) }
        }
    }

    /// A conditional test is decided at runtime, so the run decides it: one that reported an ending is counted like any other, and one that reported nothing is counted in neither direction rather than called missing.
    ///
    /// **A start line no ending followed is not nothing.** It proves the test compiled and its condition held, so the test is owed an ending as any other is: one that started and never ended is never reported, or lost where its suite and run summaries vouch for it. Left undecided, a test that crashed the process under an `#if DEBUG` reads as one the build left out, and the line reads green over a run that died.
    static func readConditional(_ tests: Set<TestIdentifier>, outcomes: RunTestOutcomes, match: TestNameMatch, population: Population, into tally: inout Tally) {
        for test in tests {
            let attempts = attempts(of: test, outcomes: outcomes, match: match)
            guard let last = RunTestOutcomes.lastAttempt(of: attempts) else {
                let names = (match.named[test] ?? []) + (population.logNames[test].map { [$0] } ?? [])
                guard names.contains(where: { unfinishedStarts(of: $0, outcomes: outcomes) > 0 }) else {
                    tally.undecided.append(test)
                    continue
                }
                tally.expected += 1
                recordNoEnding(test, outcomes: outcomes, match: match, into: &tally)
                continue
            }
            tally.expected += 1
            tally.record(test, ending: last.ending)
            tally.recordDuplication(test, attempts: attempts)
        }
    }

    /// A test whose body opens `XCTFail(…)` is switched off in source and reports as an ordinary failure, so it is lifted out of the arithmetic entirely and named with what the run made of it.
    static func readExcluded(_ tests: Set<TestIdentifier>, outcomes: RunTestOutcomes, match: TestNameMatch, into tally: inout Tally) {
        for test in tests {
            let attempts = attempts(of: test, outcomes: outcomes, match: match)
            tally.excluded.append(RunReconciliation.Excluded(test: test, ending: RunTestOutcomes.lastAttempt(of: attempts)?.ending))
        }
    }

    /// Groups one reported name could not be told apart by: enough endings is nothing missing, too few is a shortfall with no name to give, and more than the whole group could account for is a duplication with none.
    ///
    /// The endings are spent worst first, because nothing in the log says which of the group an ending belonged to: taking them in the order they were printed makes the verdict depend on whether the failure ran before or after the passes, and drops it entirely when it ran last.
    static func readCountOnly(_ match: TestNameMatch, population: Population, outcomes: RunTestOutcomes, into tally: inout Tally) {
        for ambiguity in match.byCountOnly {
            readByCount(ambiguity, population: population, outcomes: outcomes, into: &tally)
        }
    }

    /// One group reconciled by count, whichever name it could not be told apart by — a function name several tests declare, or a `@Test("…")` literal several tests share.
    ///
    /// **A conditional test in the group is owed an ending like the rest.** Its ending cannot be told from an unconditional one's, so leaving it out of the group while its ending still counts lets it stand in for a test that was lost, and a run that lost one reads green. So the group is owed an ending for every member: as many endings is every one of them run, and fewer is a shortfall whose sentence says how far the log can tell a skipped conditional test from a lost one — never green on the assumption that the skip was the conditional's. A group with no unconditional member is the exception, because nothing in it can have been lost: the run decides it as it decides a lone conditional test, counting what ended and nothing else. Its members the endings do not reach are undecided, as a lone conditional test that reported nothing is, and since the count cannot say which of them those are, every conditional member of the group is named undecided beside the note saying how many reported nothing.
    static func readByCount(_ ambiguity: TestNameMatch.Ambiguity, population: Population, outcomes: RunTestOutcomes, into tally: inout Tally) {
        let unconditional = ambiguity.expected.count { population.expected.contains($0) }
        let conditional = ambiguity.expected.count { population.conditional.contains($0) }
        let counted = unconditional + conditional
        if counted < ambiguity.expected.count {
            tally.notes.append("\(ambiguity.function): \(ambiguity.expected.count - counted) of the tests this name cannot tell apart are excluded in their declaration, so the group is reconciled over the \(counted) that are not.")
        }
        let endings = RunTestOutcomes.worstFirst(ambiguity.endings(in: outcomes))
        // A start no ending followed proves a member compiled and ran, so it counts as unconditional and the group is owed every ending.
        let started = ambiguity.reported.reduce(0) { $0 + unfinishedStarts(of: $1, outcomes: outcomes) }
        let group = CountedGroup(members: counted, conditional: conditional - min(conditional, started), endings: endings.count)
        tally.expected += group.owed
        tally.ran += group.ran
        for ending in endings.prefix(group.ran) {
            tally.count(ending)
        }
        if let note = group.unowedNote(function: ambiguity.function) {
            tally.notes.append(note)
            tally.undecided.append(contentsOf: ambiguity.expected.filter(population.conditional.contains))
            tally.undecidedInGroups.append(contentsOf: ambiguity.expected.filter(population.conditional.contains))
        }
        let surplus = endings.count - ambiguity.expected.count
        if surplus > 0 {
            tally.countOnlyDuplicated += surplus
            tally.notes.append("\(ambiguity.function): the run ended this name \(surplus) time\(surplus == 1 ? "" : "s") more than there are tests declaring it, which no retry explains, so the surplus is counted as duplicated with no name to give.")
        }
        guard group.missing > 0 else {
            return
        }
        let shortfall = ReconciliationShortfall(function: ambiguity.function, missing: group.missing, expected: group.owed, conditional: conditional)
        if !ambiguity.function.hasPrefix("\""), lostStarts(of: ambiguity, outcomes: outcomes) >= group.missing {
            tally.lostByCount.append(shortfall)
        } else {
            tally.shortfalls.append(shortfall)
        }
    }

    /// The endings that claimed no test in scope: a quoted display name joined to the test that declares it, and everything else stated rather than guessed onto a test.
    ///
    /// Swift Testing logs a test carrying `@Test("…")` under that display name, which matches no identifier, so the log shows an ending nobody claimed beside a test nobody reported on. The inventory holds the literal each test declares, so the join is made on it: the ending is that test's, its identity is confirmed rather than assumed, and it is counted like any other.
    ///
    /// **An ending is counted onto a test only where the log names that test.** A quoted ending whose literal names no test still unreported stays unclaimed — stated rather than counted — and the test that reported nothing stays missing. Spending one on a test the log never named is exactly how a crash is covered up: the test that never ran leaves `missing` on the strength of an ending that was never its, and a run that lost a test reads green.
    ///
    /// **A literal more than one unreported test declares is reconciled by count, as a function name several suites share is.** The log names none of them by anything else — not the suite, not the target — so as many endings as the group holds is every one of them run, and fewer is a shortfall with no name to give: claiming one of them on the literal names the other missing, which is a guess, and a false red whenever both ran.
    ///
    /// **A test still waiting on its literal is a missing one or a conditional one that reported nothing.** A conditional test that ran logs under its literal as surely as any other, so leaving it out of the join strands its ending unclaimed, and leaving it out of a shared group lets its ending stand in for a lost test's.
    static func readUnclaimed(_ match: TestNameMatch, population: Population, outcomes: RunTestOutcomes, into tally: inout Tally) {
        var claimed: Set<String> = []
        var shared: [String] = []

        for name in match.unclaimed where name.hasPrefix("\"") {
            let attempts = outcomes.attempts[name] ?? []
            guard let last = RunTestOutcomes.lastAttempt(of: attempts) else {
                continue
            }
            let declaring = (population.displayNames[name] ?? []).filter { tally.missing.contains($0) || tally.undecided.contains($0) }
            guard let test = declaring.first else {
                continue
            }
            // `read` counted a missing test as expected and `readConditional` counted an undecided one in neither
            // direction, so both leave where they stand and the join below counts each of them once.
            tally.expected -= declaring.count { tally.missing.contains($0) }
            tally.missing.removeAll { declaring.contains($0) }
            tally.undecided.removeAll { declaring.contains($0) }
            if declaring.count > 1 {
                readByCount(TestNameMatch.Ambiguity(sharedLiteral: name, declaredBy: declaring), population: population, outcomes: outcomes, into: &tally)
                shared.append(name)
            } else {
                tally.expected += 1
                tally.claim(test, ending: last.ending, attempts: attempts)
            }
            claimed.insert(name)
        }

        if let note = TestNameMatch.sharedLiteralNote(shared) {
            tally.notes.append(note)
        }
        tally.unclaimed = match.unclaimed.filter { !claimed.contains($0) }
    }

    /// What the answer owes about an iteration that ended fewer tests than the one before it, which is the shape a repeat that died part-way leaves.
    ///
    /// Every count stands on each test's last attempt, so a later iteration that stopped early leaves the tests it never reached counted by an earlier iteration's ending. Nothing in the log tells a repeat that lost its tail from a retry that re-ran only what failed — `(repetition N)` marks a repeat of everything, and no line marks a retry at all — so the asymmetry is stated rather than resolved.
    static func iterationNotes(_ outcomes: RunTestOutcomes) -> [String] {
        var endings: [Int: Int] = [:]
        for attempts in outcomes.attempts.values {
            for attempt in attempts {
                endings[attempt.iteration, default: 0] += 1
            }
        }
        let counted = endings.keys.sorted().map { (iteration: $0, endings: endings[$0] ?? 0) }
        guard let drop = zip(counted, counted.dropFirst()).first(where: { $1.endings < $0.endings }) else {
            return []
        }
        return ["Iteration \(drop.1.iteration) ended \(drop.1.endings) test\(drop.1.endings == 1 ? "" : "s") where iteration \(drop.0.iteration) ended \(drop.0.endings): a later iteration reporting fewer endings than an earlier one is what a repeat that stopped part-way leaves, and every count above stands on each test's last attempt whichever iteration printed it."]
    }

    /// How many start lines `name` printed that no ending followed: a Swift Testing name's counted per run, and none where a run also printed a line under it this reader cannot read; an XCTest name's as its starts beyond its endings.
    static func unfinishedStarts(of name: String, outcomes: RunTestOutcomes) -> Int {
        if outcomes.swiftTestingNames.contains(name) {
            return outcomes.swiftTestingRuns.reduce(0) { $0 + $1.unfinished(name) }
        }
        guard let tally = outcomes[name] else {
            return 0
        }
        return max(0, tally.started - tally.passed - tally.failed - tally.skipped)
    }

    static func attempts(of test: TestIdentifier, outcomes: RunTestOutcomes, match: TestNameMatch) -> [RunTestOutcomes.Attempt] {
        (match.named[test] ?? []).flatMap { outcomes.attempts[$0] ?? [] }
    }
}

// MARK: - The arithmetic

private extension RunReconciler {
    struct Tally {
        var expected = 0
        var ran = 0
        var passed = 0
        var failed = 0
        var skipped = 0
        var failedTests: [TestIdentifier] = []
        var skippedTests: [TestIdentifier] = []
        var missing: [TestIdentifier] = []
        var shortfalls: [ReconciliationShortfall] = []
        var lost: [TestIdentifier] = []
        var lostByCount: [ReconciliationShortfall] = []
        var duplicated: [RunReconciliation.Duplication] = []
        /// Endings a group reconciled by count printed beyond the tests declaring that name, which are duplications with no name to give.
        var countOnlyDuplicated = 0
        var excluded: [RunReconciliation.Excluded] = []
        var undecided: [TestIdentifier] = []
        /// The members of ``undecided`` that belong to an all-conditional group whose endings did not reach them all, which the count cannot tell from the members that reported.
        var undecidedInGroups: [TestIdentifier] = []
        var unclaimed: [String] = []
        var notes: [String] = []

        var counts: ReconciliationCounts {
            ReconciliationCounts(
                expected: expected,
                ran: ran,
                passed: passed,
                failed: failed,
                skipped: skipped,
                missing: missing.count + shortfalls.reduce(0) { $0 + $1.missing },
                duplicated: duplicated.count + countOnlyDuplicated,
                linesLost: lost.count + lostByCount.reduce(0) { $0 + $1.missing }
            )
        }

        mutating func count(_ ending: RunTestOutcomes.Ending) {
            switch ending {
            case .passed: passed += 1
            case .failed: failed += 1
            case .skipped: skipped += 1
            }
        }

        mutating func record(_ test: TestIdentifier, ending: RunTestOutcomes.Ending) {
            ran += 1
            count(ending)
            if ending == .failed {
                failedTests.append(test)
            }
            if ending == .skipped {
                skippedTests.append(test)
            }
        }

        /// Counts a test by an ending that named it under something other than its identifier: it reported after all, so it leaves `missing` and is counted like any other, a second ending inside one iteration included.
        mutating func claim(_ test: TestIdentifier, ending: RunTestOutcomes.Ending, attempts: [RunTestOutcomes.Attempt]) {
            missing.removeAll { $0 == test }
            record(test, ending: ending)
            recordDuplication(test, attempts: attempts)
        }

        mutating func recordDuplication(_ test: TestIdentifier, attempts: [RunTestOutcomes.Attempt]) {
            guard let repeated = RunTestOutcomes.repeatWithinAnIteration(of: attempts) else {
                return
            }
            duplicated.append(RunReconciliation.Duplication(test: test, iteration: repeated.iteration, endings: repeated.endings))
        }

        /// The sentences the arithmetic owes about itself, beside the ones the population owed about the tests it could not take in.
        func notes(_ match: TestNameMatch) -> [String] {
            var sentences = notes
            if let note = match.countOnlyNote {
                sentences.append(note)
            }
            if !unclaimed.isEmpty {
                sentences.append("\(unclaimed.count) ending\(unclaimed.count == 1 ? "" : "s") claimed no test the index declares in scope, which is stated rather than counted: an extra test running is not a reason to fail a run that otherwise adds up.")
            }
            return sentences
        }
    }
}
