//
// Copyright © Agulhas Labs
//

import Foundation

/// Every simulator a sharded run touches, and the one seam all of it goes through.
///
/// **The seam is ``SimulatorAccessibility/spawn(_:_:deadline:)``, and it is the seam because it is bounded on every path out** — a `simctl` that hangs is ended, and what comes back says it timed out rather than nothing at all. So a test injects a runner and no test here has ever created, booted or deleted a device.
///
/// **Only the operations that legitimately take minutes carry their own deadline.** Listing and resolving are questions `simctl` answers off a plist, and the five seconds the live runner gives them by default is generous; creating, booting and deleting are the ones that reach CoreSimulator, and each names how long it is prepared to wait.
///
/// **Nothing here deletes by name.** The name finds a device in `simctl`'s own listing; what is handed to `simctl delete` is always the udid the listing or the ledger carried beside it.
public struct ShardDevices: Sendable {
    private init() {}
}

public extension ShardDevices {
    /// How every `simctl` call here is spawned — the executable and its arguments, exactly as ``SimulatorAccessibility`` spells the same seam.
    typealias Run = (String, [String]) throws -> SimulatorAccessibility.Output

    /// What one build and every one of its devices is made for: the device type `simctl` knows by that name, and the runtime it will be created on.
    struct Resolution: Equatable, Sendable {
        /// The device type identifier, as `simctl create` takes it.
        public let deviceType: String
        /// The runtime identifier, as `simctl create` takes it.
        public let runtime: String
        /// That runtime's version, which is what an answer and a `-destination` spell.
        public let osVersion: String

        public init(deviceType: String, runtime: String, osVersion: String) {
            self.deviceType = deviceType
            self.runtime = runtime
            self.osVersion = osVersion
        }
    }

    /// A device as `simctl`'s own listing gives it: the name beside the udid, which is the pairing the sweep is built on.
    struct Device: Equatable, Sendable {
        public let udid: String
        public let name: String

        public init(udid: String, name: String) {
            self.udid = udid
            self.name = name
        }
    }

    /// What became of one device the tool tried to delete.
    ///
    /// **A device `simctl` says does not exist counts as deleted, and the answer says so** — gone is what was wanted, and a run that reported it as a failure would send somebody to delete a device that is not there.
    struct Deletion: Equatable, Sendable {
        public let udid: String
        /// Why the device is still there, or `nil` where it is gone.
        public let failure: String?
        /// Whether `simctl` said there was no such device — it was gone before this ran.
        public let wasAlreadyGone: Bool

        public init(udid: String, failure: String? = nil, wasAlreadyGone: Bool = false) {
            self.udid = udid
            self.failure = failure
            self.wasAlreadyGone = wasAlreadyGone
        }
    }

    /// What a run's cleanup did, as the answer's devices line says it.
    struct Cleanup: Equatable, Sendable {
        /// How many devices the run got a udid for.
        public let created: Int
        public let deletions: [Deletion]

        public init(created: Int, deletions: [Deletion]) {
            self.created = created
            self.deletions = deletions
        }
    }

    /// How long a `simctl create` may take before it is ended and reported as timed out.
    static var createDeadline: TimeInterval {
        60
    }

    /// How long a boot and the `bootstatus -b` behind it may take together, in seconds of wall clock each.
    ///
    /// Three minutes: a first boot of a freshly installed runtime does the data-container work every later boot is spared.
    static var bootDeadline: TimeInterval {
        180
    }

    /// How long a shutdown or a delete may take, in seconds of wall clock each.
    static var deleteDeadline: TimeInterval {
        60
    }

    /// How long the operation this `simctl` argv names may take, for a caller that spawns every one of them through one seam.
    ///
    /// The bounds above are per operation, and a run injects a single way of spawning `simctl` so that a test can answer them all from memory — which is exactly where the three of them collapse into whatever that one seam chose, and a three-minute boot is ended after the five seconds a listing gets. Reading the operation out of the argv is what keeps the judgement in one place: the alternative is each of five call sites naming its own bound, five spellings of one rule with nothing holding them together.
    static func deadline(of arguments: [String]) -> TimeInterval {
        switch arguments.dropFirst().first {
        case "create":
            createDeadline
        case "boot", "bootstatus":
            bootDeadline
        case "shutdown", "delete":
            deleteDeadline
        default:
            SimulatorAccessibility.spawnDeadline
        }
    }

