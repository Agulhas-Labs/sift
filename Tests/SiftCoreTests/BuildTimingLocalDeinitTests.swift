//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A `deinit` of a class declared inside a function is named for that class, not for the function that holds it.
@Suite(.temporaryDirectories)
struct BuildTimingLocalDeinitTests {
    private static var source: String {
        """
        func host() {
            final class Local {
                deinit {
                    _ = 1 + 2
                }
            }
            _ = Local()
        }

        """
    }

    @Test
    func aLocalClassDeinitIsNamedForTheClassNotTheFunction() throws {
        let made = try TemporaryDirectory.make("build-timing-local-deinit")
        let root = URL(fileURLWithPath: CanonicalPath.of(made.path))
        try TestSources.write(Self.source, to: "Sources/Widget/Host.swift", in: root)
        let path = root.path + "/Sources/Widget/Host.swift"
        let timings = [
            BuildTiming(milliseconds: 0.14, path: path, line: 3, column: 9, kind: .body, declarationDescription: "deinitializer Widget.(file).host().Local.deinit@\(path):3:9"),
            BuildTiming(milliseconds: 0.05, path: path, line: 4, column: 17, kind: .expression),
        ]

        let analysis = BuildTimingAnalysis(timings: timings, packageRoot: root, treeRoot: root, top: 10)

        #expect(analysis.bodies.first?.declaration?.name == "Local.deinit")
        #expect(analysis.expressions.first?.declaration?.name == "Local.deinit")
    }
}
