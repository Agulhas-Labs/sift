//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Every test `swift test list` prints is expected and lands in exactly one shard, whether declared at file scope or in a nested suite.
struct PackageShardListingTests {
    /// What `swift test list` printed for a package with a file-scope test, a named suite holding a nested suite, and a plain suite.
    private static var listing: String {
        """
        LibTests.Outer/Inner/innerTest()
        LibTests.Outer/outerTest()
        LibTests.PlainA/a1()
        LibTests.freeStanding()
        """
    }

    @Test func everyListedTestIsExpectedIncludingFileScopeAndNestedOnes() throws {
        let listed = try PackageShardPlanner.listed(Self.listing + "\n\n")

        #expect(listed.map(\.enumerated) == [
            "LibTests/Outer.Inner/innerTest()",
            "LibTests/Outer/outerTest()",
            "LibTests/PlainA/a1()",
            "LibTests/\(PackageShardPlanner.fileScopeType)/freeStanding()",
        ])
        #expect(Set(listed.map(PackageShardPlanner.suite(of:))) == ["LibTests.Outer", "LibTests.PlainA", "LibTests.freeStanding()"])
    }

    @Test func aFileScopeTestIsPlannedOnceAndFilteredByItsOwnName() throws {
        let listed = try PackageShardPlanner.listed(Self.listing)
        let plan = PackageShardPlanner.plan(tests: listed, shards: 3) { _ in nil }
        let free = try #require(listed.first { $0.type == PackageShardPlanner.fileScopeType })
        let holding = plan.shards.filter { $0.tests.contains(free) }

        #expect(plan.testCount == listed.count)
        #expect(holding.count == 1)
        let regex = try Regex(PackageShardPlanner.filter(for: [free]))
        #expect("LibTests.freeStanding()/Tests.swift:4:2".contains(regex))
        #expect(!"LibTests.freeStandingToo()/Tests.swift:5:2".contains(regex))
        #expect(!"LibTests.freeStanding(value:)/Tests.swift:6:2".contains(regex))
        #expect(!"LibTests.PlainA/a1()/Tests.swift:9:6".contains(regex))
    }

    @Test func aNamedSuiteHoldingANestedSuiteReconcilesEveryEnding() throws {
        let listed = try PackageShardPlanner.listed(Self.listing)
        let plan = PackageShardPlanner.plan(tests: listed, shards: 1) { _ in nil }
        var read = RunTestOutcomes()
        for line in [
            "◇ Suite \"Some words\" started.",
            "✔ Test innerTest() passed after 0.001 seconds.",
            "✔ Test outerTest() passed after 0.001 seconds.",
            "✔ Suite Inner passed after 0.001 seconds.",
            "✔ Suite \"Some words\" passed after 0.001 seconds.",
            "✔ Test a1() passed after 0.001 seconds.",
            "✔ Test freeStanding() passed after 0.001 seconds.",
            "✔ Test run with 4 tests in 3 suites passed after 0.001 seconds.",
        ] {
            read.read(line)
        }
        let merged = ShardMerge.reconcile(plan: plan, outcomes: [ShardOutcome(outcomes: read, exitCode: 0, wallSeconds: 1, logPath: "log")])

        #expect(merged.counts.expected == 4)
        #expect(merged.counts.ran == 4)
        #expect(merged.counts.passed == 4)
        #expect(merged.missing.isEmpty)
        #expect(!merged.notes.contains { $0.contains("named no test") })
        #expect(merged.isGreen)
    }

    @Test func groupsReconciledByCountInSeveralShardsAreNamedInOneSentence() throws {
        let listed = try PackageShardPlanner.listed("LibTests.PlainA/check()\nLibTests.PlainA/Deep/check()\nLibTests.PlainB/check()\nLibTests.PlainB/Deep/check()")
        let plan = PackageShardPlanner.plan(tests: listed, shards: 2) { _ in nil }
        let outcomes = plan.shards.map { _ in
            var read = RunTestOutcomes()
            read.read("✔ Test check() passed after 0.001 seconds.")
            read.read("✔ Test check() passed after 0.001 seconds.")
            return ShardOutcome(outcomes: read, exitCode: 0, wallSeconds: 1, logPath: "log")
        }
        let merged = ShardMerge.reconcile(plan: plan, outcomes: outcomes)
        let notes = merged.notes.filter { $0.contains("Reconciled by count only") }

        #expect(merged.counts.passed == 4)
        #expect(notes.count == 1)
        #expect(notes.first?.hasPrefix("Reconciled by count only — shard 1: check; shard 2: check.") == true)
    }

    @Test func aFileScopeTestLoggingUnderItsLiteralIsJoinedThroughTheInventory() throws {
        let declaration = DeclaredTest(
            target: "LibTests",
            targetWasGuessed: false,
            suite: "",
            function: "freeWithName()",
            style: .swiftTesting,
            displayName: "A free test with words",
            disposition: .runs,
            path: "Tests/LibTests/Tests.swift",
            line: 6
        )
        let declared = PackageShardPlanner.declared(in: TestInventory(tests: [declaration], guessedTargets: []))
        let listed = try PackageShardPlanner.listed("LibTests.freeWithName()")
        let plan = PackageShardPlanner.plan(tests: listed, shards: 1, displayNames: declared.displayNames) { _ in nil }
        var read = RunTestOutcomes()
        read.read("✔ Test \"A free test with words\" passed after 0.001 seconds.")
        let merged = ShardMerge.reconcile(plan: plan, outcomes: [ShardOutcome(outcomes: read, exitCode: 0, wallSeconds: 1, logPath: "log")])

        #expect(try declared.displayNames["\"A free test with words\""] == [#require(listed.first)])
        #expect(merged.counts.passed == 1)
        #expect(merged.missing.isEmpty)
    }

    @Test func aLockWaitGluedOntoTheFirstTestRefusesTheListingNamingTheLine() {
        let glued = "Another instance of SwiftPM (PID: 4242) is already running using '/src/Lib/.build', waiting until that process has finished execution...LibTests.XA/testOne"
        do {
            _ = try PackageShardPlanner.listed("\(glued)\nLibTests.XA/testTwo\n")
            Issue.record("a line naming no test was dropped rather than refused")
        } catch {
            #expect("\(error)".contains("`\(glued)`"))
            #expect("\(error)".contains("refused"))
        }
    }

    @Test func aRawIdentifierIsSplitOnlyOutsideItsBackticks() throws {
        let listed = try PackageShardPlanner.listed("LibTests.Solo/`a//b`()\nLibTests.Raw/`x/y`()\nLibTests.Raw/`a.b`()\n")

        #expect(listed.map(\.type) == ["Solo", "Raw", "Raw"])
        #expect(listed.map(\.function) == ["`a//b`()", "`x/y`()", "`a.b`()"])
        #expect(Set(listed.map(PackageShardPlanner.suite(of:))) == ["LibTests.Solo", "LibTests.Raw"])
    }

    @Test func rawIdentifierTestsAreJoinedToTheQuotedNamesTheirLogUses() throws {
        let listed = try PackageShardPlanner.listed("LibTests.Solo/`a//b`()\nLibTests.Raw/`a.b`()\nLibTests.Raw/`spaced name`()\nLibTests.Raw/`x/y`()\nLibTests.Raw/plain()")
        let plan = PackageShardPlanner.plan(tests: listed, shards: 2) { _ in nil }
        let outcomes = plan.shards.map { shard in
            var read = RunTestOutcomes()
            for test in shard.tests {
                read.read("✔ Test \(PackageShardPlanner.rawIdentifierLogName(of: test) ?? test.function) passed after 0.001 seconds.")
            }
            return ShardOutcome(outcomes: read, exitCode: 0, wallSeconds: 1, logPath: "log")
        }
        let merged = ShardMerge.reconcile(plan: plan, outcomes: outcomes)

        #expect(PackageShardPlanner.rawIdentifierLogName(of: listed[0]) == "\"a//b\"")
        #expect(merged.counts.expected == 5)
        #expect(merged.counts.passed == 5)
        #expect(merged.missing.isEmpty)
        #expect(merged.isGreen)
    }

    @Test func theListingIsReadFromStandardOutputAlone() throws {
        let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let listing = try PackageTestRun.standardOutput(
            of: ["sh", "-c", "printf 'waiting until that process has finished execution...' >&2; echo LibTests.XA/testOne"],
            in: here,
            children: SetAsideChildren(),
            log: nil
        )

        #expect(listing.exitCode == 0)
        #expect(String(bytes: listing.output, encoding: .utf8) == "LibTests.XA/testOne\n")
    }

    @Test func aShardClosedOnlyIfEverySwiftTestingProcessItOpenedPrintedItsClosingLine() {
        let report = { (lines: [String]) in
            var filter = RunOutputFilter(invokedAs: ["swift", "test"])
            for line in lines {
                filter.consume(line: line)
            }
            return filter.finish(exitCode: 1)
        }
        let opened = "◇ Test run started."
        let closed = "✔ Test run with 1 test in 1 suite passed after 0.001 seconds."

        #expect(ShardRunner.closedEverySwiftTestingRun(report([opened, closed])))
        #expect(ShardRunner.closedEverySwiftTestingRun(report([opened, closed, opened, closed])))
        #expect(!ShardRunner.closedEverySwiftTestingRun(report([opened, closed, opened])))
        #expect(!ShardRunner.closedEverySwiftTestingRun(report([opened])))
    }
}
