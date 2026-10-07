//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the record a sharded run leaves of its simulators, and the question every actor asks it: is anybody still going to clean this up?
@Suite(.temporaryDirectories)
struct ShardLedgerTests {
    /// The intent is the cover for the create window, so it has to be on disk the moment it is recorded rather than at the end of the run.
    @Test
    func anIntentIsOnDiskAsSoonAsItIsRecorded() throws {
        let root = try TemporaryDirectory.make("shard-ledger")
        var ledger = try ShardLedger(repositoryRoot: root, runID: "0f9e8d7c", prefix: "a1b2c3", owner: owner(), started: { _ in nil })

        let name = try ledger.recordIntent(shard: 0)
        let onDisk = try reading(root: root, runID: "0f9e8d7c")

        #expect(name == "sift-a1b2c3-0f9e8d7c-0")
        #expect(onDisk.shards == [ShardLedger.Shard(index: 0, name: name)])
        #expect(onDisk.udids.isEmpty)
    }

    /// The udid is what every delete is made by, so the record has to carry it whole the moment `simctl` prints it.
    @Test
    func aRecordedUdidIsOnDiskAgainstItsShard() throws {
        let root = try TemporaryDirectory.make("shard-ledger")
        var ledger = try ShardLedger(repositoryRoot: root, runID: "0f9e8d7c", prefix: "a1b2c3", owner: owner(), started: { _ in nil })
        try ledger.recordIntent(shard: 0)
        try ledger.recordIntent(shard: 1)

        try ledger.record(udid: "11111111-2222-3333-4444-555555555555", forShard: 1)

        #expect(try reading(root: root, runID: "0f9e8d7c").udids == ["11111111-2222-3333-4444-555555555555"])
    }

    /// A pid is reused within hours on a busy machine, so a stranger holding the owner's pid must not read as the owner.
    @Test
    func aReusedPidWithAnotherStartTimeIsNotAlive() throws {
        let root = try TemporaryDirectory.make("shard-ledger")
        let ledger = try ShardLedger(
            repositoryRoot: root,
            runID: "0f9e8d7c",
            prefix: "a1b2c3",
            owner: ShardLedger.Identity(pid: 4711, startMicroseconds: 111),
            started: { pid in pid == 4711 ? 999 : nil }
        )

        #expect(!ledger.isAlive)
    }