    /// The device type `simctl` knows by that exact name, and the runtime this run's devices will be created on.
    ///
    /// **With no version named, the newest installed available iOS runtime that supports the device type** — the newest rather than any, because a different simulator OS invalidates every asset catalog and a run that drifted between them would rebuild the world. A version that is named is matched component by component, so `26` accepts `26.0`.
    static func resolve(
        deviceTypeName: String,
        osVersion: String? = nil,
        run: Run = { try SimulatorAccessibility.spawn($0, $1) }
    ) throws -> Resolution {
        let listing = try run(SimulatorAccessibility.xcrunPath, ["simctl", "list", "-j", "devicetypes", "runtimes"])
        guard listing.succeeded, let catalogue = try? JSONDecoder().decode(Catalogue.self, from: Data(listing.standardOutput.utf8)) else {
            throw ShardError.devices("could not read the simulator device types and runtimes: \(detail(of: listing))")
        }
        guard let deviceType = catalogue.devicetypes.first(where: { $0.name == deviceTypeName }) else {
            throw ShardError.devices("no simulator device type is named \(deviceTypeName) — simctl spells them: \(catalogue.devicetypes.map(\.name).sorted().joined(separator: ", "))")
        }
        let supporting = catalogue.runtimes.filter { runtime in
            runtime.isAvailable && runtime.platform == iOSPlatform && runtime.supportedDeviceTypes.contains { $0.identifier == deviceType.identifier }
        }
        guard !supporting.isEmpty else {
            throw ShardError.devices("no installed iOS runtime runs \(deviceTypeName) — installed and available: \(installed(catalogue.runtimes))")
        }
        let candidates = osVersion.map { asked in supporting.filter { SimulatorDestination.matches(asked, $0.version) } } ?? supporting
        guard let runtime = candidates.max(by: { isOlder($0.version, $1.version) }) else {
            throw ShardError.devices("no installed iOS runtime runs \(deviceTypeName) on \(osVersion ?? "") — it runs on: \(supporting.map(\.version).sorted().joined(separator: ", "))")
        }
        return Resolution(deviceType: deviceType.identifier, runtime: runtime.identifier, osVersion: runtime.version)
    }

    /// Creates shard `index`'s device and returns its udid, recording the intent before anything is created and the udid the moment `simctl` prints one.
    ///
    /// **The intent goes in first, and that ordering is the whole of the cover for the create window.** Between the spawn and the udid reaching the ledger this process can die, and `simctl` can answer with something no udid can be read out of — and in both cases a device exists under the recorded name, which is what the sweep finds it in the listing by.
    ///
    /// **Anything that is not shaped like a udid is an error and records nothing**, because a udid is what every delete is made by: half a line of output written into the ledger as one would be a delete aimed at no device, reported as a success.
    @discardableResult
    static func create(
        shard index: Int,
        in ledger: inout ShardLedger,
        resolution: Resolution,
        run: Run = { try SimulatorAccessibility.spawn($0, $1, deadline: ShardDevices.createDeadline) }
    ) throws -> String {
        let name = try ledger.recordIntent(shard: index)
        let created = try run(SimulatorAccessibility.xcrunPath, ["simctl", "create", name, resolution.deviceType, resolution.runtime])
        guard created.succeeded else {
            throw ShardError.devices("could not create the simulator \(name): \(detail(of: created))")
        }
        let udid = created.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SimulatorDestination.isSimulatorIdentifier(udid) else {
            throw ShardError.devices("creating the simulator \(name) printed \(detail(of: created)) where a udid was expected, so no udid was recorded for it — a device of that name is deleted by the next run's sweep")
        }
        try ledger.record(udid: udid, forShard: index)
        return udid
    }

