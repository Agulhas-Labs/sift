//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A test the index declares that the listing never named is owed only where the build compiled it: not one every complete later listing also lacks, as one an `#if` compiled out does.
@Suite(.temporaryDirectories)
struct PackageShardNeverListedConfirmationTests {
    /// The inventory of `files`, indexed from a repository written at `root` so the declarations' own files can be read back.
    private static func inventory(_ files: [(path: String, source: String)]) throws -> (inventory: TestInventory, root: URL) {
        let root = try TemporaryDirectory.make("never-listed-confirmation")
        let store = try TestSources.makeStore()
        let parsed = try files.map { try TestSources.parsed($0.source, path: $0.path, in: root) }
        try store.replaceFiles(parsed) { path in
            (path.split(separator: "/").first.map(String.init) ?? path, false)
        }
        return try (TestInventory.read(store: store, repositoryRoot: root), root)
    }

    @Test func aTestAnIfCompiledOutIsMissingFromEveryListingAndDropped() throws {
        let (inventory, root) = try Self.inventory([
            (
                "LibTests/AlphaTests.swift",
                """
                import Testing

                struct AlphaTests {
                    @Test func runs() {}
                    #if os(Linux)
                    @Test func linuxOnly() {}
                    #endif
                    #if canImport(UIKit)
                    @Test func phoneOnly() {}
                    #endif
                }

                #if false
                @Test func switchedOff() {}
                #endif
                """
            ),
            (
                "LibTests/LinuxTests.swift",
                """
                import XCTest

                #if os(Linux)
                final class LinuxTests: XCTestCase {
                    func testOnLinux() {}
                }
                #endif
                """
            ),
        ])
        let listed = try PackageShardPlanner.listed("LibTests.AlphaTests/runs()")

        let candidates = PackageShardPlanner.neverListed(declaredIn: inventory, listed: listed, repositoryRoot: root)
        let owed = PackageShardPlanner.confirmed(neverListed: candidates, listed: listed) { listed }.owed
        let (reconciliation, rendered) = Self.answer(listed: listed, neverListed: owed)

        #expect(inventory.tests.count == 5)
        #expect(candidates.map(\.function).sorted() == ["linuxOnly()", "phoneOnly()", "switchedOff()", "testOnLinux()"])
        #expect(owed.isEmpty)
        #expect(reconciliation.isGreen, "\(rendered)")
    }

    @Test func aTestInsideAnActiveIfThatTheFirstListingLostGoesRedByName() throws {
        let (inventory, root) = try Self.inventory([
            ("LibTests/AlphaTests.swift", "import Testing\n\nstruct AlphaTests {\n    @Test func runs() {}\n}\n"),
            ("LibTests/GatedTests.swift", "#if canImport(Testing)\nimport Testing\n\n@Test func gated() {}\n#endif\n"),
        ])
        let listed = try PackageShardPlanner.listed("LibTests.AlphaTests/runs()")
        let relisted = try PackageShardPlanner.listed("LibTests.AlphaTests/runs()\nLibTests.gated()")

        let owed = PackageShardPlanner.confirmed(
            neverListed: PackageShardPlanner.neverListed(declaredIn: inventory, listed: listed, repositoryRoot: root),
            listed: listed
        ) { relisted }.owed
        let (reconciliation, rendered) = Self.answer(listed: listed, neverListed: owed)

        #expect(owed.map(\.enumerated) == ["LibTests/(file scope)/gated()"])
        #expect(!reconciliation.isGreen)
        #expect(rendered.contains("\n  LibTests/(file scope)/gated()"))
    }

    /// A package whose `LibTests` declares `AlphaTests/one()` and, in `Fixtures/` — which its manifest excludes — the file-scope `fixtureTest()`.
    private static func excludedFixture() throws -> (inventory: TestInventory, root: URL) {
        try inventory([
            ("LibTests/AlphaTests.swift", "import Testing\n\nstruct AlphaTests {\n    @Test func one() {}\n}\n"),
            ("LibTests/Fixtures/Sample.swift", "import Testing\n\n@Test func fixtureTest() {}\n"),
        ])
    }

    /// The answer a one-shard run gives where every listed test passed, with `neverListed` as the plan's.
    private static func answer(listed: [TestIdentifier], neverListed: [TestIdentifier]) -> (reconciliation: ShardReconciliation, rendered: String) {
        var plan = PackageShardPlanner.plan(tests: listed, shards: 1) { _ in nil }
        plan.neverListed = neverListed
        return answer(plan)
    }

