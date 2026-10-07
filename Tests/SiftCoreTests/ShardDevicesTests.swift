//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers every simulator operation a sharded run makes, through an injected runner — no test here creates, boots or deletes a real device.
@Suite(.temporaryDirectories)
struct ShardDevicesTests {
    /// With no version named, a run takes the newest installed runtime that actually runs the device type — and an unavailable one is not installed.
    @Test
    func resolveTakesTheNewestInstalledRuntimeThatRunsTheDeviceType() throws {
        let resolution = try ShardDevices.resolve(deviceTypeName: "iPhone 17", run: Self.catalogueRunner())

        #expect(resolution.deviceType == "com.apple.CoreSimulator.SimDeviceType.iPhone-17")
        #expect(resolution.runtime == "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        #expect(resolution.osVersion == "27.0")
    }

    /// A version written short names the longer spelling of itself, which is the reading `-destination OS=` already has.
    @Test
    func resolveTakesTheVersionThatWasNamed() throws {
        let resolution = try ShardDevices.resolve(deviceTypeName: "iPhone 17", osVersion: "26", run: Self.catalogueRunner())

        #expect(resolution.runtime == "com.apple.CoreSimulator.SimRuntime.iOS-26-0")
        #expect(resolution.osVersion == "26.0")
    }

    /// A device type nobody has is a refusal that says what `simctl` does spell, since the spelling is the thing that was wrong.
    @Test
    func resolveRefusesADeviceTypeNobodyHasAndSaysWhatExists() {
        let thrown = Self.failure { try ShardDevices.resolve(deviceTypeName: "iPhone 17 Ultra", run: Self.catalogueRunner()) }

        #expect(thrown?.contains("no simulator device type is named iPhone 17 Ultra") == true)
        #expect(thrown?.contains("iPhone 17") == true)
    }

    /// A version nobody has installed is the other half of the same refusal, and it lists the versions that would have worked.
    @Test
    func resolveRefusesAVersionNobodyHasInstalled() {
        let thrown = Self.failure { try ShardDevices.resolve(deviceTypeName: "iPhone 17", osVersion: "19", run: Self.catalogueRunner()) }

        #expect(thrown?.contains("it runs on: 26.0, 27.0") == true)
    }

    /// The intent is the cover for the create window, so it is on disk before `simctl create` is spawned — the runner here reads the record and says what it found.
    @Test
    func theIntentIsInTheRecordBeforeAnythingIsCreated() throws {
        let root = try TemporaryDirectory.make("shard-devices")
        var ledger = try Self.ledger(in: root)
        var seenWhenCreateRan: [ShardLedger.Shard] = []
        let run: ShardDevices.Run = { _, _ in
            seenWhenCreateRan = try Self.recorded(in: root).shards
            return SimulatorAccessibility.Output(succeeded: true, standardOutput: "\(Self.firstUdid)\n")
        }

        let udid = try ShardDevices.create(shard: 0, in: &ledger, resolution: Self.resolution, run: run)

        #expect(seenWhenCreateRan == [ShardLedger.Shard(index: 0, name: "sift-a1b2c3-0f9e8d7c-0")])
        #expect(udid == Self.firstUdid)
        #expect(try Self.recorded(in: root).udids == [Self.firstUdid])
    }

    /// A udid is what every delete is made by, so anything that is not shaped like one records nothing at all — and the device it may name is left to the sweep, which finds it by the recorded name.
    @Test
    func aCreateThatPrintsAnythingElseRecordsNoUdid() throws {
        let root = try TemporaryDirectory.make("shard-devices")
        var ledger = try Self.ledger(in: root)
        let run: ShardDevices.Run = { _, _ in
            SimulatorAccessibility.Output(succeeded: true, standardOutput: "An error was encountered processing the command\n")
        }

        var thrown: Error?
        do {
            _ = try ShardDevices.create(shard: 0, in: &ledger, resolution: Self.resolution, run: run)
        } catch {
            thrown = error
        }

        #expect(thrown is ShardError)
        #expect(ledger.udids.isEmpty)
        #expect(try Self.recorded(in: root).udids.isEmpty)
        #expect(try Self.recorded(in: root).shards.map(\.name) == ["sift-a1b2c3-0f9e8d7c-0"])
    }

