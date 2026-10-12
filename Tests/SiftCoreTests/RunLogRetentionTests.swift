//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// How long a run's raw log lives: a failed run's in a pool of its own, until its command passes, and every `raw:` line saying which.
@Suite(.temporaryDirectories)
struct RunLogRetentionTests {
    private static func runs(in directory: URL) -> URL {
        SiftPaths.cache(in: directory).appendingPathComponent(RunLog.runsDirectoryName, isDirectory: true)
    }

    private static func names(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: runs(in: directory).path)
    }

    /// The failed run's log is still there after more ordinary runs than the count keeps.
    @Test
    func aFailedRunsLogOutlivesTheCountThatPrunesOrdinaryOnes() throws {
        let directory = try TemporaryDirectory.make("run-log-failed-outlives")
        defer { try? FileManager.default.removeItem(at: directory) }
        let failed = try #require(RunLog.open(inDirectory: directory))
        failed.close()
        failed.keepFailure(tag: "aaaaaaaa")
        for _ in 0 ... RunLog.keptLogs {
            RunLog.open(inDirectory: directory)?.close()
        }

        #expect(FileManager.default.fileExists(atPath: failed.url.path))
        #expect(failed.url.lastPathComponent.hasPrefix("failed-aaaaaaaa-"))
    }

    /// A pass of the same command clears its failed logs and nobody else's.
    @Test
    func aPassClearsOnlyItsOwnCommandsFailedLogs() throws {
        let directory = try TemporaryDirectory.make("run-log-failed-cleared")
        defer { try? FileManager.default.removeItem(at: directory) }
        let mine = try #require(RunLog.open(inDirectory: directory))
        mine.close()
        mine.keepFailure(tag: "aaaaaaaa")
        let other = try #require(RunLog.open(inDirectory: directory))
        other.close()
        other.keepFailure(tag: "bbbbbbbb")
        let passing = try #require(RunLog.open(inDirectory: directory))
        passing.close()

        passing.clearFailures(tag: "aaaaaaaa")

        #expect(!FileManager.default.fileExists(atPath: mine.url.path))
        #expect(FileManager.default.fileExists(atPath: other.url.path))
        #expect(FileManager.default.fileExists(atPath: passing.url.path))
    }

    /// The pool holds `keptLogs`, across tags, and never touches the other pools.
    @Test
    func theFailedPoolIsBoundedAndNeverTouchesTheOtherPools() throws {
        let directory = try TemporaryDirectory.make("run-log-failed-bound")
        defer { try? FileManager.default.removeItem(at: directory) }
        let unbuilt = try #require(RunLog.open(inDirectory: directory))
        unbuilt.close()
        unbuilt.keep(in: .didNotBuild)
        for index in 0 ... RunLog.keptLogs {
            let log = try #require(RunLog.open(inDirectory: directory))
            log.close()
            log.keepFailure(tag: String(format: "%08x", index % 2))
        }
        let names = try Self.names(in: directory)

        #expect(names.count { $0.hasPrefix(RunLog.KeptPool.failed.rawValue) } == RunLog.keptLogs)
        #expect(FileManager.default.fileExists(atPath: unbuilt.url.path))
    }

    /// A slow failed run kept after a pool's worth of quick failures that started and ended during it is the newest there, not the oldest: its path is about to be printed.
    @Test
    func aSlowFailedRunKeptAfterQuickOnesIsStillThere() throws {
        let directory = try TemporaryDirectory.make("run-log-failed-slow")
        defer { try? FileManager.default.removeItem(at: directory) }
        let slow = try #require(RunLog.open(inDirectory: directory))
        for _ in 0 ..< RunLog.keptLogs {
            let quick = try #require(RunLog.open(inDirectory: directory))
            quick.close()
            quick.keepFailure(tag: "bbbbbbbb")
        }

        slow.close()
        slow.keepFailure(tag: "aaaaaaaa")

        #expect(slow.url.lastPathComponent.hasPrefix("failed-aaaaaaaa-"))
        #expect(FileManager.default.fileExists(atPath: slow.url.path))
        #expect(try Self.names(in: directory).count { $0.hasPrefix(RunLog.KeptPool.failed.rawValue) } == RunLog.keptLogs)
    }

    /// A slow run published after quick ones that ran during it lives for the next `keptLogs - 1` runs, as its line says, and not one more.
    @Test
    func aSlowRunsLogLivesForTheRunsItsLineNames() throws {
        let directory = try TemporaryDirectory.make("run-log-slow-ordinary")
        defer { try? FileManager.default.removeItem(at: directory) }
        let slow = try #require(RunLog.open(inDirectory: directory))
        for _ in 1 ..< RunLog.keptLogs {
            RunLog.open(inDirectory: directory)?.close()
        }
        slow.close()

        for _ in 1 ..< RunLog.keptLogs {
            RunLog.open(inDirectory: directory)?.close()
        }
        #expect(FileManager.default.fileExists(atPath: slow.url.path))

        RunLog.open(inDirectory: directory)?.close()
        #expect(!FileManager.default.fileExists(atPath: slow.url.path))
    }

    /// A run that ran nothing stays an ordinary log and leaves its command's kept failures alone: a mistyped filter never passes, so it must not hold a failed slot.
    @Test
    func aRunThatRanNothingStaysOrdinaryAndClearsNothing() throws {
        let directory = try TemporaryDirectory.make("run-log-ran-nothing")
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = ["swift", "test", "--filter", "Nope"]
        let failed = try #require(RunLog.open(inDirectory: directory))
        failed.close()
        failed.settle(exitCode: 1, command: command, in: directory)
        let nothing = try #require(RunLog.open(inDirectory: directory))
        nothing.close()

        nothing.settle(exitCode: RunTestSelector.exitCode, command: command, in: directory)

        #expect(nothing.url.lastPathComponent.hasPrefix("run-"))
        #expect(RunLog.retention(ofPath: nothing.url.path) == "kept for the next \(RunLog.keptLogs - 1) runs")
        #expect(FileManager.default.fileExists(atPath: failed.url.path))
    }

    /// Different commands, or the same one elsewhere, get different tags; the same command the same tag.
    @Test
    func theCommandTagSeparatesCommandsAndDirectories() {
        let here = URL(fileURLWithPath: "/tmp/a")
        let tag = RunLog.commandTag(["swift", "test"], in: here)

        #expect(tag == RunLog.commandTag(["swift", "test"], in: here))
        #expect(tag != RunLog.commandTag(["swift", "build"], in: here))
        #expect(tag != RunLog.commandTag(["swift", "test"], in: URL(fileURLWithPath: "/tmp/b")))
    }

    /// Each kind of log states how long it lives.
    @Test
    func theRetentionWordsFollowThePoolTheLogStandsIn() {
        #expect(RunLog.retention(ofPath: ".sift/runs/run-a.log") == "kept for the next \(RunLog.keptLogs - 1) runs")
        #expect(RunLog.retention(ofPath: ".sift/runs/failed-aaaaaaaa-run-a.log") == "kept until it passes or \(RunLog.keptLogs) newer failures")
        #expect(RunLog.retention(ofPath: ".sift/runs/unbuilt-run-a.log") == "kept among the last \(RunLog.keptLogs) of its kind")
    }
}
