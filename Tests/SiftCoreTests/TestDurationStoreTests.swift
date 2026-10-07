//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers what a repository remembers about what its tests cost, and the rule for which timings are allowed in at all.
@Suite(.temporaryDirectories)
struct TestDurationStoreTests {
    /// The answer is a median, so the one observation charged the bundle's load moves it by nothing like what it would move a mean.
    @Test
    func theMedianLeavesTheBundleLoadWhereItBelongs() throws {
        var store = try TestDurationStore(repositoryRoot: TemporaryDirectory.make("durations"))
        // The first of these ran first in its bundle and was charged the load; the other two were not.
        for seconds in [4.0, 0.02, 0.03] {
            store.record(recording([("aTest()", seconds)]))
        }

        #expect(store.median(for: "aTest()") == 0.03)
        #expect(store.median(for: "neverRun()") == nil)
    }

    /// A timing taken while something in the run was being retried is a timing of the retry, so the whole recording is dropped — the healthy-looking tests beside it included.
    @Test
    func aRetriedRunRecordsNothing() throws {
        let root = try TemporaryDirectory.make("durations")
        var store = TestDurationStore(repositoryRoot: root)
        store.record(TestDurationStore.Recording(observations: [
            TestDurationStore.Timing(identifier: "aTest()", seconds: 0.5),
            TestDurationStore.Timing(identifier: "otherTest()", seconds: 0.5),
        ], retried: true))

        #expect(store.median(for: "aTest()") == nil)
        #expect(store.median(for: "otherTest()") == nil)
        // Nothing was kept, so nothing was written either.
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    /// A run that lost a test is a run that ended in a way nobody planned, and its other timings were taken in it.
    @Test
    func aRunMissingATestRecordsNothing() throws {
        var store = try TestDurationStore(repositoryRoot: TemporaryDirectory.make("durations"))
        store.record(TestDurationStore.Recording(observations: [TestDurationStore.Timing(identifier: "aTest()", seconds: 0.5)], missing: 1))

        #expect(store.median(for: "aTest()") == nil)
    }

    /// Within a kept run, only the first iteration of a test is a timing of the test rather than of a repeat over a warmed machine.
    @Test
    func onlyTheFirstIterationOfATestIsKept() throws {
        var store = try TestDurationStore(repositoryRoot: TemporaryDirectory.make("durations"))
        store.record(TestDurationStore.Recording(observations: [
            TestDurationStore.Timing(identifier: "aTest()", seconds: 0.5),
            TestDurationStore.Timing(identifier: "aTest()", seconds: 0.1, iteration: 2),
        ]))

        #expect(store.observations(for: "aTest()").map(\.seconds) == [0.5])
    }

    /// Five observations are kept, and the sixth evicts the oldest, so the answer follows a suite as its cost changes instead of averaging in what it used to be.
    @Test
    func aSixthObservationEvictsTheOldest() throws {
        var store = try TestDurationStore(repositoryRoot: TemporaryDirectory.make("durations"))
        for seconds in [1.0, 2.0, 3.0, 4.0, 5.0, 6.0] {
            store.record(recording([("aTest()", seconds)]))
        }

        #expect(store.observations(for: "aTest()").map(\.seconds) == [2.0, 3.0, 4.0, 5.0, 6.0])
    }

    /// The file is the whole store, so what one run wrote is what the next run reads.
    @Test
    func whatOneRunWroteTheNextRunReads() throws {
        let root = try TemporaryDirectory.make("durations")
        var first = TestDurationStore(repositoryRoot: root)
        first.record(recording([("aTest()", 0.25)]))

        #expect(TestDurationStore(repositoryRoot: root).median(for: "aTest()") == 0.25)
        #expect(first.fileURL.lastPathComponent == "test-durations.json")
        #expect(first.fileURL.deletingLastPathComponent().lastPathComponent == ".sift")
    }

    /// A file nobody can read is an empty store, never an error: these are timings, and a run that cannot read its last five plans from none rather than failing.
    @Test
    func aCorruptFileReadsAsEmpty() throws {
        let root = try TemporaryDirectory.make("durations")
        var seeded = TestDurationStore(repositoryRoot: root)
        seeded.record(recording([("aTest()", 0.25)]))
        try Data("{ this is not JSON".utf8).write(to: seeded.fileURL)

        let noted = root.appendingPathComponent("noted.txt")
        var store = TestDurationStore(repositoryRoot: root, note: { try? Data($0.utf8).write(to: noted) })
        #expect(store.median(for: "aTest()") == nil)
        // Empty, but not silently: a store that threw its last five away says so.
        #expect(FileManager.default.fileExists(atPath: noted.path))

        // And an empty store is a working store: the next run's timings go in on top of it.
        store.record(recording([("aTest()", 0.5)]))
        #expect(TestDurationStore(repositoryRoot: root).median(for: "aTest()") == 0.5)
    }

    /// A test nobody has run in ninety days has been renamed, deleted or moved far more often than it is about to run again, and its entry would otherwise sit in the file forever.
    @Test
    func aTestUnseenForNinetyDaysIsDropped() throws {
        let root = try TemporaryDirectory.make("durations")
        let ninetyOneDaysAgo = Date(timeIntervalSinceNow: -91 * 24 * 60 * 60)
        var old = TestDurationStore(repositoryRoot: root, now: { ninetyOneDaysAgo })
        old.record(recording([("goneTest()", 0.25)]))

        var current = TestDurationStore(repositoryRoot: root)
        #expect(current.median(for: "goneTest()") == 0.25)
        current.record(recording([("liveTest()", 0.5)]))

        let reopened = TestDurationStore(repositoryRoot: root)
        #expect(reopened.median(for: "goneTest()") == nil)
        #expect(reopened.median(for: "liveTest()") == 0.5)
    }

    /// A run that measured nothing eligible leaves the file alone, rather than rewriting it to say the same thing.
    @Test
    func aRecordingWithNoFirstIterationLeavesNoFile() throws {
        var store = try TestDurationStore(repositoryRoot: TemporaryDirectory.make("durations"))
        store.record(TestDurationStore.Recording(observations: [TestDurationStore.Timing(identifier: "aTest()", seconds: 0.5, iteration: 2)]))

        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    /// A clean run of first attempts, which is what most of these cases differ from.
    private func recording(_ timings: [(String, Double)]) -> TestDurationStore.Recording {
        TestDurationStore.Recording(observations: timings.map { TestDurationStore.Timing(identifier: $0.0, seconds: $0.1) })
    }
}
