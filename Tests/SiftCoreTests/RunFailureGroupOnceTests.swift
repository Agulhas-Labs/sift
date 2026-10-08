//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a measured failure block naming each test once and listing a parameterised test's cases in one order, whatever order the run printed them in.
///
/// `Fixtures/RunOutput/swift-test-failure-groups.txt` is a real run of two failing tests making the same two failing expectations, one of them parameterised over three arguments: eight failures, two signatures, both tests under each. Before this, the second signature's `also:` line named the plain test a second time, and the two example lines listed the three arguments in two different orders, because the cases ran in parallel and reached the two expectations in different orders.
@Suite(.temporaryDirectories)
struct RunFailureGroupOnceTests {
    /// The plain test is named in full once, under the first signature, and under the second it shares with the parameterised test it is referred back to with its own failure's location, so that failure is still accounted for.
    @Test
    func aTestNamedUnderOneSignatureIsNotNamedAgainUnderTheNext() throws {
        let answer = try Self.answer(sites: .none, workingDirectory: URL(fileURLWithPath: "/Users/dev/Probe"))

        #expect(answer.contains("  ↳ top: Expectation failed: exitCode(patterns) == nil  ×4"))
        #expect(answer.filter { $0.contains("aSingleFilterIsNotJudged()") } == [
            "    also: aSingleFilterIsNotJudged() — ProbeTests.swift:10:9",
            "    also: aSingleFilterIsNotJudged() — ProbeTests.swift:9:9 (named above)",
        ])
        // A full `also:` line names a test no line above it named, and a back-reference one that a line above did.
        for (index, line) in answer.enumerated() where line.hasPrefix("    also: ") {
            let name = String(line.dropFirst("    also: ".count).prefix { $0 != " " })
            let namedAbove = answer[..<index].contains { $0.contains(name) }
            #expect(namedAbove == line.contains("(named above)"), "\(line)")
        }
        // Eight failures, all accounted for by name: no line says some were left unnamed.
        #expect(!answer.contains { $0.contains("not named here") })
    }

    /// Both example lines of the parameterised test list its three arguments in one order, sorted by their text, and print the first of them's own message.
    @Test
    func aParameterisedTestsArgumentsAreListedInOneOrderUnderEverySignature() throws {
        let answer = try Self.answer(sites: .none, workingDirectory: URL(fileURLWithPath: "/Users/dev/Probe"))
        let label = #"anObjCRenamedXCTestIsNotJudged(patterns:) with patterns → ["SwiftNamedTests", "ProbeTests.XCAlphaTests/testA$"], patterns → ["SwiftNamedTests"], patterns → ["Third", "Fourth", "Fifth"]"#

        #expect(answer.filter { $0.contains("anObjCRenamedXCTestIsNotJudged") } == [
            "  \(label) — ProbeTests.swift:26:9  ×3",
            "  \(label) — ProbeTests.swift:22:9  ×3",
        ])
        #expect(answer.contains("    Expectation failed: exitCode(patterns) == nil → false exitCode(patterns) → 2 some → 2"))
        #expect(answer.contains(#"    Expectation failed: judged(patterns).isEmpty → false judged(patterns) → ["SwiftNamedTests", "ProbeTests.XCAlphaTests/testA$"] isEmpty → false"#))
    }

    /// The property itself: the measured block is the same whichever order the run's failures arrived in — the fixture's, and two tests tied on count under both of the signatures they share, where the lead is the first by name rather than the first to fail, and one test failing one expectation at two lines.
    @Test(arguments: [false, true])
    func theBlockIsTheSameWhicheverOrderTheFailuresArrivedIn(reversed: Bool) throws {
        let failures = try Self.failures()
        let reordered = reversed ? Array(failures.reversed()) : Array(failures[4...] + failures[..<4])

        let original = Self.measured(failures)

        #expect(original.contains("  ↳ top: Expectation failed: exitCode(patterns) == nil  ×4"))
        #expect(Self.measured(reordered) == original)

        let tied = Self.tiedFailures
        let tiedReordered = reversed ? Array(tied.reversed()) : Array(tied[2...] + tied[..<2])
        let tiedOriginal = Self.measured(tied)

        #expect(tiedOriginal.filter { $0.hasPrefix("  one()") } == ["  one() — Probe.swift:3:5", "  one() — Probe.swift:4:5"])
        #expect(Self.measured(tiedReordered) == tiedOriginal)

        // One test failing one expectation at two lines is shown at the first of them by location.
        let twice = [
            RunFailureShape.Failure(name: "one()", location: "Probe.swift:21:5", message: "Expectation failed: gamma"),
            RunFailureShape.Failure(name: "one()", location: "Probe.swift:20:5", message: "Expectation failed: gamma"),
        ]
        let twiceOriginal = Self.measured(twice)

        #expect(twiceOriginal.contains("  one() — Probe.swift:20:5  ×2"))
        #expect(Self.measured(reversed ? twice.reversed() : twice) == twiceOriginal)
    }

    /// Every failure is accounted for under its signature: the lines beneath each signature add up to its count, and the block's to the count its heading states — on the fixture, and on two tests tied under the two signatures they share, whichever order they arrived in.
    @Test(arguments: [false, true])
    func everySignaturesLinesAddUpToItsCountAndTheBlockToTheHeading(reversed: Bool) throws {
        let fixture = try Self.failures()
        for failures in [fixture, Self.tiedFailures] {
            let ordered = reversed ? Array(failures.reversed()) : failures
            let expected = RunFailureShape.of(ordered, changedFiles: .of([])).signatures.map(\.count)
            let block = Self.measured(ordered)
            let accounted = Self.accounted(block)

            #expect(accounted.perSignature == expected, "\(block.joined(separator: "\n"))")
            #expect(accounted.perSignature.reduce(0, +) == accounted.heading)
            #expect(accounted.heading == failures.count)
        }
    }

    /// Resolved against the probe's own source, each `all N are in` line counts the failures of the example line above it, and the plain test is still named once.
    @Test
    func eachAllNClaimCountsTheExampleItStandsUnder() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.probeSource, to: "Tests/ProbeTests/ProbeTests.swift", in: root)
        try TestSources.commitAll(in: root, message: "probe")
        try await SiftEngine(directory: root).ensureFresh()
        let report = try Self.report()
        let sites = RunFailureSites.resolving(report.testFailures.compactMap(\.location), inRepositoryAt: root)

        let answer = try Self.answer(sites: sites, workingDirectory: root)
        let claim = "    all 3 are in ProbeTests.anObjCRenamedXCTestIsNotJudged(patterns:) — Tests/ProbeTests/ProbeTests.swift:13-27 (syntactic)"
        let claims = answer.indices.filter { answer[$0] == claim }

        #expect(claims.count == 2)
        for index in claims {
            #expect(answer[index - 2].hasPrefix("  anObjCRenamedXCTestIsNotJudged(patterns:) with "))
            #expect(answer[index - 2].hasSuffix("  ×3"))
        }
        #expect(answer.filter { $0.contains("aSingleFilterIsNotJudged()") && !$0.contains("(named above)") }.count == 1)
    }
}

