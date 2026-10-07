//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the per-test failure history and the report `sift flakes` prints from it — above all the line that must never move: a run that recorded nothing about its failures is unknown, never a run where nothing failed.
@Suite(.temporaryDirectories)
struct RunFailureHistoryTests {
    // MARK: Fixtures

    private static func run(
        kind: String = "swift test",
        exit: Int = 0,
        root: String? = "/repo/a",
        failed: [String]? = nil,
        failedTotal: Int? = nil,
        day: String = "2026-08-20",
        tree: String? = nil,
        invocation: String = "all"
    ) -> String {
        var object: [String: Any] = ["kind": kind, "exit": exit, "ms": 100, "ts": "\(day)T10:00:00Z"]
        if let root {
            object["root"] = root
        }
        if let tree {
            object["tree"] = tree
            object["invocation"] = invocation
        }
        if let failed {
            object["failed"] = failed
            object["failed_total"] = failedTotal ?? failed.count
        }
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data ?? Data(), encoding: .utf8) ?? ""
    }

    private static func writeLog(_ lines: [String]) throws -> URL {
        let file = try TemporaryDirectory.make("flakes")
            .appendingPathComponent("flakes.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private static func history(_ lines: [String], root: String? = nil) throws -> RunFailureHistory {
        let file = try writeLog(lines)
        let scope = try LogScope.resolve(root, inLogsAt: [file]).get()
        return RunFailureHistory.of(RunScan.load(fileURL: file, scope: scope))
    }

    // MARK: Lines written before the field existed

    /// Every entry written before the field existed parses, and every one of them is unknown.
    ///
    /// This is the failure the whole design is arranged around: read as "no test failed", a log full of old lines would answer "this has never failed before" about every test in it — and a wrong answer of that shape is worse than no answer, because it is the one that gets believed.
    @Test
    func aRunRecordedBeforeTheFieldExistedIsUnknownAndNeverAPass() throws {
        let history = try Self.history([
            Self.run(exit: 1),
            Self.run(exit: 0),
            Self.run(kind: "xcodebuild", exit: 65),
        ])

        #expect(history.measured == 0)
        #expect(history.unrecorded == 3)
        #expect(history.unknownTree.isEmpty)
    }

    /// Half a pair is not a measurement: names with no count beside them cannot say whether they are the whole list.
    @Test
    func namesWithoutTheirCountAreUnknown() throws {
        let file = try Self.writeLog([
            #"{"exit":1,"failed":["aTest()"],"kind":"swift test","ms":1,"ts":"2026-08-20T10:00:00Z"}"#,
        ])

        let history = RunFailureHistory.of(RunScan.load(fileURL: file))

        #expect(history.measured == 0)
        #expect(history.unrecorded == 1)
    }

    /// The report says the log could not answer, and says how much of it could not.
    @Test
    func theReportOverAnOlderLogSaysItMeasuredNothing() throws {
        let file = try Self.writeLog([Self.run(exit: 1), Self.run(exit: 0)])

        let rendered = RunFailureHistoryReport.render(fileURL: file, redactor: nil)

        #expect(rendered.contains("no run has recorded which tests failed"))
        #expect(rendered.contains("2 runs recorded nothing about which tests failed"))
        #expect(rendered.contains("Unknown, and counted in nothing above."))
    }

    // MARK: Counting

    /// The measurement: how many recorded runs named the test, out of how many recorded anything at all.
    @Test
    func aTestWithBothOutcomesIsCountedAgainstItsPopulation() throws {
        let history = try Self.history([
            Self.run(exit: 1, failed: ["theWellIsATarget()"], day: "2026-08-20"),
            Self.run(exit: 0, failed: []),
            Self.run(exit: 0, failed: []),
            Self.run(exit: 1, failed: ["theWellIsATarget()"], day: "2026-08-24"),
            Self.run(exit: 0, failed: []),
        ])

        let population = try #require(history.unknownTree.first)
        let test = try #require(population.tests.first)

        #expect(history.measured == 5)
        #expect(population.runs == 5)
        #expect(test.name == "theWellIsATarget()")
        #expect(test.failed == 2)
        #expect(test.lastFailed == "2026-08-24")
    }

    /// A test named by every run that could name it has failed and never passed, which is a broken test rather than an inconsistent one.
    @Test
    func aTestThatFailedInEveryRecordedRunIsNotListed() throws {
        let history = try Self.history([
            Self.run(exit: 1, failed: ["alwaysBroken()"]),
            Self.run(exit: 1, failed: ["alwaysBroken()"]),
        ])

        #expect(history.measured == 2)
        #expect(history.unknownTree.isEmpty)
    }

    /// The denominator is the runs of the same command kind, because a `swift build` cannot fail a test.
    ///
    /// Nine build runs behind a test's fraction would read as nine runs it survived, which understates by an order of magnitude the one number this report exists to state.
    @Test
    func runsOfAnotherKindAreNotInTheDenominator() throws {
        let history = try Self.history([
            Self.run(kind: "swift test", exit: 1, failed: ["theWellIsATarget()"]),
            Self.run(kind: "swift test", exit: 0, failed: []),
            Self.run(kind: "swift build", exit: 0, failed: []),
            Self.run(kind: "swift build", exit: 0, failed: []),
        ])

        let population = try #require(history.unknownTree.first { $0.keys == ["swift test"] })

        #expect(history.measured == 4)
        #expect(population.runs == 2)
        #expect(population.tests.first?.failed == 1)
    }

    /// A run that withheld some of its failures can say a test failed and can never say one did not, so it is in neither half of a fraction.
    @Test
    func aRunThatCouldNotNameAllItsFailuresIsExcludedAndCounted() throws {
        let history = try Self.history([
            Self.run(exit: 1, failed: ["oneOfSeveral()"], failedTotal: 210),
            Self.run(exit: 0, failed: []),
            Self.run(exit: 1, failed: ["oneOfSeveral()"]),
        ])

        let population = try #require(history.unknownTree.first)

        #expect(history.incomplete == 1)
        #expect(history.measured == 2)
        #expect(population.runs == 2)
        #expect(population.tests.first?.failed == 1)
    }

    // MARK: A kind that does not name its action

    /// A hard regression must not be served as a flake, and the `xcodebuild` key cannot tell one from the other.
    ///
    /// The log files a build, a test, a clean and an archive under the single word `xcodebuild`, so a population read off that key mixes runs that ran the suite with runs that could not have. Here the test failed in **every** run that named a test at all — the shape this report excludes by design, as broken rather than inconsistent — and twenty builds sharing its key made 4 short of 24. Listed, it reads `4 of 24` and the reader reruns instead of investigating.
    @Test
    func aTestThatFailedInEveryXcodebuildTestRunIsNotServedAsAFlake() throws {
        let builds = (0 ..< 20).map { _ in Self.run(kind: "xcodebuild", exit: 0, failed: []) }
        let testRuns = (0 ..< 4).map { _ in Self.run(kind: "xcodebuild", exit: 65, failed: ["theSummaryScreenReads()"]) }

        let history = try Self.history(builds + testRuns)

        #expect(history.unknownTree.isEmpty)
        #expect(history.measured == 0)
        #expect(history.conflated == 24)
    }

    /// The kinds that do name their action keep their listing; the one that does not is counted beside it and listed nowhere.
    @Test
    func theReportKeepsThePopulationItHasAndCountsTheRunsItSetAside() throws {
        let file = try Self.writeLog(
            (0 ..< 10).map { _ in Self.run(kind: "xcodebuild", exit: 0, failed: []) }
                + [Self.run(kind: "xcodebuild", exit: 65, failed: ["theSummaryScreenReads()"])]
                + [
                    Self.run(kind: "swift test", exit: 1, failed: ["theWellIsATarget()"], day: "2026-08-20"),
                    Self.run(kind: "swift test", exit: 0, failed: [], day: "2026-08-21"),
                ]
        )

        let rendered = RunFailureHistoryReport.render(fileURL: file, redactor: nil)

        #expect(rendered.contains("1 test has both failed and passed, over 2 runs that recorded which tests failed"))
        #expect(rendered.contains("swift test — 2 runs:"))
        #expect(rendered.contains("11 runs recorded which tests failed under a command kind that does not say which action it ran"))
        #expect(rendered.contains("Counted in nothing above."))
        // Not printed under a smaller denominator either: a count the log cannot support is not printed.
        #expect(!rendered.contains("xcodebuild —"))
        #expect(!rendered.contains("theSummaryScreenReads()"))
    }

    // MARK: The key that names its action

    /// A line written before the action was recorded stays counted out, beside the newer lines that do carry one.
    ///
    /// The bare word is not a legacy shape that ages out of the code: it is still what an invocation whose action argv leaves in doubt files under. So the two shapes have to coexist in one log for as long as the log exists — the older half counted out loud, the newer half measured — and nothing may read the older half as a run of whichever action the newer half happened to name.
    @Test
    func anOlderLineWithNoActionStaysConflatedBesideOnesThatHaveOne() throws {
        let history = try Self.history(
            (0 ..< 6).map { _ in Self.run(kind: "xcodebuild", exit: 0, failed: []) }
                + [
                    Self.run(kind: "xcodebuild test", exit: 65, failed: ["theSummaryScreenReads()"]),
                    Self.run(kind: "xcodebuild test", exit: 0, failed: []),
                    Self.run(kind: "xcodebuild test", exit: 0, failed: []),
                ]
        )

        let population = try #require(history.unknownTree.first)

        #expect(history.conflated == 6)
        #expect(history.measured == 3)
        #expect(population.keys == ["xcodebuild test"])
        #expect(population.runs == 3)
        #expect(population.tests.first?.failed == 1)
    }

    /// A build cannot fail a test, so it is not in one's denominator — the reason the key names the action.
    ///
    /// It is the same rule `swift build` answers to, and with the key naming the action it reaches `xcodebuild` too: five builds sharing a tool name with two test runs would make a test that failed in half of them read as 1 of 7.
    @Test
    func anXcodebuildBuildIsNotInATestsDenominator() throws {
        let history = try Self.history(
            (0 ..< 5).map { _ in Self.run(kind: "xcodebuild build", exit: 0, failed: []) }
                + [
                    Self.run(kind: "xcodebuild test", exit: 65, failed: ["theSummaryScreenReads()"]),
                    Self.run(kind: "xcodebuild test", exit: 0, failed: []),
                ]
        )

        let population = try #require(history.unknownTree.first { $0.keys == ["xcodebuild test"] })

        // Every run is measured — a build is a population of its own, not a run set aside — and none of
        // the five stands behind the test's fraction.
        #expect(history.conflated == 0)
        #expect(history.measured == 7)
        #expect(population.runs == 2)
        #expect(population.tests.first?.failed == 1)
        // And the build population lists nothing, so it is not a heading over an empty listing either.
        #expect(history.unknownTree.contains { $0.keys.contains("xcodebuild build") } == false)
    }

    /// `test` and `test-without-building` execute the same suite the same way, so they are one population and the heading says both.
    ///
    /// `build-for-testing` and `test-without-building` are how a CI script splits one test run in two; counting the halves separately would leave a test that failed in every `test-without-building` run excluded as broken and its `xcodebuild test` history standing beside it as a different number.
    @Test
    func theTwoActionsThatExecuteTestsShareOnePopulationAndTheHeadingNamesBoth() throws {
        let file = try Self.writeLog([
            Self.run(kind: "xcodebuild test", exit: 65, failed: ["theSummaryScreenReads()"], day: "2026-08-26"),
            Self.run(kind: "xcodebuild test", exit: 0, failed: [], day: "2026-08-27"),
            Self.run(kind: "xcodebuild test-without-building", exit: 0, failed: [], day: "2026-08-27"),
            Self.run(kind: "xcodebuild build-for-testing", exit: 0, failed: [], day: "2026-08-27"),
        ])
        let history = RunFailureHistory.of(RunScan.load(fileURL: file))

        let population = try #require(history.unknownTree.first)
        let rendered = RunFailureHistoryReport.render(fileURL: file, redactor: nil)

        #expect(population.keys == ["xcodebuild test", "xcodebuild test-without-building"])
        #expect(population.runs == 3)
        #expect(population.tests.first?.failed == 1)
        // The heading names the spellings the fraction is actually over, rather than standing three runs
        // under whichever of the two the fold was identified by.
        #expect(rendered.contains("xcodebuild test, xcodebuild test-without-building — 3 runs:"))
        #expect(rendered.contains("1 of 3   last 2026-08-26"))
    }

    /// A log of nothing but the ambiguous kind says which silence it is, rather than one that its own coverage line contradicts.
    ///
    /// "No run has recorded which tests failed" printed four lines above "11 runs recorded which tests failed …" is the report refuting itself, and the reader has no way to tell which sentence to believe.
    @Test
    func aLogOfOnlyTheAmbiguousKindSaysWhyRatherThanThatNothingWasRecorded() throws {
        let file = try Self.writeLog([
            Self.run(kind: "xcodebuild", exit: 65, failed: ["alphaBreaks()"]),
            Self.run(kind: "xcodebuild", exit: 0, failed: []),
        ])

        let rendered = RunFailureHistoryReport.render(fileURL: file, redactor: nil)

        #expect(rendered.contains("no run recorded which tests failed under a kind that says which action it ran"))
        #expect(!rendered.contains("no run has recorded which tests failed"))
        #expect(rendered.contains("2 runs recorded which tests failed under a command kind that does not say which action it ran"))
    }

    /// Scoping to a repository narrows the population as well as the failures, so the fraction stays over one directory's runs.
    @Test
    func aRootNarrowsBothHalvesOfTheFraction() throws {
        let history = try Self.history(
            [
                Self.run(exit: 1, root: "/repo/a", failed: ["theWellIsATarget()"]),
                Self.run(exit: 0, root: "/repo/a", failed: []),
                Self.run(exit: 0, root: "/repo/b", failed: []),
                Self.run(exit: 0, root: "/repo/b", failed: []),
            ],
            root: "/repo/a"
        )

        #expect(history.measured == 2)
        #expect(history.unknownTree.first?.runs == 2)
    }

    // MARK: Rendering

    /// The row states the count, its denominator and the day — and the block under it states that none of that is a diagnosis.
    @Test
    func theReportStatesTheCountsAndRefusesToCallThemADiagnosis() throws {
        let file = try Self.writeLog([
            Self.run(exit: 1, failed: ["theWellIsATarget()"], day: "2026-08-20"),
            Self.run(exit: 0, failed: [], day: "2026-08-21"),
            Self.run(exit: 0, failed: [], day: "2026-08-22"),
        ])

        let rendered = RunFailureHistoryReport.render(fileURL: file, redactor: nil)

        #expect(rendered.contains("1 test has both failed and passed, over 3 runs that recorded which tests failed"))
        #expect(rendered.contains("swift test — 3 runs:"))
        #expect(rendered.contains("1 of 3   last 2026-08-20   theWellIsATarget()"))
        // The caveat speaks with the row's own numbers, so it is about the reading being made rather than
        // an invented example beside it.
        #expect(rendered.contains("These are counts, not a diagnosis: a test named by 1 of 3 runs may fail at random"))
        // The word the whole register turns on: the report never applies it to a test.
        #expect(rendered.lowercased().contains("is flaky") == false)
    }

    /// Nothing found is reported as nothing found, over the population it was looked for in.
    @Test
    func aLogWhereNoTestHasBothOutcomesSaysSoWithItsPopulation() throws {
        let file = try Self.writeLog([Self.run(exit: 0, failed: []), Self.run(exit: 0, failed: [])])

        let rendered = RunFailureHistoryReport.render(fileURL: file, redactor: nil)

        #expect(rendered.contains("no test has both failed and passed — measured over 2 runs that recorded which tests failed"))
    }

    /// Test names are code identifiers from private repositories, so the default report carries pseudonyms and `--unredact` carries the names.
    @Test
    func aTestsNameIsPseudonymisedByDefault() throws {
        let file = try Self.writeLog([
            Self.run(exit: 1, failed: ["theWellIsATarget()"]),
            Self.run(exit: 0, failed: []),
        ])

        let redacted = RunFailureHistoryReport.render(fileURL: file, redactor: Redactor(salt: Data("salt".utf8)))
        let plain = RunFailureHistoryReport.render(fileURL: file, redactor: nil)

        #expect(redacted.contains("theWellIsATarget()") == false)
        #expect(redacted.contains("test-"))
        #expect(plain.contains("theWellIsATarget()"))
    }

    /// A redacted name like `test-9b3bcb` identifies nothing on its own — the reader needs to be told the flag exists, once for the whole answer rather than once beside every row.
    @Test
    func aRedactedReportHintsAtUnredactExactlyOnce() throws {
        let file = try Self.writeLog([
            Self.run(exit: 1, failed: ["theWellIsATarget()", "anotherOne()"]),
            Self.run(exit: 0, failed: []),
        ])

        let redacted = RunFailureHistoryReport.render(fileURL: file, redactor: Redactor(salt: Data("salt".utf8)))
        let plain = RunFailureHistoryReport.render(fileURL: file, redactor: nil)

        #expect(redacted.components(separatedBy: "names redacted — --unredact to show them").count == 2)
        #expect(plain.contains("--unredact") == false)
    }

    /// A root the log has never seen refuses and lists what it does hold, rather than reporting a count under a name it guessed at.
    @Test
    func anUnmatchedRootRefusesAndNamesTheRootsItHolds() throws {
        let file = try Self.writeLog([Self.run(exit: 0, root: "/repo/a", failed: [])])

        let rendered = RunFailureHistoryReport.render(fileURL: file, root: "nowhere", redactor: nil)

        #expect(rendered.contains("nothing recorded for a root matching nowhere"))
        #expect(rendered.contains("/repo/a"))
    }

    // MARK: Trees

    /// A test that failed and passed on identical bytes is the same-tree tier, counted over only the runs of that tree.
    @Test
    func aTestWithBothOutcomesOnTheSameBytesIsTheSameTreeTier() throws {
        let history = try Self.history([
            Self.run(exit: 1, failed: ["theWellIsATarget()"], day: "2026-08-21", tree: "aaaa"),
            Self.run(exit: 0, failed: [], tree: "aaaa"),
            Self.run(exit: 0, failed: [], tree: "aaaa"),
            Self.run(exit: 0, failed: [], tree: "bbbb"),
        ])

        let population = try #require(history.sameTree.first)
        let test = try #require(population.tests.first)

        #expect(test.name == "theWellIsATarget()")
        #expect(test.failed == 1)
        #expect(test.runs == 3)
        #expect(test.trees == 1)
        #expect(test.lastFailed == "2026-08-21")
        #expect(population.runs == 4)
        #expect(history.otherTrees.isEmpty)
        #expect(history.unknownTree.isEmpty)
    }

    /// A test that failed only on trees it never passed on is the second tier — what a deliberate red looks like — and never the first.
    @Test
    func aTestThatFailedOnlyOnTreesItNeverPassedOnIsTheSecondTier() throws {
        let history = try Self.history([
            Self.run(exit: 1, failed: ["theWellIsATarget()"], tree: "aaaa"),
            Self.run(exit: 1, failed: ["theWellIsATarget()"], tree: "aaaa"),
            Self.run(exit: 0, failed: [], tree: "bbbb"),
        ])

        let test = try #require(history.otherTrees.first?.tests.first)

        #expect(history.sameTree.isEmpty)
        #expect(test.failed == 2)
        #expect(test.runs == 3)
        #expect(test.trees == nil)
    }

    /// A run with no tree is unknown: it joins neither tier, and its tests are read apart over the runs like it.
    @Test
    func aRunWithNoTreeIsUnknownAndInNeitherTier() throws {
        let history = try Self.history([
            Self.run(exit: 1, failed: ["theWellIsATarget()"]),
            Self.run(exit: 0, failed: []),
            Self.run(exit: 0, failed: [], tree: "aaaa"),
        ])

        let test = try #require(history.unknownTree.first?.tests.first)

        #expect(history.sameTree.isEmpty)
        #expect(history.otherTrees.isEmpty)
        #expect(history.treeless == 2)
        #expect(history.measured == 3)
        #expect(test.failed == 1)
        #expect(test.runs == 2)
    }

    /// The report states the same-tree tier first, then the second under its caveat, then the unknown runs apart, counted the way unrecorded ones are.
    @Test
    func theReportStatesTheSameTreeTierFirstAndTheUnknownApart() throws {
        let file = try Self.writeLog([
            Self.run(exit: 1, failed: ["theWellIsATarget()"], tree: "aaaa"),
            Self.run(exit: 0, failed: [], tree: "aaaa"),
            Self.run(exit: 1, failed: ["theGridReflows()"], tree: "bbbb"),
            Self.run(exit: 1, failed: ["theGridReflows()"]),
            Self.run(exit: 0, failed: []),
        ])

        let rendered = RunFailureHistoryReport.render(fileURL: file, redactor: nil)
        let same = try #require(rendered.range(of: "same tree — failed and passed on identical bytes under one command line, over 3 runs that recorded their tree:"))
        let other = try #require(rendered.range(of: "failed only on trees, or under command lines, it never passed on:"))
        let unknown = try #require(rendered.range(of: "tree unknown — runs that recorded no tree, read together:"))

        #expect(same.upperBound < other.lowerBound)
        #expect(other.upperBound < unknown.lowerBound)
        #expect(rendered.contains("1 of 2 on one tree   last 2026-08-20   theWellIsATarget()"))
        #expect(rendered.contains("1 of 3   last 2026-08-20   theGridReflows()"))
        #expect(rendered.contains("a deliberate red"))
        #expect(rendered.contains("2 runs recorded which tests failed but not the tree they ran on"))
        #expect(rendered.contains("failed and passed on the same bytes"))
    }

    /// A narrower command on the same tree is no pass of a test it may never have run: the log keeps failures and not the tests that ran, so outcomes on one tree are compared only under one command line.
    @Test
    func aNarrowerRunOnTheSameTreeIsNoPassOfATestItDidNotRun() throws {
        let history = try Self.history([
            Self.run(exit: 1, failed: ["theWellIsATarget()"], tree: "cccc", invocation: "all"),
            Self.run(exit: 0, failed: [], tree: "cccc", invocation: "steady"),
        ])

        #expect(history.sameTree.isEmpty)
        #expect(history.otherTrees.first?.tests.first?.name == "theWellIsATarget()")
    }

    /// A line that recorded its tree and not its command line cannot say which runs ran the same tests, so it is unknown rather than known.
    @Test
    func aTreeWithoutItsCommandLineIsUnknown() throws {
        let file = try Self.writeLog([
            #"{"kind":"swift test","exit":1,"ms":100,"ts":"2026-08-20T10:00:00Z","root":"/repo/a","tree":"cccc","failed":["theWellIsATarget()"],"failed_total":1}"#,
            #"{"kind":"swift test","exit":0,"ms":100,"ts":"2026-08-20T10:00:00Z","root":"/repo/a","tree":"cccc","failed":[],"failed_total":0}"#,
        ])
        let history = RunFailureHistory.of(RunScan.load(fileURL: file))

        #expect(history.sameTree.isEmpty)
        #expect(history.treeless == 2)
    }
}