    /// Boots a device, waits for the boot to have finished, and arms the accessibility preference the run's tests read.
    ///
    /// A device already booted is a booted device: `simctl` refuses the second boot, and refusing it is not a failure of this call.
    ///
    /// **Arming accessibility is best effort.** It is a convenience for what runs afterwards rather than a property of the device, and a run that refused to start over it would be refusing for the wrong reason.
    static func boot(
        udid: String,
        run: Run = { try SimulatorAccessibility.spawn($0, $1, deadline: ShardDevices.bootDeadline) }
    ) throws {
        let booted = try run(SimulatorAccessibility.xcrunPath, ["simctl", "boot", udid])
        if !booted.succeeded, !saysAlreadyBooted(booted) {
            throw ShardError.devices("could not boot the simulator \(udid): \(detail(of: booted))")
        }
        let status = try run(SimulatorAccessibility.xcrunPath, ["simctl", "bootstatus", udid, "-b"])
        guard status.succeeded else {
            throw ShardError.devices("the simulator \(udid) did not finish booting: \(detail(of: status))")
        }
        for arguments in SimulatorAccessibility.enableArguments(udid: udid) {
            _ = try? run(SimulatorAccessibility.xcrunPath, arguments)
        }
    }

    /// Shuts a device down and deletes it, and says which of the two ways that went.
    ///
    /// **This never throws.** Every device the run created owes an answer, and one that could not be deleted owes the loudest of them — so a failure is a value carrying the command a person runs by hand, and the devices after it in the list are still tried.
    ///
    /// The shutdown's own failure is ignored: a device already shut down refuses it, and so does a device that is already gone.
    static func delete(
        udid: String,
        run: Run = { try SimulatorAccessibility.spawn($0, $1, deadline: ShardDevices.deleteDeadline) }
    ) -> Deletion {
        _ = try? run(SimulatorAccessibility.xcrunPath, ["simctl", "shutdown", udid])
        do {
            let deleted = try run(SimulatorAccessibility.xcrunPath, ["simctl", "delete", udid])
            if deleted.succeeded {
                return Deletion(udid: udid)
            }
            guard !saysNoSuchDevice(deleted) else {
                return Deletion(udid: udid, wasAlreadyGone: true)
            }
            return Deletion(udid: udid, failure: detail(of: deleted))
        } catch {
            return Deletion(udid: udid, failure: "\(error)")
        }
    }

    /// Deletes every device this run recorded a udid for.
    ///
    /// **The record survives a failure.** When everything went, the run's directory goes with it; when anything is still there, the ledger stays exactly where it was so the next run's sweep retries it — a record removed over a device that is still on the disk is the one state this feature cannot leave behind.
    static func deleteAll(
        in ledger: ShardLedger,
        run: Run = { try SimulatorAccessibility.spawn($0, $1, deadline: ShardDevices.deleteDeadline) }
    ) -> Cleanup {
        let udids = ledger.udids
        let deletions = udids.map { delete(udid: $0, run: run) }
        if deletions.allSatisfy({ $0.failure == nil }) {
            try? ledger.remove()
        }
        return Cleanup(created: udids.count, deletions: deletions)
    }

    /// Every device `simctl` currently lists, with the name beside the udid — and nothing at all where the listing could not be read.
    ///
    /// Unavailable devices included: a runtime somebody deleted leaves its devices behind, and those are exactly the ones nothing else is going to clean up.
    static func listed(run: Run = { try SimulatorAccessibility.spawn($0, $1) }) -> [Device] {
        guard let listing = try? run(SimulatorAccessibility.xcrunPath, ["simctl", "list", "devices", "-j"]), listing.succeeded else {
            return []
        }
        guard let decoded = try? JSONDecoder().decode(DeviceListing.self, from: Data(listing.standardOutput.utf8)) else {
            return []
        }
        return decoded.devices.values.flatMap(\.self).map { Device(udid: $0.udid, name: $0.name) }.sorted { $0.udid < $1.udid }
    }
}