    /// An owner whose start time could not be read is refused before anything is written: on disk it would read as dead, and a parallel run's sweep deletes a dead run's devices.
    @Test
    func anOwnerWithNoStartTimeIsRefusedAndNothingIsWritten() throws {
        let root = try TemporaryDirectory.make("shard-ledger")
        let unjudged = ShardLedger.Identity.current(started: { _ in nil })

        #expect(throws: ShardError.self) {
            _ = try ShardLedger(repositoryRoot: root, runID: "0f9e8d7c", prefix: "a1b2c3", owner: unjudged)
        }
        #expect(ShardLedger.runIDs(in: root).isEmpty)
    }

    /// The owner and the watcher are two chances at the same cleanup, and either one alive is enough to leave the run's devices alone.
    @Test
    func aWatcherKeepsARunAliveOnceItsOwnerIsGone() throws {
        let root = try TemporaryDirectory.make("shard-ledger")
        var ledger = try ShardLedger(
            repositoryRoot: root,
            runID: "0f9e8d7c",
            prefix: "a1b2c3",
            owner: ShardLedger.Identity(pid: 4711, startMicroseconds: 111),
            started: { pid in pid == 4712 ? 222 : nil }
        )

        #expect(!ledger.isAlive)
        try ledger.recordWatcher(ShardLedger.Identity(pid: 4712, startMicroseconds: 222))
        #expect(ledger.isAlive)
        #expect(try reading(root: root, runID: "0f9e8d7c", started: { pid in pid == 4712 ? 222 : nil }).isAlive)
    }

    /// A record this version cannot decode names no pid at all, so no process could be its owner and the run is dead.
    @Test
    func aCorruptRecordReadsAsUnreadable() throws {
        let root = try TemporaryDirectory.make("shard-ledger")
        _ = try ShardLedger(repositoryRoot: root, runID: "0f9e8d7c", prefix: "a1b2c3", owner: owner(), started: { _ in nil })
        let url = ShardLedger.directory(in: root, runID: "0f9e8d7c").appendingPathComponent("ledger.json")
        try Data("{ half a rec".utf8).write(to: url)

        guard case .unreadable = ShardLedger.read(repositoryRoot: root, runID: "0f9e8d7c", started: { _ in nil }) else {
            Issue.record("a record that cannot be decoded is unreadable")
            return
        }
    }

    /// A run that left no record at all is the other thing the sweep has to tell apart from a live one.
    @Test
    func aRunWithNoRecordReadsAsMissing() throws {
        let root = try TemporaryDirectory.make("shard-ledger")

        guard case .missing = ShardLedger.read(repositoryRoot: root, runID: "0f9e8d7c", started: { _ in nil }) else {
            Issue.record("a run with no file on disk is missing")
            return
        }
    }

    /// The prefix is minted once per checkout: every later run of every later session has to read the same one, or its devices would be invisible to the sweep.
    @Test
    func theDevicePrefixIsMintedOnceAndReadBackAfterwards() throws {
        let root = try TemporaryDirectory.make("shard-ledger")

        let minted = try ShardLedger.devicePrefix(in: root, mint: { "a1b2c3" })
        let second = try ShardLedger.devicePrefix(in: root, mint: { "ffffff" })

        #expect(minted == "a1b2c3")
        #expect(second == "a1b2c3")
    }

    /// A prefix that is not six lowercase hex characters matches no device name, so the cheapest correct answer is a new one.
    @Test
    func aMalformedPrefixIsReMinted() throws {
        let root = try TemporaryDirectory.make("shard-ledger")
        let url = SiftPaths.cache(in: root).appendingPathComponent("device-prefix")
        try FileManager.default.createDirectory(at: SiftPaths.cache(in: root), withIntermediateDirectories: true)
        try Data("not hex at all\n".utf8).write(to: url)

        #expect(try ShardLedger.devicePrefix(in: root, mint: { "a1b2c3" }) == "a1b2c3")
        #expect(try ShardLedger.devicePrefix(in: root, mint: { "ffffff" }) == "a1b2c3")
    }

    /// A prefix written with the newline a person's editor adds is the prefix it says it is.
    @Test
    func aPrefixIsReadThroughTheWhitespaceAroundIt() throws {
        let root = try TemporaryDirectory.make("shard-ledger")
        let url = SiftPaths.cache(in: root).appendingPathComponent("device-prefix")
        try FileManager.default.createDirectory(at: SiftPaths.cache(in: root), withIntermediateDirectories: true)
        try Data("a1b2c3\n".utf8).write(to: url)

        #expect(try ShardLedger.devicePrefix(in: root, mint: { "ffffff" }) == "a1b2c3")
    }

    /// A minted identifier is the shape the device names are parsed back out of, so the two have to agree on what hex means.
    @Test
    func mintedIdentifiersAreTheShapeTheNamesAreParsedIn() {
        #expect(ShardDeviceName.isHexadecimal(ShardLedger.newRunID(), count: 8))
        #expect(ShardDeviceName.isHexadecimal(ShardLedger.newPrefix(), count: 6))
    }

    /// The run's directory holds its result bundles as well as its record, and cleaning up takes all of it.
    @Test
    func removingTakesTheRunsDirectoryWithIt() throws {
        let root = try TemporaryDirectory.make("shard-ledger")
        let ledger = try ShardLedger(repositoryRoot: root, runID: "0f9e8d7c", prefix: "a1b2c3", owner: owner(), started: { _ in nil })
        #expect(ShardLedger.runIDs(in: root) == ["0f9e8d7c"])

        try ledger.remove()

        #expect(!FileManager.default.fileExists(atPath: ledger.directory.path))
        #expect(ShardLedger.runIDs(in: root).isEmpty)
        try ledger.remove()
    }

    /// Every run under `.sift/shards` is a run the sweep has to ask about, and they come back in one order so an answer reads the same twice.
    @Test
    func everyRunThatLeftARecordIsListed() throws {
        let root = try TemporaryDirectory.make("shard-ledger")
        _ = try ShardLedger(repositoryRoot: root, runID: "0f9e8d7c", prefix: "a1b2c3", owner: owner(), started: { _ in nil })
        _ = try ShardLedger(repositoryRoot: root, runID: "00112233", prefix: "a1b2c3", owner: owner(), started: { _ in nil })

        #expect(ShardLedger.runIDs(in: root) == ["00112233", "0f9e8d7c"])
    }
}

private extension ShardLedgerTests {
    func owner() -> ShardLedger.Identity {
        ShardLedger.Identity(pid: 4711, startMicroseconds: 111)
    }

    func reading(
        root: URL,
        runID: String,
        started: @escaping @Sendable (Int32) -> UInt64? = { _ in nil },
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> ShardLedger {
        guard case let .ledger(ledger) = ShardLedger.read(repositoryRoot: root, runID: runID, started: started) else {
            Issue.record("\(runID) should have a readable record on disk", sourceLocation: sourceLocation)
            throw ShardError.ledger("no readable record for \(runID)")
        }
        return ledger
    }
}
