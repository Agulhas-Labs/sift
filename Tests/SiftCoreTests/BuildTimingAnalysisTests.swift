//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Folding, ranking and naming a build's timings, over the captured package's own source written back to disk.
@Suite(.temporaryDirectories)
struct BuildTimingAnalysisTests {
    /// The captured package's `Slow.swift`, byte for byte, so the capture's locations land on the lines they were measured on.
    private static var slowSource: String {
        """
        struct Ledger {
            var rates = [1, 2.5, 3, 4.25, 5, 6.5, 7, 8.75]

            func total() -> Double {
                let sum = 1.0 + 2 + 3.5 + 4 + 5.0 + 6 + 7 + 8.25 + 9 + 10 + 11 + 12.5 + 13 + 14 + 15.5 + 16 + 17 + 18.0
                return sum
            }

            func mixed() -> [Any] {
                let values: [Any] = [1, "two", 3.0, [4, 5], ["six": 6], 7, "eight", 9.0]
                return values
            }

            func pick(_ flag: Int) -> Int {
                flag > 3 ? 1 : flag > 2 ? 2 : flag > 1 ? 3 : 4
            }

            func doubled() -> [Double] {
                rates.map { $0 * 2 }
            }
        }

        func box<T>(_ value: T) -> [T] { [value, value] }

        func outer() -> Double {
            func inner() -> Double {
                var total = 0.0
                for i in 0 ..< 50 {
                    total += Double(i) * Double(i) / (Double(i) + 1.0) - Double(i) / 2.0 + Double(i) * 3.0
                }
                return total
            }
            var total = inner()
            for i in 0 ..< 50 {
                total += Double(i) * Double(i) / (Double(i) + 1.0) - Double(i) / 2.0 + Double(i) * 3.0
            }
            return total
        }

        """
    }

    private static var mainSource: String {
        """
        let ledger = Ledger()
        _ = ledger.total()
        _ = ledger.mixed()
        _ = ledger.pick(2)
        _ = ledger.doubled()
        _ = box(1)
        _ = outer()

        """
    }

    /// The capture's timings, relocated into a fresh package directory holding the same two files.
    private static func capturedPackage() throws -> (root: URL, timings: [BuildTiming]) {
        let root = try TemporaryDirectory.make("build-timing")
        try TestSources.write(slowSource, to: "Sources/Widget/Slow.swift", in: root)
        try TestSources.write(mainSource, to: "Sources/Widget/main.swift", in: root)
        let capture = try TestSources.runOutput("swift-build-debug-time")
            .replacingOccurrences(of: "/Users/dev/Widget", with: root.path)
        return (root, BuildTimingParser.timings(in: capture))
    }

    private static func near(_ value: Double, _ expected: Double) -> Bool {
        abs(value - expected) < 0.000_1
    }

    @Test
    func theSlowestBodyIsNamedByTheDeclarationThatEnclosesIt() throws {
        let (root, timings) = try Self.capturedPackage()
        let analysis = BuildTimingAnalysis(timings: timings, packageRoot: root, treeRoot: root, top: 10)

        let first = try #require(analysis.bodies.first)

        #expect(first.path == "Sources/Widget/Slow.swift")
        #expect(first.line == 4)
        #expect(Self.near(first.milliseconds, 7.09))
        #expect(first.declaration?.name == "Ledger.total()")
        #expect(first.declaration?.startLine == 4)
        #expect(first.declaration?.endLine == 7)
    }

    @Test
    func theSlowestExpressionIsTheLiteralChainInsideTheSlowestBody() throws {
        let (root, timings) = try Self.capturedPackage()
        let analysis = BuildTimingAnalysis(timings: timings, packageRoot: root, treeRoot: root, top: 10)

        let first = try #require(analysis.expressions.first)

        #expect((first.line, first.column) == (5, 19))
        #expect(Self.near(first.milliseconds, 2.96))
        #expect(first.declaration?.name == "Ledger.total()")
    }