public extension ShardDevices.Deletion {
    /// The commands a person runs to finish what a failed delete could not.
    var command: String {
        "\(SimulatorAccessibility.xcrunName) simctl shutdown \(udid); \(SimulatorAccessibility.xcrunName) simctl delete \(udid)"
    }
}

public extension ShardDevices.Cleanup {
    /// The devices this run could not delete, which are the ones somebody has to.
    var failures: [ShardDevices.Deletion] {
        deletions.filter { $0.failure != nil }
    }

    /// The one line the answer carries about the run's devices, or nothing where the run created none.
    ///
    /// `3 simulators created, 3 deleted` is the whole of it when it went well, and a device left behind is named with the command to remove it rather than counted.
    var summary: String? {
        guard created > 0 else {
            return nil
        }
        let gone = deletions.filter { $0.failure == nil }
        var text = "\(created) \(created == 1 ? "simulator" : "simulators") created, \(gone.count) deleted"
        let alreadyGone = gone.filter(\.wasAlreadyGone).count
        if alreadyGone > 0 {
            text += " (\(alreadyGone) \(alreadyGone == 1 ? "was" : "were") already gone)"
        }
        let left = failures
        guard !left.isEmpty else {
            return text
        }
        return text + " — \(left.count) left: \(left.map(\.udid).joined(separator: ", ")) — run: \(left.map(\.command).joined(separator: "; ")) — \(ShardSweep.retryHint)"
    }
}

extension ShardDevices {
    /// What a spawned `simctl` said, preferring the stream that says which failure it was.
    static func detail(of output: SimulatorAccessibility.Output) -> String {
        let errors = output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        guard errors.isEmpty else {
            return errors
        }
        let printed = output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return printed.isEmpty ? "it printed nothing" : printed
    }

    /// Whether `simctl` is saying the device is not there — which, for a delete, is what was wanted.
    static func saysNoSuchDevice(_ output: SimulatorAccessibility.Output) -> Bool {
        let said = "\(output.standardError) \(output.standardOutput)".lowercased()
        return ["invalid device", "unable to find a device", "no such device", "device not found"].contains { said.contains($0) }
    }

    /// Whether `simctl` is refusing a boot because the device is booted already.
    static func saysAlreadyBooted(_ output: SimulatorAccessibility.Output) -> Bool {
        "\(output.standardError) \(output.standardOutput)".lowercased().contains("current state: booted")
    }

    /// Whether one version sorts before another, component by component as numbers — `26.10` after `26.9`, which a string comparison has backwards.
    static func isOlder(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let width = max(left.count, right.count)
        let padded = { (parts: [Int]) in parts + Array(repeating: 0, count: width - parts.count) }
        return padded(left).lexicographicallyPrecedes(padded(right))
    }

    /// The platform whose runtimes this command creates devices on.
    static var iOSPlatform: String {
        "iOS"
    }

    /// The iOS runtimes actually installed, as a refusal lists them.
    static func installed(_ runtimes: [Runtime]) -> String {
        let versions = runtimes.filter { $0.isAvailable && $0.platform == iOSPlatform }.map(\.version).sorted()
        return versions.isEmpty ? "none" : versions.joined(separator: ", ")
    }
}

extension ShardDevices {
    /// What `simctl list -j devicetypes runtimes` prints, down to what a resolution reads.
    struct Catalogue: Decodable {
        let devicetypes: [DeviceType]
        let runtimes: [Runtime]
    }

    /// A device type, both as the catalogue lists it and as a runtime names the ones it supports.
    struct DeviceType: Decodable {
        let name: String
        let identifier: String
    }

    struct Runtime: Decodable {
        let identifier: String
        let version: String
        let isAvailable: Bool
        let platform: String?
        let supportedDeviceTypes: [DeviceType]
    }

    /// What `simctl list devices -j` prints: devices under the runtime they sit on, each with the name beside the udid.
    struct DeviceListing: Decodable {
        let devices: [String: [Listed]]
    }

    struct Listed: Decodable {
        let udid: String
        let name: String
    }
}
