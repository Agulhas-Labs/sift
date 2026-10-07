//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `BuildTimingRenderer` directly, for shapes `BuildCommandTests` cannot reach through a captured build transcript.
@Suite(.temporaryDirectories)
struct BuildTimingRendererTests {
    /// `--top` sets how many rows every list keeps, the by-file list included — not just as many as the body and expression rankings happened to fill.
    @Test
    func topGovernsTheByFileListEvenWhenFewerSitesWereRanked() throws {
        let made = try TemporaryDirectory.make("build-timing-renderer")
        let root = URL(fileURLWithPath: CanonicalPath.of(made.path))
        // Three body-only sites and three expression-only sites, each in its own file: both rankings stay
        // under `top`, so `max(bodies.count, expressions.count)` undercounts the six files that were timed.
        let timings = [
            BuildTiming(milliseconds: 6, path: root.path + "/A.swift", line: 1, column: 1, kind: .body),
            BuildTiming(milliseconds: 5, path: root.path + "/B.swift", line: 1, column: 1, kind: .body),
            BuildTiming(milliseconds: 4, path: root.path + "/C.swift", line: 1, column: 1, kind: .body),
            BuildTiming(milliseconds: 3, path: root.path + "/D.swift", line: 1, column: 1, kind: .expression),
            BuildTiming(milliseconds: 2, path: root.path + "/E.swift", line: 1, column: 1, kind: .expression),
            BuildTiming(milliseconds: 1, path: root.path + "/F.swift", line: 1, column: 1, kind: .expression),
        ]
        let analysis = BuildTimingAnalysis(timings: timings, packageRoot: root, treeRoot: root, top: 4)

        let rendered = BuildTimingRenderer(root: root).render(analysis, seconds: 1, logLines: 5, logURL: nil, top: 4)

        let byFile = try #require(rendered.split(separator: "\n").first { $0.hasPrefix("by file, most body time first — ") })

        #expect(byFile == "by file, most body time first — 4 of 6:")
    }
}
