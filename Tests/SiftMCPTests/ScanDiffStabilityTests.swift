//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

struct ScanDiffStabilityTests {
    /// A window that one build classed differently between its two runs is listed as unstable, and not counted as differing.
    @Test func aWindowThatMovedBetweenRunsOfOneBuildIsUnstableNotDiffering() {
        let theirs = [Self.window("w1", "guided"), Self.window("w2", "guided")]
        let ours = [Self.window("w1", "cold"), Self.window("w2", "guided")]
        let oursAgain = [Self.window("w1", "guided"), Self.window("w2", "guided")]

        let lines = ScanDiff.lines(theirs: theirs, ours: ours, again: (theirs: theirs, ours: oursAgain))

        #expect(lines.contains { $0.hasPrefix("  unstable: classed differently between runs of the same build") }, "\(lines)")
        #expect(lines.contains { $0.contains("call w1") && $0.contains("classed guided / guided → cold / guided") }, "\(lines)")
        #expect(!lines.contains { $0.hasPrefix("      ") && $0.contains(" → ") && !$0.contains("call") }, "\(lines)")
        #expect(lines.last?.hasPrefix("  scan differs on 0 of 2 windows") == true, "\(lines)")
    }

    /// A window stable on both runs of each build and classed differently between the builds is counted.
    @Test func aWindowStableOnBothRunsAndDifferentBetweenBuildsIsCounted() {
        let theirs = [Self.window("w1", "cold"), Self.window("w2", "guided"), Self.window("w3", "guided")]
        let ours = [Self.window("w1", "guided"), Self.window("w2", "guided"), Self.window("w3", "cold")]
        let oursAgain = [Self.window("w1", "guided"), Self.window("w2", "guided"), Self.window("w3", "guided")]

        let lines = ScanDiff.lines(theirs: theirs, ours: ours, again: (theirs: theirs, ours: oursAgain))

        #expect(lines.contains("         1  cold → guided"), "\(lines)")
        #expect(lines.contains { $0.contains("call w3") && $0.contains("classed guided / guided → cold / guided") }, "\(lines)")
        #expect(lines.last?.hasPrefix("  scan differs on 1 of 3 windows") == true, "\(lines)")
    }

    /// The second runs are only worth making where the first runs differ.
    @Test func theBuildsDifferOnlyWhereSomeWindowIsClassedApart() {
        let same = [Self.window("w1", "cold")]

        #expect(!ScanDiff.differs(theirs: same, ours: same))
        #expect(ScanDiff.differs(theirs: same, ours: []))
    }

    private static func window(_ call: String, _ classification: String) -> ScoredWindow {
        ScoredWindow(session: "stable", call: call, classification: classification, file: "/nowhere/Depot.swift", locator: nil)
    }
}
