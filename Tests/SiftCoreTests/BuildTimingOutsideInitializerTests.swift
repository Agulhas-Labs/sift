//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// What the line for time outside the package owes a reader: the expressions in no function body are in it, and the ones inside a body are not added twice.
@Suite(.temporaryDirectories)
struct BuildTimingOutsideInitializerTests {
    private static var depotSource: String {
        """
        public let table = [1, 2, 3]
        public struct Depot {
            static let values = [4, 5, 6]
            func restock() {
                _ = 1 + 2
            }
            var gauge: Int { 1 + 2 }
        }

        """
    }

    private static var depotPath: String {
        "/.build/sift-timing/checkouts/Depot/Sources/Depot/Depot.swift"
    }

    private static func analysis(dependencySource: String?) throws -> (root: URL, analysis: BuildTimingAnalysis) {
        let made = try TemporaryDirectory.make("build-timing-outside")
        let root = URL(fileURLWithPath: CanonicalPath.of(made.path))
        if let dependencySource {
            try TestSources.write(dependencySource, to: String(depotPath.dropFirst()), in: root)
        }
        let path = root.path + depotPath
        let timings = [
            BuildTiming(milliseconds: 2.0, path: path, line: 1, column: 19, kind: .expression),
            BuildTiming(milliseconds: 2.0, path: path, line: 3, column: 25, kind: .expression),
            BuildTiming(milliseconds: 3.34, path: path, line: 4, column: 10, kind: .body, declarationDescription: "instance method Depot.(file).Depot.restock()@Depot.swift:4:10"),
            BuildTiming(milliseconds: 9.0, path: path, line: 5, column: 13, kind: .expression),
            BuildTiming(milliseconds: 1.0, path: path, line: 7, column: 22, kind: .expression),
        ]
        return (root, BuildTimingAnalysis(timings: timings, packageRoot: root, treeRoot: root, top: 10))
    }

    @Test
    func aGlobalAndAStaticInitializerAreCountedAndTheExpressionsInsideBodiesAreNot() throws {
        let (root, analysis) = try Self.analysis(dependencySource: Self.depotSource)

        #expect(abs(analysis.outsideBodyMilliseconds - 3.34) < 0.000_1)
        #expect(abs(analysis.outsideExpressionMilliseconds - 4.0) < 0.000_1)
        #expect(abs(analysis.outsideMilliseconds - 7.34) < 0.000_1)
        let rendered = BuildTimingRenderer(root: root).render(analysis, seconds: 1, logLines: 5, logURL: nil, top: 10)
        let outside = try #require(rendered.split(separator: "\n").first { $0.hasPrefix("outside the package's own sources") })
        #expect(outside.contains("3.34 ms of function bodies, 4.00 ms of expressions outside any body"), "\(outside)")
    }

    @Test
    func aDependencyFileThatCannotBeReadCountsItsExpressionsOnlyWhenItPrintedNoBodyLine() throws {
        let (_, analysis) = try Self.analysis(dependencySource: nil)

        // This file printed a body line, so its expressions are taken to be inside it: none is added.
        #expect(abs(analysis.outsideExpressionMilliseconds) < 0.000_1)
        #expect(abs(analysis.outsideBodyMilliseconds - 3.34) < 0.000_1)
    }
}