    @Test
    func aSiteTimedInEveryFrontendJobIsOneRowWithItsCount() throws {
        let (root, timings) = try Self.capturedPackage()
        let analysis = BuildTimingAnalysis(timings: timings, packageRoot: root, treeRoot: root, top: 10)

        let initializer = try #require(analysis.expressions.first { ($0.line, $0.column) == (2, 17) })
        #expect(initializer.count == 3)
        #expect(Self.near(initializer.milliseconds, 1.47))
        #expect(initializer.declaration?.name == "Ledger.rates")
        let accessors = try #require(analysis.bodies.first { $0.line == 2 })
        #expect(accessors.count == 3)
        #expect(accessors.declaration?.name == "Ledger.rates")
    }

    @Test
    func aTopLevelStatementIsInNoDeclarationAndATopLevelBindingIsItsOwn() throws {
        let (root, timings) = try Self.capturedPackage()
        let analysis = BuildTimingAnalysis(timings: timings, packageRoot: root, treeRoot: root, top: 20)

        let binding = try #require(analysis.expressions.first { $0.path == "Sources/Widget/main.swift" && $0.line == 1 })
        #expect(binding.count == 2)
        #expect(binding.declaration?.name == "ledger")
        let statement = try #require(analysis.expressions.first { $0.path == "Sources/Widget/main.swift" && $0.line == 2 })
        #expect(statement.count == 2)
        #expect(statement.declaration == nil)
    }

    @Test
    func aLocalFunctionsTimeIsExcludedFromItsEnclosingBodysTotalAndNamedByTheCompiler() throws {
        let (root, timings) = try Self.capturedPackage()
        let analysis = BuildTimingAnalysis(timings: timings, packageRoot: root, treeRoot: root, top: 20)

        let outer = try #require(analysis.bodies.first { $0.line == 25 })
        #expect(Self.near(outer.milliseconds, 4.66))
        #expect(outer.declaration?.name == "outer()")

        let inner = try #require(analysis.bodies.first { $0.line == 26 })
        #expect(Self.near(inner.milliseconds, 3.39))
        #expect(inner.declaration?.name == "outer().inner()")

        // outer()'s own printed time already includes inner()'s, so the fold leaves inner() out of every total.
        #expect(Self.near(analysis.bodyMilliseconds, 14.66))
        #expect((analysis.bodyLines, analysis.bodySites) == (10, 8))
        // The listing still ranks inner(), so its heading counts one row more than the totals count sites.
        #expect(analysis.bodyRows == 9)
        let slowFile = try #require(analysis.files.first { $0.path == "Sources/Widget/Slow.swift" })
        #expect(Self.near(slowFile.bodyMilliseconds, 14.66))
        #expect(slowFile.bodyLines == 10)
    }

    @Test
    func bodyAndExpressionTimeAreTotalledApart() throws {
        let (root, timings) = try Self.capturedPackage()
        let analysis = BuildTimingAnalysis(timings: timings, packageRoot: root, treeRoot: root, top: 10)

        #expect(Self.near(analysis.bodyMilliseconds, 14.66))
        #expect((analysis.bodyLines, analysis.bodySites) == (10, 8))
        #expect(Self.near(analysis.expressionMilliseconds, 12.62))
        #expect((analysis.expressionLines, analysis.expressionSites) == (36, 25))
        #expect(analysis.outsideLines == 0)
    }

    @Test
    func theListedShareIsOfTheRowsKeptByTop() throws {
        let (root, timings) = try Self.capturedPackage()
        let analysis = BuildTimingAnalysis(timings: timings, packageRoot: root, treeRoot: root, top: 2)

        #expect(analysis.bodies.map(\.line) == [4, 25])
        #expect(Self.near(analysis.listedBodyMilliseconds, 7.09 + 4.66))
        #expect(analysis.expressions.count == 2)
        #expect(Self.near(analysis.listedExpressionMilliseconds, 2.96 + 2.49))
    }

