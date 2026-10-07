//
// Copyright © Agulhas Labs
//

import Foundation

/// The record of one sharded run's simulators — `.sift/shards/<runid>/ledger.json` — written so that whichever of three actors is still alive can finish the cleanup.
///
/// **A device sift created is deleted by the udid sift recorded, by the owner, its watcher, or the next run's sweep.** That invariant is the whole reason this file exists on disk rather than in memory: the owner can be killed, and a machine can go down mid-run, and in both cases the devices are still there costing gigabytes apiece. So the ledger carries the owner's and the watcher's pid *with the moment each was started* — a pid alone is reused, and a stranger holding a dead run's pid would keep its devices alive forever — and per shard an **intent**, the device's name, written *before* `simctl create` is spawned, and then the udid the moment create prints it.
///
/// **Every change is an atomic rewrite**: a temporary file in the same directory, renamed into place. The rename is the commit point, so a run killed mid-write leaves the previous record rather than half of one, and half a record is a record the sweep would read as unreadable and act on.
public struct ShardLedger: Sendable {
    /// The repository whose `.sift/` holds the record.
    public let repositoryRoot: URL
    /// What is on disk, and what every mutation rewrites whole.
    private var file: File
    /// When the process holding a pid was started, injected so a test can decide who is alive without starting anything.
    private let started: @Sendable (Int32) -> UInt64?

    /// Opens a ledger for a new run and writes it, so a sweep can see the run before its first device exists.
    ///
    /// Writing at once rather than at the first intent is what keeps the create window safe for everybody else: a parallel session sweeping this checkout finds the run alive and leaves its devices alone.
    public init(
        repositoryRoot: URL,
        runID: String = ShardLedger.newRunID(),
        prefix: String,
        owner: Identity,
        started: @escaping @Sendable (Int32) -> UInt64? = { KernelProcess.startMicroseconds(of: $0) }
    ) throws {
        // An owner with no start time cannot be told from a dead one, so a parallel run's sweep would delete this run's
        // devices while it used them. Nothing exists yet, which makes refusing free.
        guard owner.startMicroseconds != 0 else {
            throw ShardError.ledger("the kernel gave no start time for this process (pid \(owner.pid)), so another run could not tell this one was alive — no simulator was created")
        }
        self.repositoryRoot = repositoryRoot
        self.started = started
        file = File(version: Self.currentVersion, runID: runID, prefix: prefix, owner: owner, watcher: nil, shards: [])
        try write()
    }

    /// Rebuilds a ledger from what was read off disk.
    private init(repositoryRoot: URL, file: File, started: @escaping @Sendable (Int32) -> UInt64?) {
        self.repositoryRoot = repositoryRoot
        self.file = file
        self.started = started
    }
}

public extension ShardLedger {
    /// A process as this record identifies it: the pid, and the moment that pid started.
    ///
    /// The start time is the whole of the identity. Pids are reused within hours on a busy machine, and a ledger that asked only "is pid 4711 running" would read a stranger's shell as its own dead owner and leave the devices for nobody.
    struct Identity: Codable, Equatable, Sendable {
        public let pid: Int32
        public let startMicroseconds: UInt64

        public init(pid: Int32, startMicroseconds: UInt64) {
            self.pid = pid
            self.startMicroseconds = startMicroseconds
        }

        /// This process, as the ledger records it.
        ///
        /// A kernel with no record of the caller's own pid cannot happen; were it to, the recorded `0` is what ``ShardLedger/init(repositoryRoot:runID:prefix:owner:started:)`` refuses, because a run that reads as dead is one a parallel sweep deletes the devices of.
        public static func current(started: (Int32) -> UInt64? = { KernelProcess.startMicroseconds(of: $0) }) -> Identity {
            let pid = getpid()
            return Identity(pid: pid, startMicroseconds: started(pid) ?? 0)
        }
    }

    /// One shard's device: the name, written before it is created, and the udid once `simctl` has printed one.
    struct Shard: Codable, Equatable, Sendable {
        public let index: Int
        public let name: String
        public var udid: String?

