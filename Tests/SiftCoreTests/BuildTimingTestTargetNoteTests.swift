//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The one line `sift build --analyse` owes a reader when `swift build` left the test targets out of the ranking.
@Suite(.temporaryDirectories)
struct BuildTimingTestTargetNoteTests {
    private static func rendered(builtWithTests: Bool) throws -> String {
        let made = try TemporaryDirectory.make("build-timing-note")
        let root = URL(fileURLWithPath: CanonicalPath.of(made.path))
        let timings = [BuildTiming(milliseconds: 6, path: root.path + "/A.swift", line: 1, column: 1, kind: .body)]
        let analysis = BuildTimingAnalysis(timings: timings, packageRoot: root, treeRoot: root, top: 4)
        return BuildTimingRenderer(root: root).render(analysis, seconds: 1, logLines: 5, logURL: nil, top: 4, builtWithTests: builtWithTests)
    }

    @Test
    func aBuildThatSkippedTheTestTargetsSaysTheRankingLeavesThemOutAndNamesTheFlag() throws {
        let answer = try Self.rendered(builtWithTests: false)

        let note = try #require(answer.split(separator: "\n").first { $0.hasPrefix("test targets are not built") })

        #expect(note.contains("compiled targets only"))
        #expect(note.contains("--build-tests"))
    }

    @Test
    func aBuildThatIncludedTheTestTargetsCarriesNoNote() throws {
        let answer = try Self.rendered(builtWithTests: true)

        #expect(!answer.contains("test targets are not built"))
    }
}