    @Test
    func filesAreRankedByBodyTimeWithExpressionTimeBeside() throws {
        let (root, timings) = try Self.capturedPackage()
        let analysis = BuildTimingAnalysis(timings: timings, packageRoot: root, treeRoot: root, top: 10)

        #expect(analysis.files.map(\.path) == ["Sources/Widget/Slow.swift", "Sources/Widget/main.swift"])
        let main = try #require(analysis.files.last)
        #expect(main.bodyLines == 0)
        #expect(main.expressionLines == 14)
        let printed: [Double] = [0.81, 0.06, 0.05, 0.09, 0.03, 0.12, 0.02, 0.80, 0.06, 0.04, 0.10, 0.03, 0.11, 0.02]
        #expect(Self.near(main.expressionMilliseconds, printed.reduce(0, +)))
    }

    @Test
    func aDependencyIsCountedApartAndNeverRanked() throws {
        let root = try TemporaryDirectory.make("build-timing")
        try TestSources.write(Self.slowSource, to: "Sources/Widget/Slow.swift", in: root)
        let timings = [
            BuildTiming(milliseconds: 90, path: root.path + "/.build/sift-timing/checkouts/Depot/Sources/DepotKit/Shelf.swift", line: 3, column: 5, kind: .body),
            BuildTiming(milliseconds: 40, path: "/Users/dev/Elsewhere/Crate.swift", line: 1, column: 1, kind: .expression),
            BuildTiming(milliseconds: 2, path: root.path + "/Sources/Widget/Slow.swift", line: 14, column: 10, kind: .body),
        ]

        let analysis = BuildTimingAnalysis(timings: timings, packageRoot: root, treeRoot: root, top: 10)

        #expect(analysis.bodies.map(\.path) == ["Sources/Widget/Slow.swift"])
        #expect(analysis.expressions.isEmpty)
        #expect(Self.near(analysis.outsideMilliseconds, 130))
        #expect(analysis.outsideLines == 2)
        #expect(analysis.bodies.first?.declaration?.name == "Ledger.pick(_:)")
    }

    @Test
    func theLongLiteralChainIsNamedByItsShape() throws {
        let (root, timings) = try Self.capturedPackage()
        let analysis = BuildTimingAnalysis(timings: timings, packageRoot: root, treeRoot: root, top: 10)

        let chain = try #require(analysis.expressions.first { ($0.line, $0.column) == (5, 19) })

        #expect(chain.shape == "long literal chain")
    }

    @Test
    func theUntypedMixedCollectionLiteralIsNamedByItsShape() throws {
        let (root, timings) = try Self.capturedPackage()
        let analysis = BuildTimingAnalysis(timings: timings, packageRoot: root, treeRoot: root, top: 10)

        let literal = try #require(analysis.expressions.first { ($0.line, $0.column) == (2, 17) })

        #expect(literal.shape == "untyped mixed collection literal")
    }

    @Test
    func theTernaryChainIsNamedByItsShape() throws {
        let (root, timings) = try Self.capturedPackage()
        let analysis = BuildTimingAnalysis(timings: timings, packageRoot: root, treeRoot: root, top: 10)

        let ternary = try #require(analysis.expressions.first { ($0.line, $0.column) == (15, 9) })

        #expect(ternary.shape == "ternary chain")
    }

    @Test
    func aTypeAnnotatedMixedCollectionLiteralHasNoShape() throws {
        let (root, timings) = try Self.capturedPackage()
        let analysis = BuildTimingAnalysis(timings: timings, packageRoot: root, treeRoot: root, top: 10)

        let annotated = try #require(analysis.expressions.first { ($0.line, $0.column) == (10, 29) })

        #expect(annotated.shape == nil)
    }

    @Test
    func aPackageBelowTheTreeRootIsNamedByItsRepositoryRelativePath() throws {
        let tree = try TemporaryDirectory.make("build-timing")
        let package = tree.appendingPathComponent("Packages/Widget")
        try TestSources.write(Self.slowSource, to: "Packages/Widget/Sources/Widget/Slow.swift", in: tree)
        let timings = [BuildTiming(milliseconds: 5, path: package.path + "/Sources/Widget/Slow.swift", line: 5, column: 19, kind: .expression)]

        let analysis = BuildTimingAnalysis(timings: timings, packageRoot: package, treeRoot: tree, top: 10)

        #expect(analysis.expressions.first?.path == "Packages/Widget/Sources/Widget/Slow.swift")
        #expect(analysis.expressions.first?.declaration?.name == "Ledger.total()")
    }
}
