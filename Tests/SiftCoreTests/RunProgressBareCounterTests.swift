//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a SwiftPM build that prints only its step counter: the progress file still says it is building, and times the build where it fails to compile.
@Suite(.temporaryDirectories)
struct RunProgressBareCounterTests {
    private static func snapshot(in directory: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> RunProgressSnapshot {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter(RunProgressPaths.isRunFile)
        let name = try #require(names.first, sourceLocation: sourceLocation)
        return try RunProgressSnapshot.decoded(from: Data(contentsOf: directory.appendingPathComponent(name)))
    }

    @Test
    func aBuildPrintingOnlyACounterIsBuildingAndIsTimedWhenItFailsToCompile() throws {
        let root = try TemporaryDirectory.make("progress-bare-counter")
        let directory = RunProgressPaths.directory(in: root, writesUnder: nil)
        let progress = try #require(RunProgress.forRun(in: root, writesUnder: nil, environment: [:]))
        progress.begin(["swift", "test"], kind: .swiftTest, logPath: nil)
        defer { progress.writer.reset() }

        progress.consume(Data("Building for debugging...\n[3 / 12]\n".utf8))
        #expect(try Self.snapshot(in: directory).phase == .building)

        progress.consume(Data("/tmp/Gadget.swift:4:9: error: cannot find 'x' in scope\n[4 / 12]\n".utf8))
        progress.endOutput()
        progress.finish(exitCode: 1, logPath: nil)

        let last = try Self.snapshot(in: directory)
        #expect(last.phase == .failed)
        #expect(last.errors == 1)
        let summary = try #require(last.summary)
        #expect(summary.buildMs != nil, "\(summary)")
        #expect(summary.testMs == nil)
    }

    @Test(arguments: ["[3 / 12]", "[3/12]", "[3\u{2009}/\u{2009}12]  "])
    func aBareCounterIsReported(line: String) {
        #expect(RunBuildStep.isBareCounter(line))
    }

    @Test(arguments: ["[3/12] Pallet", "[Planning deferred tasks]", "[3]", "Building [3/12]", ""])
    func aLineWithMoreThanACounterIsNotABareCounter(line: String) {
        #expect(!RunBuildStep.isBareCounter(line))
    }

    @Test
    func aCounterAfterTestingHasStartedLeavesTheBuildFlagClear() {
        var tally = RunLiveTally(startedAt: Date())
        tally.consume(line: "Test Suite 'All tests' started at 2026-10-02 10:00:00.000.", now: Date())
        tally.consume(line: "[5 / 12]", now: Date())

        #expect(!tally.state.buildStarted)
    }
}
