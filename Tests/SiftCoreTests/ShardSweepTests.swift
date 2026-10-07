//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the sweep a new run makes over what earlier runs left behind, through an injected runner — no test here lists, creates or deletes a real device.
@Suite(.temporaryDirectories)
struct ShardSweepTests {
    /// A dead run owes every device it has, so the sweep deletes what its record names together with what it created and never recorded.
    @Test
    func aDeadRunLosesTheDevicesItRecordedAndTheOnesItNeverDid() throws {
        let root = try TemporaryDirectory.make("shard-sweep")
        let ledger = try Self.ledger(in: root, runID: Self.deadRun, udids: [Self.firstUdid])
        var commands: [[String]] = []
        let run = Self.runner(listing: [Self.device(Self.firstUdid, shard: 0), Self.device(Self.secondUdid, shard: 1)], record: { commands.append($0) })

        let report = ShardSweep.sweep(repositoryRoot: root, prefix: Self.prefix, run: run, started: { _ in nil })

        #expect(Self.deleted(from: commands) == [Self.firstUdid, Self.secondUdid])
        #expect(report.sentences == ["swept 2 simulators left by run \(Self.deadRun), which is no longer running"])
        #expect(report.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ledger.directory.path))
    }

    /// A run somebody is still going to clean up keeps everything, including a device its record has not caught up with — that is another session inside its own create window.
    @Test
    func aLiveRunKeepsEverythingIncludingTheDeviceItHasNotRecordedYet() throws {
        let root = try TemporaryDirectory.make("shard-sweep")
        let ledger = try Self.ledger(in: root, runID: Self.deadRun, udids: [Self.firstUdid])
        var commands: [[String]] = []
        let run = Self.runner(listing: [Self.device(Self.firstUdid, shard: 0), Self.device(Self.secondUdid, shard: 1)], record: { commands.append($0) })

        let report = ShardSweep.sweep(repositoryRoot: root, prefix: Self.prefix, run: run, started: { pid in pid == Self.ownerPid ? Self.ownerStart : nil })

        #expect(Self.deleted(from: commands).isEmpty)
        #expect(report == ShardSweep.Report(sentences: [], failures: []))
        #expect(FileManager.default.fileExists(atPath: ledger.fileURL.path))
    }

    /// The name only finds candidates, and it finds them whole: a name this tool did not write and another checkout's prefix are both somebody else's device.
    @Test
    func onlyANameThisCheckoutStrictlySpellsIsEverLookedAt() throws {
        let root = try TemporaryDirectory.make("shard-sweep")
        var commands: [[String]] = []
        let listing = [
            ShardDevices.Device(udid: Self.firstUdid, name: "sift-\(Self.prefix)-\(Self.deadRun)-0-copy"),
            ShardDevices.Device(udid: Self.secondUdid, name: "sift-\(Self.prefix)-\(Self.deadRun)-00"),
            ShardDevices.Device(udid: Self.thirdUdid, name: "sift-ffffff-\(Self.deadRun)-0"),
            ShardDevices.Device(udid: Self.fourthUdid, name: "iPhone 17"),
        ]
        let run = Self.runner(listing: listing, record: { commands.append($0) })

        let report = ShardSweep.sweep(repositoryRoot: root, prefix: Self.prefix, run: run, started: { _ in nil })

        #expect(Self.deleted(from: commands).isEmpty)
        #expect(report == ShardSweep.Report(sentences: [], failures: []))
    }

    /// The run asking for the sweep is alive by definition, and its own record names devices it is about to create.
    @Test
    func theCallersOwnRunIsNeverSweptByItself() throws {
        let root = try TemporaryDirectory.make("shard-sweep")
        let ledger = try Self.ledger(in: root, runID: Self.deadRun, udids: [Self.firstUdid])
        var commands: [[String]] = []
        let run = Self.runner(listing: [Self.device(Self.firstUdid, shard: 0)], record: { commands.append($0) })

        let report = ShardSweep.sweep(repositoryRoot: root, prefix: Self.prefix, excluding: Self.deadRun, run: run, started: { _ in nil })

        #expect(Self.deleted(from: commands).isEmpty)
        #expect(report == ShardSweep.Report(sentences: [], failures: []))
        #expect(FileManager.default.fileExists(atPath: ledger.fileURL.path))
    }

