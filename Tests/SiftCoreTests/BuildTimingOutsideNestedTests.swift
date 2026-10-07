//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A local function's body time is inside its enclosing body's, so the line for time outside the package counts the line but not the time.
@Suite(.temporaryDirectories)
struct BuildTimingOutsideNestedTests {
    @Test
    func aLocalFunctionOutsideThePackageIsCountedAsALineButNotAddedToItsEnclosingBody() throws {
        let made = try TemporaryDirectory.make("build-timing-outside-nested")
        let root = URL(fileURLWithPath: CanonicalPath.of(made.path))
        let path = root.path + "/.build/sift-timing/checkouts/Depot/Sources/Depot/Depot.swift"
        let timings = [
            BuildTiming(milliseconds: 80, path: path, line: 1, column: 6, kind: .body, declarationDescription: "global function Depot.(file).outer()@Depot.swift:1:6"),
            BuildTiming(milliseconds: 50, path: path, line: 2, column: 10, kind: .body, declarationDescription: "local function Depot.(file).outer().inner()@Depot.swift:2:10"),
        ]

        let analysis = BuildTimingAnalysis(timings: timings, packageRoot: root, treeRoot: root, top: 10)

        #expect(analysis.outsideLines == 2)
        #expect(abs(analysis.outsideBodyMilliseconds - 80) < 0.000_1)
    }
}