    /// A create `simctl` refused is a create, and the run stops there rather than going on to boot nothing.
    @Test
    func aCreateSimctlRefusedIsAnError() throws {
        let root = try TemporaryDirectory.make("shard-devices")
        var ledger = try Self.ledger(in: root)
        let run: ShardDevices.Run = { _, _ in
            SimulatorAccessibility.Output(succeeded: false, standardOutput: "", standardError: "Invalid runtime: none\n")
        }

        var thrown: Error?
        do {
            _ = try ShardDevices.create(shard: 0, in: &ledger, resolution: Self.resolution, run: run)
        } catch {
            thrown = error
        }

        #expect("\(thrown ?? ShardError.devices(""))".contains("Invalid runtime"))
        #expect(try Self.recorded(in: root).udids.isEmpty)
    }

    /// Booting is the boot, the wait for it to have finished, and the accessibility keys the run's own tests read.
    @Test
    func bootWaitsForTheBootToFinishAndArmsAccessibility() throws {
        var commands: [[String]] = []
        let run: ShardDevices.Run = { _, arguments in
            commands.append(arguments)
            return SimulatorAccessibility.Output(succeeded: true, standardOutput: "")
        }

        try ShardDevices.boot(udid: Self.firstUdid, run: run)

        #expect(commands.first == ["simctl", "boot", Self.firstUdid])
        #expect(commands.dropFirst().first == ["simctl", "bootstatus", Self.firstUdid, "-b"])
        #expect(Array(commands.dropFirst(2)) == SimulatorAccessibility.enableArguments(udid: Self.firstUdid))
    }

    /// A device already booted is a booted device, and `simctl` refusing the second boot is not a failure of this run.
    @Test
    func aDeviceAlreadyBootedIsNotAFailure() throws {
        var commands: [[String]] = []
        let run: ShardDevices.Run = { _, arguments in
            commands.append(arguments)
            guard arguments.first(where: { $0 == "boot" }) != nil else {
                return SimulatorAccessibility.Output(succeeded: true, standardOutput: "")
            }
            return SimulatorAccessibility.Output(succeeded: false, standardOutput: "", standardError: "Unable to boot device in current state: Booted\n")
        }

        try ShardDevices.boot(udid: Self.firstUdid, run: run)

        #expect(commands.dropFirst().first == ["simctl", "bootstatus", Self.firstUdid, "-b"])
    }

    /// Deleting is the shutdown and then the delete, and the shutdown's own refusal is ignored — a device already shut down refuses it.
    @Test
    func deletingShutsDownFirstAndToleratesThatRefusal() {
        var commands: [[String]] = []
        let run: ShardDevices.Run = { _, arguments in
            commands.append(arguments)
            guard arguments.first(where: { $0 == "shutdown" }) != nil else {
                return SimulatorAccessibility.Output(succeeded: true, standardOutput: "")
            }
            return SimulatorAccessibility.Output(succeeded: false, standardOutput: "", standardError: "Unable to shutdown device in current state: Shutdown\n")
        }

        let deletion = ShardDevices.delete(udid: Self.firstUdid, run: run)

        #expect(commands == [["simctl", "shutdown", Self.firstUdid], ["simctl", "delete", Self.firstUdid]])
        #expect(deletion == ShardDevices.Deletion(udid: Self.firstUdid))
    }

    /// A device `simctl` says does not exist is gone, which is what was wanted — reporting it as a failure would send somebody to delete nothing.
    @Test
    func aDeviceSimctlDoesNotKnowCountsAsDeleted() {
        let run: ShardDevices.Run = { _, _ in
            SimulatorAccessibility.Output(succeeded: false, standardOutput: "", standardError: "Invalid device: \(Self.firstUdid)\n")
        }

        let deletion = ShardDevices.delete(udid: Self.firstUdid, run: run)

        #expect(deletion.failure == nil)
        #expect(deletion.wasAlreadyGone)
    }