    /// The answer a run of `plan` gives where every test it planned passed.
    private static func answer(_ plan: ShardPlan) -> (reconciliation: ShardReconciliation, rendered: String) {
        var outcomes = RunTestOutcomes()
        for test in plan.shards.flatMap(\.tests) {
            outcomes.read("✔ Test \(test.function) passed after 0.1 seconds.")
        }
        let reconciliation = ShardMerge.reconcile(plan: plan, outcomes: [ShardOutcome(outcomes: outcomes, exitCode: 0, wallSeconds: 1, logPath: "log")])
        return (reconciliation, ShardAnswerRenderer(swiftPackage: true).render(reconciliation, plan: plan))
    }

    @Test func aTestNeitherListingNamesWasNotCompiledAndTheRunStaysGreen() throws {
        let (inventory, root) = try Self.excludedFixture()
        let listed = try PackageShardPlanner.listed("LibTests.AlphaTests/one()")
        var relistings = 0

        let candidates = PackageShardPlanner.neverListed(declaredIn: inventory, listed: listed, repositoryRoot: root)
        let owed = PackageShardPlanner.confirmed(neverListed: candidates, listed: listed) {
            relistings += 1
            return listed
        }.owed
        let (reconciliation, rendered) = Self.answer(listed: listed, neverListed: owed)

        #expect(candidates.map(\.enumerated) == ["LibTests/(file scope)/fixtureTest()"])
        #expect(relistings == 1)
        #expect(owed.isEmpty)
        #expect(reconciliation.isGreen, "\(rendered)")
    }

    @Test func aTestTheSecondListingNamesWasLostByTheFirstAndGoesRedByName() throws {
        let (inventory, root) = try Self.excludedFixture()
        let listed = try PackageShardPlanner.listed("LibTests.AlphaTests/one()")
        let relisted = try PackageShardPlanner.listed("LibTests.AlphaTests/one()\nLibTests.fixtureTest()")

        let owed = PackageShardPlanner.confirmed(
            neverListed: PackageShardPlanner.neverListed(declaredIn: inventory, listed: listed, repositoryRoot: root),
            listed: listed
        ) { relisted }.owed
        let (reconciliation, rendered) = Self.answer(listed: listed, neverListed: owed)

        #expect(owed.map(\.enumerated) == ["LibTests/(file scope)/fixtureTest()"])
        #expect(!reconciliation.isGreen)
        #expect(rendered.hasPrefix("✘ sift test — 1 declared but never listed"))
        #expect(rendered.contains("\n  LibTests/(file scope)/fixtureTest()"))
    }

    @Test func aSecondListingIsRunOnlyWhereACandidateIsOwedAndOneThatFailedLeavesThemAll() throws {
        let fixtureTest = try PackageShardPlanner.listed("LibTests.fixtureTest()")
        let listed = try PackageShardPlanner.listed("LibTests.AlphaTests/one()")
        var relistings = 0

        let none = PackageShardPlanner.confirmed(neverListed: [], listed: listed) {
            relistings += 1
            return []
        }
        let failed = PackageShardPlanner.confirmed(neverListed: fixtureTest, listed: listed) {
            relistings += 1
            return nil
        }

        #expect(none.owed.isEmpty)
        #expect(failed.owed == fixtureTest)
        #expect(!failed.complete)
        #expect(relistings == 1)
    }

    /// Two tests listed first; `fixtureTest()` is the candidate.
    private static var firstListing: String {
        "LibTests.AlphaTests/one()\nLibTests.AlphaTests/two()"
    }

    @Test func aListingShortOfTheFirstRulesNothingOutAndThePackageIsListedAgain() throws {
        let fixtureTest = try PackageShardPlanner.listed("LibTests.fixtureTest()")
        let listed = try PackageShardPlanner.listed(Self.firstListing)
        let short = try PackageShardPlanner.listed("LibTests.AlphaTests/one()")
        var relistings = 0

        let empty = PackageShardPlanner.confirmed(neverListed: fixtureTest, listed: listed) {
            relistings += 1
            return []
        }
        let neverComplete = PackageShardPlanner.confirmed(neverListed: fixtureTest, listed: listed) { short }

        #expect(empty.owed == fixtureTest)
        #expect(!empty.complete)
        #expect(relistings == PackageShardPlanner.confirmingListings)
        #expect(neverComplete.owed == fixtureTest)
        #expect(!neverComplete.complete)
    }

    @Test func aLaterCompleteListingIsTrustedWhereAnEarlierFellShort() throws {
        let fixtureTest = try PackageShardPlanner.listed("LibTests.fixtureTest()")
        let listed = try PackageShardPlanner.listed(Self.firstListing)
        var listings = try [PackageShardPlanner.listed("LibTests.AlphaTests/two()"), listed]

        let confirmed = PackageShardPlanner.confirmed(neverListed: fixtureTest, listed: listed) { listings.removeFirst() }

        #expect(confirmed.owed.isEmpty)
        #expect(confirmed.complete)
        #expect(listings.isEmpty)
    }