        public init(index: Int, name: String, udid: String? = nil) {
            self.index = index
            self.name = name
            self.udid = udid
        }
    }

    /// What was found where a run's ledger should be.
    ///
    /// **Unreadable is not the same as missing, and neither is alive.** A record this version cannot decode names no pid at all, so no process could be its owner — the sweep treats it as a dead run and deletes what the listing carries for it.
    enum Reading: Sendable {
        case ledger(ShardLedger)
        case unreadable
        case missing
    }

    /// The run this record belongs to.
    var runID: String {
        file.runID
    }

    /// The checkout prefix its device names carry.
    var prefix: String {
        file.prefix
    }

    /// The process that started the run.
    var owner: Identity {
        file.owner
    }

    /// The detached process watching the owner, once there is one.
    var watcher: Identity? {
        file.watcher
    }

    /// Every shard, in the order they were intended.
    var shards: [Shard] {
        file.shards
    }

    /// Every udid this run has recorded, in shard order.
    var udids: [String] {
        file.shards.compactMap(\.udid)
    }

    /// Whether anybody is still going to clean this run up on its own — its owner or its watcher still running, as the pid *and* the start time recorded for it.
    var isAlive: Bool {
        if let startMicroseconds = started(file.owner.pid), startMicroseconds == file.owner.startMicroseconds {
            return true
        }
        guard let watcher = file.watcher, let startMicroseconds = started(watcher.pid) else {
            return false
        }
        return startMicroseconds == watcher.startMicroseconds
    }

    /// `.sift/shards` — every run's record, and the result bundles beside them.
    static func directory(in repositoryRoot: URL) -> URL {
        SiftPaths.cache(in: repositoryRoot).appendingPathComponent(directoryName)
    }

    /// `.sift/shards/<runid>` — one run's directory.
    static func directory(in repositoryRoot: URL, runID: String) -> URL {
        directory(in: repositoryRoot).appendingPathComponent(runID)
    }

    /// This run's directory, which holds its record and its result bundles.
    var directory: URL {
        Self.directory(in: repositoryRoot, runID: runID)
    }

    /// This run's record.
    var fileURL: URL {
        directory.appendingPathComponent(Self.fileName)
    }

    /// Every run that has left a record under `.sift/shards`, whether or not it is still running.
    static func runIDs(in repositoryRoot: URL) -> [String] {
        let root = directory(in: repositoryRoot)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        return entries.filter { entry in
            FileManager.default.fileExists(atPath: root.appendingPathComponent(entry).appendingPathComponent(fileName).path)
        }.sorted()
    }

    /// What is on disk for one run.
    static func read(
        repositoryRoot: URL,
        runID: String,
        started: @escaping @Sendable (Int32) -> UInt64? = { KernelProcess.startMicroseconds(of: $0) }
    ) -> Reading {
        let url = directory(in: repositoryRoot, runID: runID).appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else {
            return .missing
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.version == currentVersion, file.runID == runID else {
            return .unreadable
        }
        return .ledger(ShardLedger(repositoryRoot: repositoryRoot, file: file, started: started))
    }

    /// The name shard `index` will be created under, recorded before anything is created.
    ///
    /// **This is the intent, and it is the whole of the cover for the create window.** `simctl create` can return a device and then this process can die before the udid is written — or print something nobody can read a udid out of — and in both cases the device exists under this name, which is the name the sweep finds it in the listing by.
    @discardableResult
    mutating func recordIntent(shard index: Int) throws -> String {
        let name = ShardDeviceName(prefix: prefix, runID: runID, index: index).text
        if let existing = file.shards.firstIndex(where: { $0.index == index }) {
            file.shards[existing] = Shard(index: index, name: name)
        } else {
            file.shards.append(Shard(index: index, name: name))
        }
        try write()
        return name
    }

    /// Records the udid `simctl` printed for shard `index`, the moment it printed it.
    mutating func record(udid: String, forShard index: Int) throws {
        guard let position = file.shards.firstIndex(where: { $0.index == index }) else {
            throw ShardError.ledger("shard \(index) has no recorded name in \(shownFileURL), so its udid cannot be recorded against one")
        }
        file.shards[position].udid = udid
        try write()
    }

    /// Drops a shard whose device is gone, so the record names only devices that still exist.
    ///
    /// **Only ever after a delete that succeeded.** A record that forgot a device still on the disk is the one state this feature cannot leave behind — so a failed delete keeps its entry, and the next cleanup and the sweep after that try it again.
    mutating func forget(shard index: Int) throws {
        file.shards.removeAll { $0.index == index }
        try write()
    }

    /// Records the detached process that will finish the cleanup if the owner cannot.
    mutating func recordWatcher(_ identity: Identity) throws {
        file.watcher = identity
        try write()
    }

    /// Removes the run's directory, its record and its result bundles with it.
    func remove() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        try FileManager.default.removeItem(at: directory)
    }