private extension RunFailureGroupOnceTests {
    /// The probe's test file as it stood when the fixture was captured, so its failure lines resolve to the declarations they happened in.
    static var probeSource: String {
        """
        import Foundation
        import Probe
        import Testing

        struct ProbeTests {
            @Test
            func aSingleFilterIsNotJudged() {
                let patterns = ["NothingLikeThis"]
                #expect(judged(patterns).isEmpty)
                #expect(exitCode(patterns) == nil)
            }

            @Test(arguments: [
                ["SwiftNamedTests"],
                ["SwiftNamedTests", "ProbeTests.XCAlphaTests/testA$"],
                ["Third", "Fourth", "Fifth"],
            ])
            func anObjCRenamedXCTestIsNotJudged(patterns: [String]) {
                if patterns.count == 2 {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                #expect(judged(patterns).isEmpty)
                if patterns.count == 1 {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                #expect(exitCode(patterns) == nil)
            }
        }

        """
    }

    static func report() throws -> RunReport {
        try TestSources.runReport("swift-test-failure-groups", invokedAs: ["swift", "test"], exitCode: 1)
    }

    /// The fixture's whole answer, as `sift run` prints it.
    static func answer(sites: RunFailureSites, workingDirectory: URL) throws -> [String] {
        try RunReportRenderer(kind: .swiftTest, workingDirectory: workingDirectory, changedFiles: .of([]), sites: sites)
            .render(report(), exitCode: 1, logURL: nil)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    static func failures() throws -> [RunFailureShape.Failure] {
        try report().testFailures.map {
            RunFailureShape.Failure(name: $0.name, location: $0.location, message: $0.message, arguments: $0.arguments, note: $0.note)
        }
    }

    /// Two tests failing the same two expectations once each, in the order the second of them failed first.
    static var tiedFailures: [RunFailureShape.Failure] {
        [
            RunFailureShape.Failure(name: "two()", location: "Probe.swift:9:5", message: "Expectation failed: alpha"),
            RunFailureShape.Failure(name: "two()", location: "Probe.swift:10:5", message: "Expectation failed: beta"),
            RunFailureShape.Failure(name: "one()", location: "Probe.swift:3:5", message: "Expectation failed: alpha"),
            RunFailureShape.Failure(name: "one()", location: "Probe.swift:4:5", message: "Expectation failed: beta"),
        ]
    }

    /// The count a measured block's heading states, and how many failures the lines beneath each of its signatures account for: an example line or an `also:` line its own `×N` (one where it prints none), a `+N more tests` line the failures it counts.
    ///
    /// The block-wide `not named here` line accounts for none, since it is the gap this measures.
    static func accounted(_ block: [String]) -> (heading: Int, perSignature: [Int]) {
        let heading = Int(block.first?.prefix { $0.isNumber } ?? "") ?? 0
        var perSignature: [Int] = []
        for line in block.dropFirst() {
            let isExample = line.hasPrefix("  ") && !line.hasPrefix("   ") && !line.hasPrefix("  ↳") && !line.hasPrefix("  +")
            if isExample {
                perSignature.append(0)
            }
            guard isExample || line.hasPrefix("    also: ") || line.hasPrefix("    +"), !perSignature.isEmpty else {
                continue
            }
            let count = if line.hasPrefix("    +"), let open = line.lastIndex(of: "(") {
                Int(line[line.index(after: open)...].prefix { $0.isNumber }) ?? 0
            } else if let times = line.range(of: "  ×", options: .backwards) {
                Int(line[times.upperBound...]) ?? 0
            } else {
                1
            }
            perSignature[perSignature.count - 1] += count
        }
        return (heading, perSignature)
    }

    /// The block with no log left to list into, which is the form the fixture's own answer takes.
    static func measured(_ failures: [RunFailureShape.Failure]) -> [String] {
        var budget = RunFailureCensus.listingBudget
        return RunFailureShape.of(failures, changedFiles: .of([])).rendered(within: 0, spending: &budget)
    }
}