    /// A delete that failed carries the reason and the exact commands a person runs by hand, because nothing else is going to do it.
    @Test
    func aFailedDeleteCarriesTheManualCommand() {
        let run: ShardDevices.Run = { _, _ in
            SimulatorAccessibility.Output(succeeded: false, standardOutput: "", standardError: "the spawn timed out: xcrun did not finish within 60s and was ended")
        }

        let deletion = ShardDevices.delete(udid: Self.firstUdid, run: run)

        #expect(deletion.failure?.contains("timed out") == true)
        #expect(deletion.command == "xcrun simctl shutdown \(Self.firstUdid); xcrun simctl delete \(Self.firstUdid)")
    }

    /// When everything went, the run's record goes with it, and the answer's devices line is one clause long.
    @Test
    func deletingEverythingRemovesTheRecord() throws {
        let root = try TemporaryDirectory.make("shard-devices")
        let ledger = try Self.ledgerWithTwoDevices(in: root)
        let run: ShardDevices.Run = { _, _ in SimulatorAccessibility.Output(succeeded: true, standardOutput: "") }

        let cleanup = ShardDevices.deleteAll(in: ledger, run: run)

        #expect(cleanup.failures.isEmpty)
        #expect(cleanup.summary == "2 simulators created, 2 deleted")
        #expect(!FileManager.default.fileExists(atPath: ledger.directory.path))
    }

    /// A device still on the disk keeps the record exactly where it was, so the next run's sweep retries it — and the answer names the device and the command.
    @Test
    func aFailedDeleteKeepsTheRecordForTheNextSweep() throws {
        let root = try TemporaryDirectory.make("shard-devices")
        let ledger = try Self.ledgerWithTwoDevices(in: root)
        let run: ShardDevices.Run = { _, arguments in
            guard arguments.last == Self.secondUdid, arguments.contains("delete") else {
                return SimulatorAccessibility.Output(succeeded: true, standardOutput: "")
            }
            return SimulatorAccessibility.Output(succeeded: false, standardOutput: "", standardError: "An error was encountered processing the command")
        }

        let cleanup = ShardDevices.deleteAll(in: ledger, run: run)

        #expect(cleanup.failures.map(\.udid) == [Self.secondUdid])
        #expect(cleanup.summary == "2 simulators created, 1 deleted — 1 left: \(Self.secondUdid) — run: xcrun simctl shutdown \(Self.secondUdid); xcrun simctl delete \(Self.secondUdid) — or `sift test --sweep` to retry")
        #expect(FileManager.default.fileExists(atPath: ledger.fileURL.path))
    }

    /// A device that was gone before the cleanup ran is deleted, and the line says so rather than quietly counting it.
    @Test
    func theSummarySaysWhichDevicesWereAlreadyGone() throws {
        let root = try TemporaryDirectory.make("shard-devices")
        let ledger = try Self.ledgerWithTwoDevices(in: root)
        let run: ShardDevices.Run = { _, arguments in
            guard arguments.last == Self.secondUdid, arguments.contains("delete") else {
                return SimulatorAccessibility.Output(succeeded: true, standardOutput: "")
            }
            return SimulatorAccessibility.Output(succeeded: false, standardOutput: "", standardError: "Invalid device: \(Self.secondUdid)")
        }

        let cleanup = ShardDevices.deleteAll(in: ledger, run: run)

        #expect(cleanup.summary == "2 simulators created, 2 deleted (1 was already gone)")
    }

    /// A run that created nothing has nothing to say about its devices.
    @Test
    func aRunThatCreatedNoDevicesSaysNothing() throws {
        let root = try TemporaryDirectory.make("shard-devices")
        let ledger = try Self.ledger(in: root)

        let cleanup = ShardDevices.deleteAll(in: ledger, run: { _, _ in SimulatorAccessibility.Output(succeeded: true, standardOutput: "") })

        #expect(cleanup.summary == nil)
    }

