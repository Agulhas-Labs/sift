//
// Copyright © Agulhas Labs
//

import Foundation

/// The devices earlier runs of this checkout left behind, deleted by the next run that starts.
///
/// **This is the third and last actor that can delete a run's devices**, after the run itself and its watcher, and it is the only one that covers a reboot, a watcher that was killed, a record that never made it to disk, and the moment between `simctl create` returning a udid and the ledger recording it.
///
/// **The name only finds candidates; the deletion is always by udid.** A listed device is looked at only where ``ShardDeviceName/init(parsing:)`` reads its name whole *and* the prefix is this checkout's — so `sift-<prefix>-<runid>-0-copy`, `sift-<prefix>-<runid>-00` and another checkout's prefix are all somebody else's devices, and nothing here ever names one to `simctl delete`.
///
/// **A run that is still alive is left entirely alone**, including a device its ledger has not recorded yet: a parallel session in its own create window owns that device, and the run's own cleanup is the one that will take it.
public struct ShardSweep: Sendable {
    private init() {}
}

public extension ShardSweep {
    /// What one sweep deleted and what it could not, as the answer says both.
    struct Report: Equatable, Sendable {
        /// One line per dead run something was swept for, and one per device that is still there.
        public let sentences: [String]
        /// The devices a delete could not remove, which are the ones somebody has to remove by hand.
        public let failures: [ShardDevices.Deletion]
        /// Every device this sweep deleted, by name and udid, in the order it deleted them.
        public let deleted: [ShardDevices.Device]

        public init(sentences: [String], failures: [ShardDevices.Deletion], deleted: [ShardDevices.Device] = []) {
            self.sentences = sentences
            self.failures = failures
            self.deleted = deleted
        }
    }

    /// What a failed delete's line says after its manual command, since the record it keeps lets the sweep retry it once nothing is running.
    static var retryHint: String {
        "or `sift test --sweep` to retry"
    }

    /// Deletes, by udid, every device left by a run of this checkout that nobody is going to clean up any more.
    ///
    /// **A run is a candidate whether it left a record, a device, or both** — the ledgers under `.sift/shards` and the devices `simctl` lists are read together, because a reboot leaves a record whose devices nothing knows about and a lost record leaves devices whose run nothing knows about.
    ///
    /// **The record survives a failure.** A run's directory is removed only when every one of its devices went, so a device still on the disk keeps the record that names it and the next sweep tries again — a record removed over a device that is still there is the one state this feature cannot leave behind.
    ///
    /// `excluding` is the caller's own run, which is alive by definition and must not sweep itself before it has created anything.
    static func sweep(
        repositoryRoot: URL,
        prefix: String,
        excluding runID: String? = nil,
        run: ShardDevices.Run = { try SimulatorAccessibility.spawn($0, $1, deadline: ShardDevices.deleteDeadline) },
        started: @escaping @Sendable (Int32) -> UInt64? = { KernelProcess.startMicroseconds(of: $0) }
    ) -> Report {
        let listed = listedByRun(prefix: prefix, run: run)
        var sentences: [String] = []
        var failures: [ShardDevices.Deletion] = []
        var deleted: [ShardDevices.Device] = []
        for identifier in candidates(in: repositoryRoot, listed: listed, excluding: runID) {
            let reading = ShardLedger.read(repositoryRoot: repositoryRoot, runID: identifier, started: started)
            guard !isAlive(reading) else {
                continue
            }
            let devices = devices(of: reading, listed: listed[identifier] ?? [])
            let deletions = devices.map { ShardDevices.delete(udid: $0.udid, run: run) }
            deleted += zip(devices, deletions).filter { $1.failure == nil && !$1.wasAlreadyGone }.map(\.0)
            if deletions.allSatisfy({ $0.failure == nil }) {
                try? FileManager.default.removeItem(at: ShardLedger.directory(in: repositoryRoot, runID: identifier))
            }
            let swept = deletions.filter { $0.failure == nil && !$0.wasAlreadyGone }.count
            if swept > 0 {
                sentences.append("swept \(swept) \(swept == 1 ? "simulator" : "simulators") left by run \(identifier), which is no longer running")
            }
            for deletion in deletions {
                guard let failure = deletion.failure else {
                    continue
                }
                sentences.append("could not delete \(deletion.udid) left by run \(identifier): \(failure) — run: \(deletion.command) — \(retryHint)")
                failures.append(deletion)
            }
        }
        return Report(sentences: sentences, failures: failures, deleted: deleted)
    }
}

