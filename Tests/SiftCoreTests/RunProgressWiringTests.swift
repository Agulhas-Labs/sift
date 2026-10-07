//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a wrapped run keeping its live progress file: what a reader polling `.sift/progress/` sees while a child builds, tests, falls silent and fails.
@Suite(.temporaryDirectories)
struct RunProgressWiringTests {
    /// A child that builds as SwiftPM does, runs two XCTest tests, the second failing after three silent seconds, and exits 1.
    private static var script: String {
        """
        printf 'Building for debugging...\\n'
        printf '[1/3] Compiling Gadget Gadget.swift\\n'; sleep 0.7
        printf '[2/3] Compiling GadgetTests GadgetTests.swift\\n'; sleep 0.7
        printf '[3/3] Linking GadgetTests\\n'
        printf 'Build complete! (1.40s)\\n'
        printf "Test Suite 'All tests' started at 2026-10-02 10:00:00.000.\\n"
        printf "Test Case '-[GadgetTests.GadgetTests testA]' started.\\n"
        printf "Test Case '-[GadgetTests.GadgetTests testA]' passed (0.001 seconds).\\n"; sleep 0.7
        printf "Test Case '-[GadgetTests.GadgetTests testB]' started.\\n"; sleep 3
        printf "/tmp/GadgetTests.swift:12: error: -[GadgetTests.GadgetTests testB] : XCTAssertTrue failed\\n"
        printf "Test Case '-[GadgetTests.GadgetTests testB]' failed (3.001 seconds).\\n"
        printf 'Executed 2 tests, with 1 failure (0 unexpected) in 3.002 (3.003) seconds\\n'
        exit 1
        """
    }

    /// The file moves from building to testing with its counts rising, is rewritten while the child is silent, is whole at every read, and ends `failed` with the exit code, the timings and the published log.
    @Test
    func aPollingReaderSeesTheRunBuildTestFallSilentAndFail() throws {
        let root = try TemporaryDirectory.make("progress-wiring")
        let directory = RunProgressPaths.directory(in: root, writesUnder: nil)
        let finished = DispatchSemaphore(value: 0)
        let outcome = Outcome()
        let thread = Thread {
            let progress = RunProgress.forRun(in: root, writesUnder: nil, environment: [:])
            // The launcher leaves the ending to its caller, which ends the run on sift's own exit code; here that is the command's.
            let result = Result {
                try RunLauncher(workingDirectory: root, repositoryRoot: root, runLogDirectory: root).run(["sh", "-c", Self.script], progress: progress)
            }
            if case let .success(ran) = result {
                progress?.finish(exitCode: ran.exitCode, logPath: ran.log?.url.path)
            }
            progress?.writer.reset()
            outcome.set(result)
            finished.signal()
        }
        thread.start()

        var seen: [RunProgressSnapshot] = []
        var unreadable: [String] = []
        var done = false
        while !done {
            done = finished.wait(timeout: .now() + 0.05) == .success
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where RunProgressPaths.isRunFile(name) {
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { continue }
                do {
                    try seen.append(RunProgressSnapshot.decoded(from: data))
                } catch {
                    unreadable.append(String(data: data, encoding: .utf8) ?? "\(data.count) bytes, not UTF-8")
                }
            }
        }

        #expect(try outcome.exitCode() == 1)
        #expect(unreadable.isEmpty, "a reader found a run file it could not parse: \(unreadable)")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter(RunProgressPaths.isRunFile)
        #expect(names.count == 1, "one file per run: \(names)")
        let phases = seen.map(\.phase).reduce(into: [RunProgressSnapshot.Phase]()) {
            if $0.last != $1 {
                $0.append($1)
            }
        }
        #expect(phases == [.idle, .building, .testing, .failed] || phases == [.building, .testing, .failed], "\(phases)")
        #expect(seen.contains { $0.phase == .building && $0.current?.hasPrefix("Gadget") == true })
        #expect(seen.contains { $0.phase == .testing && $0.current?.hasSuffix("testB]") == true && $0.tests.passed == 1 })
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0.tests.passed <= $1.tests.passed && $0.tests.failed <= $1.tests.failed })
        #expect(seen.contains { $0.logPath?.hasSuffix(".log.part") == true && $0.exitCode == nil })

        // The child prints nothing for three seconds while testB runs; the heartbeat still moves `updatedAt`.
        let silent = seen.filter { $0.current?.hasSuffix("testB]") == true && $0.tests.failed == 0 }
        let beats = Set(silent.map(\.updatedAt)).sorted()
        #expect(beats.count >= 2 && (beats.last?.timeIntervalSince(beats[0]) ?? 0) >= RunProgressWriter.heartbeat - 0.5, "\(beats)")

        let last = try #require(seen.last)
        #expect(last.phase == .failed)
        #expect(last.exitCode == 1)
        #expect(last.tests == RunProgressSnapshot.TestCounts(planned: nil, passed: 1, failed: 1, skipped: 0))
        #expect(last.errors == 0)
        #expect(last.command.hasPrefix("sh -c 'printf"))
        #expect(last.scheme == nil && last.destination == nil)
        let summary = try #require(last.summary)
        #expect((summary.buildMs ?? 0) >= 1000 && (summary.testMs ?? 0) >= 3000 && summary.totalMs >= 4400, "\(summary)")
        let logPath = try #require(last.logPath)
        #expect(logPath.hasSuffix(".log") && FileManager.default.fileExists(atPath: logPath), "\(logPath)")
    }

    /// The scheme and destination come from an `xcodebuild` line only, and the command is written back as a shell would read it.
    @Test
    func theCommandIsOneShellLineAndOnlyXcodebuildNamesASchemeAndDestination() {
        let line = ["xcodebuild", "-scheme", "Gizmo", "-destination", "platform=iOS Simulator,name=iPhone 17", "test"]

        #expect(RunProgress.command(line) == "xcodebuild -scheme Gizmo -destination 'platform=iOS Simulator,name=iPhone 17' test")
        #expect(RunProgress.option("-scheme", of: line, kind: .xcodebuild) == "Gizmo")
        #expect(RunProgress.option("-destination", of: line, kind: .xcodebuild) == "platform=iOS Simulator,name=iPhone 17")
        #expect(RunProgress.option("-scheme", of: ["sh", "-scheme", "Gizmo"], kind: .unrecognized) == nil)
        #expect(RunProgress.option("-scheme", of: ["xcodebuild", "-scheme"], kind: .xcodebuild) == nil)
    }

    /// `SIFT_PROGRESS=off`, or no repository, and there is no progress to keep.
    @Test
    func theSwitchOrNoRepositoryMeansNoProgress() throws {
        let root = try TemporaryDirectory.make("progress-off")

        #expect(RunProgress.forRun(in: root, writesUnder: nil, environment: [RunProgress.switchName: "off"]) == nil)
        #expect(RunProgress.forRun(in: nil, writesUnder: root, environment: [:]) == nil)
        #expect(RunProgress.forRun(in: root, writesUnder: nil, environment: [RunProgress.switchName: "on"]) != nil)
    }
}

private extension RunProgressWiringTests {
    /// The launcher's result, handed from the thread that ran it to the test.
    final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<RunOutcome, any Error>?

        func set(_ result: Result<RunOutcome, any Error>) {
            lock.withLock { self.result = result }
        }

        func exitCode(sourceLocation: SourceLocation = #_sourceLocation) throws -> Int32 {
            try #require(lock.withLock { result }, sourceLocation: sourceLocation).get().exitCode
        }
    }
}
