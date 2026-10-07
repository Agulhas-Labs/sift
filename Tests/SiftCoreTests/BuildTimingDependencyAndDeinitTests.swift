//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Two things the `build --analyse` answer once got wrong: a dependency's time added body to expression, and a `deinit` named for its class.
@Suite(.temporaryDirectories)
struct BuildTimingDependencyAndDeinitTests {
    private static var gizmoSource: String {
        """
        final class Gizmo {
            deinit {
                _ = 1 + 2
            }
        }

        """
    }

    private static func analysed(_ timings: (URL) -> [BuildTiming]) throws -> (root: URL, analysis: BuildTimingAnalysis) {
        let made = try TemporaryDirectory.make("build-timing-deinit")
        let root = URL(fileURLWithPath: CanonicalPath.of(made.path))
        try TestSources.write(gizmoSource, to: "Sources/Widget/Gizmo.swift", in: root)
        return (root, BuildTimingAnalysis(timings: timings(root), packageRoot: root, treeRoot: root, top: 10))
    }

    @Test
    func aDependencysTimeIsItsBodiesAloneNotBodiesPlusTheirExpressions() throws {
        let (root, analysis) = try Self.analysed { root in
            [
                BuildTiming(milliseconds: 9.58, path: root.path + "/.build/sift-timing/checkouts/Depot/Sources/Depot/Depot.swift", line: 2, column: 5, kind: .expression),
                BuildTiming(milliseconds: 14.42, path: root.path + "/.build/sift-timing/checkouts/Depot/Sources/Depot/Depot.swift", line: 1, column: 13, kind: .body, declarationDescription: "global function Depot.(file).restock()@Depot.swift:1:13"),
            ]
        }

        let rendered = BuildTimingRenderer(root: root).render(analysis, seconds: 1, logLines: 5, logURL: nil, top: 10)
        let outside = try #require(rendered.split(separator: "\n").first { $0.hasPrefix("outside the package's own sources") })

        #expect(analysis.outsideLines == 2)
        #expect(abs(analysis.outsideMilliseconds - 14.42) < 0.000_1)
        #expect(outside.contains("14.42 ms of function bodies"))
        #expect(!outside.contains("24.00"))
    }

    @Test
    func aDeinitBodyAndTheExpressionInsideItAreNamedDeinitOfTheClass() throws {
        let (_, analysis) = try Self.analysed { root in
            let path = root.path + "/Sources/Widget/Gizmo.swift"
            return [
                BuildTiming(milliseconds: 0.14, path: path, line: 2, column: 5, kind: .body, declarationDescription: "deinitializer Widget.(file).Gizmo.deinit@\(path):2:5"),
                BuildTiming(milliseconds: 0.05, path: path, line: 3, column: 13, kind: .expression),
            ]
        }

        #expect(analysis.bodies.first?.declaration?.name == "Gizmo.deinit")
        #expect(analysis.expressions.first?.declaration?.name == "Gizmo.deinit")
    }

    @Test
    func aLineInTheClassOutsideItsDeinitKeepsTheClassName() throws {
        let (_, analysis) = try Self.analysed { root in
            [BuildTiming(milliseconds: 0.14, path: root.path + "/Sources/Widget/Gizmo.swift", line: 1, column: 13, kind: .body, declarationDescription: "class Widget.(file).Gizmo@x:1:13")]
        }

        #expect(analysis.bodies.first?.declaration?.name == "Gizmo")
    }
}