public extension ShardSweep.Report {
    /// The whole answer `sift test --sweep` prints: a verdict line, each device deleted by name and udid, and each one that could not be.
    var answer: String {
        let count = "\(deleted.count) \(deleted.count == 1 ? "simulator" : "simulators")"
        guard failures.isEmpty else {
            let lines = ["✘ sift test --sweep — deleted \(count), could not delete \(failures.count)"] + deviceLines + failureLines
            return lines.joined(separator: "\n")
        }
        guard !deleted.isEmpty else {
            return "✔ sift test --sweep — nothing to sweep: no ended run of this checkout left a simulator behind"
        }
        return (["✔ sift test --sweep — deleted \(count) left by runs of this checkout that are no longer running"] + deviceLines).joined(separator: "\n")
    }

    /// What `sift test --sweep` exits with: `1` where a device is still there, `0` otherwise.
    var exitCode: Int32 {
        failures.isEmpty ? 0 : 1
    }

    /// One indented line per device deleted, name first.
    private var deviceLines: [String] {
        deleted.map { "  deleted \($0.name) \($0.udid)" }
    }

    /// One indented line per device a delete could not remove, with the command that removes it by hand.
    private var failureLines: [String] {
        failures.map { "  could not delete \($0.udid): \($0.failure ?? "") — run: \($0.command) — \(ShardSweep.retryHint)" }
    }
}

extension ShardSweep {
    /// The listed devices this checkout's prefix strictly names, gathered under the run that created each one.
    ///
    /// A listing that could not be read is no devices at all, which still leaves every ledger's recorded udids to be swept by the record.
    static func listedByRun(prefix: String, run: ShardDevices.Run) -> [String: [ShardDevices.Device]] {
        var byRun: [String: [ShardDevices.Device]] = [:]
        for device in ShardDevices.listed(run: run) {
            guard let parsed = ShardDeviceName(parsing: device.name), parsed.prefix == prefix else {
                continue
            }
            byRun[parsed.runID, default: []].append(device)
        }
        return byRun
    }

    /// Every run this sweep will look at, in a stable order, which is every run that left a record or a device except the caller's own.
    static func candidates(in repositoryRoot: URL, listed: [String: [ShardDevices.Device]], excluding runID: String?) -> [String] {
        var identifiers = Set(ShardLedger.runIDs(in: repositoryRoot)).union(listed.keys)
        if let runID {
            identifiers.remove(runID)
        }
        return identifiers.sorted()
    }

    /// Whether somebody is still going to clean this run up on its own, which an unreadable or missing record never is.
    static func isAlive(_ reading: ShardLedger.Reading) -> Bool {
        guard case let .ledger(ledger) = reading else {
            return false
        }
        return ledger.isAlive
    }

    /// Every device a dead run owes, which is what it recorded together with what it created and never recorded.
    static func devices(of reading: ShardLedger.Reading, listed: [ShardDevices.Device]) -> [ShardDevices.Device] {
        guard case let .ledger(ledger) = reading else {
            return listed
        }
        let recorded = ledger.shards.compactMap { shard in shard.udid.map { ShardDevices.Device(udid: $0, name: shard.name) } }
        return recorded + listed.filter { device in !recorded.contains { $0.udid == device.udid } }
    }
}
