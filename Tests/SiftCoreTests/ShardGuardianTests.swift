//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers what a shard watcher does with what it read, through an injected runner and an injected ender — no test here starts a process or touches a real device.
@Suite(.temporaryDirectories)
struct ShardGuardianTests {
    /// An owner that let its watcher go cleaned up itself, so the watcher touches nothing at all — not the processes it was told about, and not the devices still named in the record.
    @Test
    func aReleasedWatcherEndsNothingAndDeletesNothing() throws {
        let root = try TemporaryDirectory.make("shard-guardian")
        let ledger = try Self.ledgerWithTwoDevices(in: root)
        try Self.writeSessions(beside: ledger)
        var ended: [[SetAsideChildren.Session]] = []
        var commands: [[String]] = []

        let status = ShardGuardian.sweep(
            read: ShardGuardian.released,
            runID: Self.runID,
            repositoryRoot: root,
            run: { _, arguments in
                commands.append(arguments)
                return SimulatorAccessibility.Output(succeeded: true, standardOutput: "")
            },
            endSessions: { ended.append($0) }
        )

        #expect(status == 0)
        #expect(ended.isEmpty)
        #expect(commands.isEmpty)
        #expect(FileManager.default.fileExists(atPath: ledger.fileURL.path))
    }

    /// An `xcodebuild` still driving a device that is being deleted is what this exists to rule out, so every session the owner recorded is ended before the first `simctl` runs.
    @Test
    func anOwnerGoneEndsTheTestProcessesBeforeTheFirstDelete() throws {
        let root = try TemporaryDirectory.make("shard-guardian")
        let ledger = try Self.ledgerWithTwoDevices(in: root)
        try Self.writeSessions(beside: ledger)
        var ended: [SetAsideChildren.Session] = []
        var endedBeforeEveryDelete = true

        let status = ShardGuardian.sweep(
            read: nil,
            runID: Self.runID,
            repositoryRoot: root,
            run: { _, _ in
                endedBeforeEveryDelete = endedBeforeEveryDelete && !ended.isEmpty
                return SimulatorAccessibility.Output(succeeded: true, standardOutput: "")
            },
            endSessions: { ended += $0 }
        )

        #expect(endedBeforeEveryDelete)
        #expect(ended == [SetAsideChildren.Session(pid: 4711, started: 8_100_200), SetAsideChildren.Session(pid: 4712, started: 8_100_300)])
        #expect(status == 0)
        #expect(!FileManager.default.fileExists(atPath: ledger.directory.path))
    }

    /// A device still on the disk keeps the record exactly where it was, so the next run's sweep retries it rather than forgetting the udid.
    @Test
    func aFailedDeleteKeepsTheRecordForTheNextSweep() throws {
        let root = try TemporaryDirectory.make("shard-guardian")
        let ledger = try Self.ledgerWithTwoDevices(in: root)

        let status = ShardGuardian.sweep(
            read: nil,
            runID: Self.runID,
            repositoryRoot: root,
            run: { _, arguments in
                guard arguments.last == Self.secondUdid, arguments.contains("delete") else {
                    return SimulatorAccessibility.Output(succeeded: true, standardOutput: "")
                }
                return SimulatorAccessibility.Output(succeeded: false, standardOutput: "", standardError: "An error was encountered processing the command")
            },
            endSessions: { _ in }
        )

        #expect(status == 1)
        #expect(FileManager.default.fileExists(atPath: ledger.fileURL.path))
    }

    /// A record that is already gone is a run that deleted its own devices before it died, and there is nothing left to delete them by.
    @Test
    func aRunWhoseRecordIsGoneLeavesNothingToDelete() throws {
        let root = try TemporaryDirectory.make("shard-guardian")
        var commands: [[String]] = []

        let status = ShardGuardian.sweep(
            read: nil,
            runID: Self.runID,
            repositoryRoot: root,
            run: { _, arguments in
                commands.append(arguments)
                return SimulatorAccessibility.Output(succeeded: true, standardOutput: "")
            },
            endSessions: { _ in }
        )

        #expect(status == 0)
        #expect(commands.isEmpty)
    }

    /// The sessions the owner records sit beside the run's own record, so the watcher finds them from the run id alone.
    @Test
    func theSessionsSitBesideTheRunsRecord() throws {
        let root = try TemporaryDirectory.make("shard-guardian")
        let ledger = try Self.ledger(in: root)

        #expect(ShardGuardian.sessionsFile(for: ledger) == ledger.directory.appendingPathComponent("sessions"))
        #expect(ShardGuardian.sessionsFile(for: ledger) == ShardGuardian.sessionsFile(inRunDirectory: ledger.directory))
    }
}

private extension ShardGuardianTests {
    static var runID: String {
        "0f9e8d7c"
    }

    static var firstUdid: String {
        "11111111-2222-3333-4444-555555555555"
    }

    static var secondUdid: String {
        "66666666-7777-8888-9999-000000000000"
    }

    static func ledger(in root: URL) throws -> ShardLedger {
        try ShardLedger(
            repositoryRoot: root,
            runID: runID,
            prefix: "a1b2c3",
            owner: ShardLedger.Identity(pid: 4711, startMicroseconds: 111),
            started: { _ in nil }
        )
    }

    static func ledgerWithTwoDevices(in root: URL) throws -> ShardLedger {
        var ledger = try ledger(in: root)
        try ledger.recordIntent(shard: 0)
        try ledger.record(udid: firstUdid, forShard: 0)
        try ledger.recordIntent(shard: 1)
        try ledger.record(udid: secondUdid, forShard: 1)
        return ledger
    }

    /// Two sessions written the way the owner writes them, which is the only thing the watcher reads them from.
    static func writeSessions(beside ledger: ShardLedger) throws {
        try "4711 8100200\n4712 8100300\n".write(to: ShardGuardian.sessionsFile(for: ledger), atomically: true, encoding: .utf8)
    }
}