    /// The listing carries the name beside the udid, and that pairing is what lets a name find a device the ledger never recorded.
    @Test
    func theListingPairsEachNameWithItsUdid() {
        let devices = ShardDevices.listed(run: Self.listingRunner())

        #expect(devices.contains(ShardDevices.Device(udid: Self.firstUdid, name: "sift-a1b2c3-0f9e8d7c-0")))
        #expect(devices.count == 3)
    }

    /// A listing that could not be read is no devices, which leaves every recorded udid still to be deleted by the record.
    @Test
    func aListingThatCouldNotBeReadIsNoDevices() {
        #expect(ShardDevices.listed(run: { _, _ in SimulatorAccessibility.Output(succeeded: false, standardOutput: "", standardError: "xcrun: error") }).isEmpty)
        #expect(ShardDevices.listed(run: { _, _ in SimulatorAccessibility.Output(succeeded: true, standardOutput: "not json at all") }).isEmpty)
    }
}

private extension ShardDevicesTests {
    static var firstUdid: String {
        "11111111-2222-3333-4444-555555555555"
    }

    static var secondUdid: String {
        "66666666-7777-8888-9999-000000000000"
    }

    static var resolution: ShardDevices.Resolution {
        ShardDevices.Resolution(
            deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            osVersion: "27.0"
        )
    }

    static func ledger(in root: URL) throws -> ShardLedger {
        try ShardLedger(
            repositoryRoot: root,
            runID: "0f9e8d7c",
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

    /// The record as it now stands on disk, which is the only thing the other two actors ever see.
    static func recorded(in root: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> ShardLedger {
        guard case let .ledger(ledger) = ShardLedger.read(repositoryRoot: root, runID: "0f9e8d7c", started: { _ in nil }) else {
            Issue.record("the run should have a readable record on disk", sourceLocation: sourceLocation)
            throw ShardError.ledger("no readable record for the run")
        }
        return ledger
    }

    /// What the thrown refusal said, or `nil` where nothing was thrown.
    static func failure(_ work: () throws -> some Any) -> String? {
        do {
            _ = try work()
            return nil
        } catch {
            return "\(error)"
        }
    }

    static func catalogueRunner() -> ShardDevices.Run {
        { _, _ in SimulatorAccessibility.Output(succeeded: true, standardOutput: catalogue) }
    }

    static func listingRunner() -> ShardDevices.Run {
        { _, _ in SimulatorAccessibility.Output(succeeded: true, standardOutput: listing) }
    }

    /// What `simctl list -j devicetypes runtimes` prints, cut to the fields a resolution reads: one device type, two runtimes that run it, one newer that is not installed, and one of another platform.
    static var catalogue: String {
        """
        {
          "devicetypes": [
            { "name": "iPhone 17", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17" }
          ],
          "runtimes": [
            {
              "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-0", "version": "26.0", "isAvailable": true, "platform": "iOS",
              "supportedDeviceTypes": [{ "name": "iPhone 17", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17" }]
            },
            {
              "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version": "27.0", "isAvailable": true, "platform": "iOS",
              "supportedDeviceTypes": [{ "name": "iPhone 17", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17" }]
            },
            {
              "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-28-0", "version": "28.0", "isAvailable": false, "platform": "iOS",
              "supportedDeviceTypes": [{ "name": "iPhone 17", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17" }]
            },
            {
              "identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-27-0", "version": "27.0", "isAvailable": true, "platform": "watchOS",
              "supportedDeviceTypes": [{ "name": "iPhone 17", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17" }]
            }
          ]
        }
        """
    }

    /// What `simctl list devices -j` prints: two of this run's devices and one stock device, each with its name beside its udid.
    static var listing: String {
        """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
              { "udid": "\(firstUdid)", "name": "sift-a1b2c3-0f9e8d7c-0", "state": "Booted", "isAvailable": true },
              { "udid": "\(secondUdid)", "name": "sift-a1b2c3-0f9e8d7c-1", "state": "Shutdown", "isAvailable": true },
              { "udid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "name": "iPhone 17", "state": "Shutdown", "isAvailable": true }
            ]
          }
        }
        """
    }
}