    /// Eight random lowercase hex characters, which is what makes one run's device names tell themselves from another's.
    static func newRunID() -> String {
        randomHexadecimal(count: ShardDeviceName.runIDLength)
    }

    /// Six random lowercase hex characters, minted once per checkout.
    static func newPrefix() -> String {
        randomHexadecimal(count: ShardDeviceName.prefixLength)
    }

    /// The six hex characters that name every device this checkout creates, minted on first use and kept in `.sift/device-prefix`.
    ///
    /// **A file that does not hold exactly six lowercase hex characters is re-minted rather than repaired.** The prefix is only ever compared against a device name, so a malformed one matches nothing and the cheapest correct answer is a new one — and writing it atomically is what keeps two sessions starting at once from reading half of each other's.
    static func devicePrefix(in repositoryRoot: URL, mint: () -> String = ShardLedger.newPrefix) throws -> String {
        let url = SiftPaths.cache(in: repositoryRoot).appendingPathComponent(prefixFileName)
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let prefix = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if ShardDeviceName.isHexadecimal(prefix, count: ShardDeviceName.prefixLength) {
                return prefix
            }
        }
        let prefix = mint()
        guard let data = prefix.data(using: .utf8) else {
            throw ShardError.ledger("could not encode the device prefix \(prefix)")
        }
        try replaceFile(at: url, with: data)
        return prefix
    }
}

extension ShardLedger {
    /// The directory under `.sift` that holds every run's record.
    static var directoryName: String {
        "shards"
    }

    /// One run's record inside its own directory.
    static var fileName: String {
        "ledger.json"
    }

    /// The file under `.sift` that holds this checkout's device-name prefix.
    static var prefixFileName: String {
        "device-prefix"
    }

    /// Bumped when the shape on disk changes; a record written in another version is unreadable, which is a dead run and so a swept one.
    static let currentVersion = 1

    /// What the record holds.
    struct File: Codable {
        let version: Int
        let runID: String
        let prefix: String
        var owner: Identity
        var watcher: Identity?
        var shards: [Shard]
    }

    /// The record as a person would name it, relative to the repository.
    var shownFileURL: String {
        "\(SiftPaths.directoryName)/\(Self.directoryName)/\(runID)/\(Self.fileName)"
    }

    /// `count` random lowercase hex characters.
    static func randomHexadecimal(count: Int) -> String {
        String((0 ..< count).map { _ in hexadecimalDigits.randomElement() ?? "0" })
    }

    static var hexadecimalDigits: [Character] {
        Array("0123456789abcdef")
    }

    /// Replaces the record with what the run now knows, all at once.
    private func write() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try Self.replaceFile(at: fileURL, with: encoder.encode(file))
    }

    /// Writes `data` to `url` as one indivisible step — a temporary file in the same directory, renamed into place.
    ///
    /// The rename must be within one directory: across file systems it is a copy, and a copy is exactly the half-written state this is here to rule out.
    static func replaceFile(at url: URL, with data: Data) throws {
        do {
            try DurableFile.replace(url, with: data, fsync: false, createDirectory: true)
        } catch let DurableFileError.rename(temporary, reason) {
            throw ShardError.ledger("could not move \(temporary) into place: \(reason)")
        } catch {
            throw ShardError.ledger("could not write \(url.lastPathComponent): \(error)")
        }
    }
}