    @Test func aCandidateAnyListingNamedWasCompiledAndStaysOwed() throws {
        let fixtureTest = try PackageShardPlanner.listed("LibTests.fixtureTest()")
        let listed = try PackageShardPlanner.listed(Self.firstListing)
        var listings = try [PackageShardPlanner.listed("LibTests.AlphaTests/one()\nLibTests.fixtureTest()"), listed]

        let confirmed = PackageShardPlanner.confirmed(neverListed: fixtureTest, listed: listed) { listings.removeFirst() }

        #expect(confirmed.owed == fixtureTest)
        #expect(confirmed.complete)
    }

    @Test func aRunOwesEveryCandidateWhereItsConfirmingListingExitedNonZeroOrCouldNotBeRead() throws {
        let fixtureTest = try PackageShardPlanner.listed("LibTests.fixtureTest()")
        let listed = try PackageShardPlanner.listed(Self.firstListing)
        let plan = PackageShardPlanner.plan(tests: listed, shards: 1) { _ in nil }
        var relistings = 0

        let exited = PackageTestRun.confirmingNeverListed(plan, candidates: fixtureTest, listed: listed) {
            relistings += 1
            return PackageTestRun.Relisting(tests: .success(listed), exitCode: 1, logPath: nil)
        }
        let unreadable = PackageTestRun.confirmingNeverListed(plan, candidates: fixtureTest, listed: listed) {
            PackageTestRun.Relisting(tests: .failure(CocoaError(.fileReadCorruptFile)), exitCode: 0, logPath: nil)
        }
        let confirmed = PackageTestRun.confirmingNeverListed(plan, candidates: fixtureTest, listed: listed) { PackageTestRun.Relisting(tests: .success(listed), exitCode: 0, logPath: nil) }

        #expect(exited.neverListed == fixtureTest)
        #expect(relistings == 1)
        #expect(unreadable.neverListed == fixtureTest)
        #expect(confirmed.neverListed.isEmpty)
        #expect(confirmed.shards == plan.shards)
    }

    @Test func candidatesNoListingConfirmedAreAnsweredWithWhyUnderTheirNames() throws {
        let fixtureTest = try PackageShardPlanner.listed("LibTests.fixtureTest()")
        let listed = try PackageShardPlanner.listed(Self.firstListing)
        let short = try PackageShardPlanner.listed("LibTests.AlphaTests/one()")
        let plan = PackageShardPlanner.plan(tests: listed, shards: 1) { _ in nil }

        let exited = PackageTestRun.confirmingNeverListed(plan, candidates: fixtureTest, listed: listed) { PackageTestRun.Relisting(tests: .success(listed), exitCode: 1, logPath: "relist.log") }
        let unreadable = PackageTestRun.confirmingNeverListed(plan, candidates: fixtureTest, listed: listed) {
            PackageTestRun.Relisting(tests: .failure(CocoaError(.fileReadCorruptFile)), exitCode: 0, logPath: "relist.log")
        }
        let neverComplete = PackageTestRun.confirmingNeverListed(plan, candidates: fixtureTest, listed: listed) { PackageTestRun.Relisting(tests: .success(short), exitCode: 0, logPath: "relist.log") }
        let confirmed = PackageTestRun.confirmingNeverListed(plan, candidates: fixtureTest, listed: listed) { PackageTestRun.Relisting(tests: .success(listed + fixtureTest), exitCode: 0, logPath: "relist.log") }
        let (reconciliation, rendered) = Self.answer(exited)
        let green = Self.answer(PackageTestRun.confirmingNeverListed(plan, candidates: fixtureTest, listed: listed) { PackageTestRun.Relisting(tests: .success(listed), exitCode: 0, logPath: "relist.log") })

        #expect(exited.neverListedNote == "none was ruled out: the `swift test list` run to confirm them exited 1 — its log is at relist.log.")
        #expect(unreadable.neverListedNote == "none was ruled out: the `swift test list` run to confirm them printed a line that names no test — its log is at relist.log.")
        #expect(neverComplete.neverListedNote == "none was ruled out: none of the 3 `swift test list` runs to confirm them named every test the first did — the last one's log is at relist.log.")
        #expect(confirmed.neverListed == fixtureTest)
        #expect(confirmed.neverListedNote == nil)
        #expect(!reconciliation.isGreen)
        #expect(rendered.contains("\n  LibTests/(file scope)/fixtureTest()\n\(exited.neverListedNote ?? "")"))
        #expect(green.reconciliation.isGreen)
        #expect(green.rendered == Self.answer(plan).rendered)
    }
}