    /// A device still on the disk keeps the record that names it, so the next sweep tries again — and the line carries the command a person runs by hand.
    @Test
    func aDeviceThatCouldNotBeDeletedKeepsTheRecordForTheNextSweep() throws {
        let root = try TemporaryDirectory.make("shard-sweep")
        let ledger = try Self.ledger(in: root, runID: Self.deadRun, udids: [Self.firstUdid, Self.secondUdid])
        let run = Self.runner(listing: [], failing: [Self.secondUdid])

        let report = ShardSweep.sweep(repositoryRoot: root, prefix: Self.prefix, run: run, started: { _ in nil })

        #expect(report.failures.map(\.udid) == [Self.secondUdid])
        #expect(report.sentences == [
            "swept 1 simulator left by run \(Self.deadRun), which is no longer running",
            "could not delete \(Self.secondUdid) left by run \(Self.deadRun): An error was encountered processing the command — run: xcrun simctl shutdown \(Self.secondUdid); xcrun simctl delete \(Self.secondUdid) — or `sift test --sweep` to retry",
        ])
        #expect(FileManager.default.fileExists(atPath: ledger.fileURL.path))
    }

    /// A record nothing can read is a run nothing is going to clean up, so its directory and its devices go the same way a dead run's do.
    @Test
    func aRecordNothingCanReadIsADeadRun() throws {
        let root = try TemporaryDirectory.make("shard-sweep")
        let directory = ShardLedger.directory(in: root, runID: Self.deadRun)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a record at all".utf8).write(to: directory.appendingPathComponent(ShardLedger.fileName))
        var commands: [[String]] = []
        let run = Self.runner(listing: [Self.device(Self.firstUdid, shard: 0)], record: { commands.append($0) })

        let report = ShardSweep.sweep(repositoryRoot: root, prefix: Self.prefix, run: run, started: { _ in nil })

        #expect(Self.deleted(from: commands) == [Self.firstUdid])
        #expect(report.sentences == ["swept 1 simulator left by run \(Self.deadRun), which is no longer running"])
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    /// A listing nothing could read is no devices, which still leaves every udid the records name to be swept by the records.
    @Test
    func aListingThatCouldNotBeReadStillSweepsWhatTheRecordNames() throws {
        let root = try TemporaryDirectory.make("shard-sweep")
        try Self.ledger(in: root, runID: Self.deadRun, udids: [Self.firstUdid])
        var commands: [[String]] = []
        let run: ShardDevices.Run = { _, arguments in
            commands.append(arguments)
            guard arguments.contains("list") else {
                return SimulatorAccessibility.Output(succeeded: true, standardOutput: "")
            }
            return SimulatorAccessibility.Output(succeeded: false, standardOutput: "", standardError: "xcrun: error")
        }

        let report = ShardSweep.sweep(repositoryRoot: root, prefix: Self.prefix, run: run, started: { _ in nil })

        #expect(Self.deleted(from: commands) == [Self.firstUdid])
        #expect(report.sentences == ["swept 1 simulator left by run \(Self.deadRun), which is no longer running"])
    }

    /// A dead run whose devices are already gone is a stale directory and nothing else, and a sweep that deleted nothing says nothing.
    @Test
    func aDeadRunWithNoDevicesLosesItsDirectorySilently() throws {
        let root = try TemporaryDirectory.make("shard-sweep")
        let ledger = try Self.ledger(in: root, runID: Self.deadRun)

        let report = ShardSweep.sweep(repositoryRoot: root, prefix: Self.prefix, run: Self.runner(listing: []), started: { _ in nil })

        #expect(report == ShardSweep.Report(sentences: [], failures: []))
        #expect(!FileManager.default.fileExists(atPath: ledger.directory.path))
    }

    /// A checkout with no records and no devices of its own has nothing to say.
    @Test
    func nothingToSweepIsAnEmptyReport() throws {
        let root = try TemporaryDirectory.make("shard-sweep")

        let report = ShardSweep.sweep(repositoryRoot: root, prefix: Self.prefix, run: Self.runner(listing: []), started: { _ in nil })

        #expect(report == ShardSweep.Report(sentences: [], failures: []))
    }
}

private extension ShardSweepTests {
    static var prefix: String {
        "a1b2c3"
    }

    static var deadRun: String {
        "0f9e8d7c"
    }

    static var ownerPid: Int32 {
        4711
    }

    static var ownerStart: UInt64 {
        111
    }

    static var firstUdid: String {
        "11111111-2222-3333-4444-555555555555"
    }

    static var secondUdid: String {
        "66666666-7777-8888-9999-000000000000"
    }

    static var thirdUdid: String {
        "22222222-3333-4444-5555-666666666666"
    }

    static var fourthUdid: String {
        "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    }

    /// A run's record on disk, with a udid recorded for each device it is said to have created.
    @discardableResult
    static func ledger(in root: URL, runID: String, udids: [String] = []) throws -> ShardLedger {
        var ledger = try ShardLedger(
            repositoryRoot: root,
            runID: runID,
            prefix: prefix,
            owner: ShardLedger.Identity(pid: ownerPid, startMicroseconds: ownerStart),
            started: { _ in nil }
        )
        for (index, udid) in udids.enumerated() {
            try ledger.recordIntent(shard: index)
            try ledger.record(udid: udid, forShard: index)
        }
        return ledger
    }

    /// One of the dead run's devices, named the way this tool names them.
    static func device(_ udid: String, shard index: Int) -> ShardDevices.Device {
        ShardDevices.Device(udid: udid, name: ShardDeviceName(prefix: prefix, runID: deadRun, index: index).text)
    }

    /// A `simctl` that lists exactly those devices, refuses to delete the named udids, and succeeds at everything else.
    static func runner(
        listing devices: [ShardDevices.Device],
        failing: [String] = [],
        record: @escaping ([String]) -> Void = { _ in }
    ) -> ShardDevices.Run {
        { _, arguments in
            record(arguments)
            guard !arguments.contains("list") else {
                return SimulatorAccessibility.Output(succeeded: true, standardOutput: listingText(devices))
            }
            guard arguments.contains("delete"), let udid = arguments.last, failing.contains(udid) else {
                return SimulatorAccessibility.Output(succeeded: true, standardOutput: "")
            }
            return SimulatorAccessibility.Output(succeeded: false, standardOutput: "", standardError: "An error was encountered processing the command")
        }
    }

    /// What `simctl list devices -j` prints for those devices, in the shape the real one prints — every device under its runtime identifier.
    static func listingText(_ devices: [ShardDevices.Device]) -> String {
        let entries = devices.map { device in
            "{ \"udid\": \"\(device.udid)\", \"name\": \"\(device.name)\", \"state\": \"Shutdown\", \"isAvailable\": true }"
        }
        return """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [\(entries.joined(separator: ", "))]
          }
        }
        """
    }

    /// Every udid a delete was actually made by, in the order the deletes were made.
    static func deleted(from commands: [[String]]) -> [String] {
        commands.filter { $0.contains("delete") }.compactMap(\.last)
    }
}
