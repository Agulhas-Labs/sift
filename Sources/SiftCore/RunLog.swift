//
// Copyright © Agulhas Labs
//

import Foundation

/// The raw transcript of a wrapped run, written as it arrives.
///
/// This is what makes the filtering safe to be lossy: whatever the filter dropped is still on disk one path away, and the bytes are streamed straight through rather than held in memory, because an `xcodebuild` log can run to tens of megabytes.
///
/// **One file per run, never one file per repository.** A single fixed path would make the receipt a lie the moment two sessions build the same repo at once — the slow run's answer would name a path holding the fast run's bytes, and the fail-open branch would print another run's transcript under "raw output follows". Parallel sessions in one repo are the assumed norm here, not an edge case, so the name carries the run's own start time and a token that separates two starting in the same second.
///
/// **A run in flight is written to `….log.part` and published by a rename at ``close()``.** Pruning at open time reads a directory, and a long run is by construction the *oldest* file in it — so without this, five quick runs completing during one `xcodebuild test` would unlink its transcript while this handle went on appending to the orphaned inode, and the fail-open path would then have nothing to serve under a message blaming a write that had never failed. The `.part` extension is what makes "never prune a live run" structural rather than a matter of timing: pruning matches `.log` only, and a file only becomes one when its run is over. No lock is taken and none is needed — the rule holds across processes because it is a property of the name.
public final class RunLog {
    /// Where the transcript stands once the run is over — the path a receipt names, and the one a reader is pointed at.
    ///
    /// It moves once at most, when ``keep(in:)`` takes the finished transcript out of the pruned count, which happens before any answer names it.
    public private(set) var url: URL
    /// Where it is written meanwhile, out of reach of every other run's pruning.
    let partURL: URL
    private let handle: FileHandle

    private init(url: URL, partURL: URL, handle: FileHandle) {
        self.url = url
        self.partURL = partURL
        self.handle = handle
    }
}

public extension RunLog {
    /// The subdirectory the transcripts live in, so pruning can only ever remove a file this type wrote.
    static var runsDirectoryName: String {
        "runs"
    }

    private static var filePrefix: String {
        "run-"
    }

    /// The prefix in the temporary directory, where this type's files sit among every other program's.
    private static var temporaryPrefix: String {
        "sift-\(filePrefix)"
    }

    private static var fileSuffix: String {
        ".log"
    }

    /// What a transcript is called while its run is still writing it — see the type's note on why it is a different name rather than a flag.
    private static var partSuffix: String {
        "\(fileSuffix).part"
    }

    /// How many transcripts are kept in a repository before the oldest are dropped.
    ///
    /// A run log is the receipt for one answer, and an answer is read within minutes of being produced — so the number only has to cover the sessions plausibly building one repository at once, not a history. Five does that and bounds the disk an `xcodebuild` transcript's tens of megabytes could otherwise take forever.
    static let keptLogs = 5

    /// How long an unfinished transcript is left alone before it is read as abandoned.
    ///
    /// A `.part` file is never pruned by count, so a run killed between opening its log and closing it — a crash, a `SIGKILL`, a harness timeout — would otherwise pin its bytes forever, and a repo built all day would accumulate one orphan per death. A day is deliberately far longer than any real run: the longest thing this wraps is a cold `xcodebuild test` on a monorepo, measured in tens of minutes, so nothing live is ever within an order of magnitude of the cutoff. A `.part` whose creation date the filesystem will not give up is left alone rather than guessed at — the opposite of the choice ``created(_:)`` makes for a completed log, because here an unreadable age would mean deleting a transcript that may still be being written.
    static let abandonedPartAge: TimeInterval = 24 * 60 * 60

    /// Opens this run's own log under `directory`, falling back to a temporary file, and returns `nil` only when neither can be written.
    ///
    /// A log that cannot be opened never stops the run: the wrapped command is the point, and the receipt says so instead of pretending the file is there.
    ///
    /// `temporary` defaults to the process temporary directory and is a parameter only so the fallback can be exercised somewhere a test owns. Pruning it is the point of that exercise: the shared temporary directory is where nothing is ever looked at, so an unbounded branch there is an unbounded branch nobody notices.
    static func open(
        inDirectory directory: URL,
        fallingBackTo temporary: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    ) -> RunLog? {
        let runs = SiftPaths.cache(in: directory)
            .appendingPathComponent(runsDirectoryName, isDirectory: true)
        if let log = open(at: runs.appendingPathComponent(fileName(prefix: filePrefix)), creating: runs) {
            prune(in: runs, prefix: filePrefix)
            return log
        }
        // The fallback is bounded on the same terms as the directory it stands in for. Named per run, it
        // would otherwise be the one branch that accumulates a transcript forever.
        guard let log = open(at: temporary.appendingPathComponent(fileName(prefix: temporaryPrefix)), creating: nil) else {
            return nil
        }
        prune(in: temporary, prefix: temporaryPrefix)
        return log
    }

    /// This run's file name: sortable by when it started, unique against a run that started in the same second.
    ///
    /// The token is what makes the uniqueness real rather than probable — a second is a long time next to two shells launched by the same keystroke, and two runs inside one process share a pid.
    private static func fileName(prefix: String) -> String {
        "\(prefix)\(stamp.string(from: Date()))-\(String(format: "%08x", UInt32.random(in: 0 ... .max)))\(fileSuffix)"
    }

    /// Fixed-width, zero-padded and UTC, so a lexicographic sort of the names is a chronological one.
    ///
    /// The trailing `Z` says so in the name itself, so nobody reads `run-20260930-193451Z-…` as local time.
    ///
    /// POSIX locale and the Gregorian calendar are pinned for the reason `TranscriptAudit` pins them: a machine set to another calendar would otherwise name a file 2569 and sort every real one beneath it. UTC rather than local time because a clock going back an hour must not reorder the directory.
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss'Z'"
        return formatter
    }()

    /// Drops all but the newest ``keptLogs`` *completed* transcripts, matching only names this type wrote under `prefix`.
    ///
    /// Ordered by when each file was created rather than by its name: the name's stamp is whole seconds, which is legible but coarse enough that a repository built several times in one second would prune by the disambiguating token — that is, arbitrarily, and possibly dropping a transcript newer than one it kept. The name is the tiebreak for two files a filesystem timestamp cannot separate.
    ///
    /// A run still in flight is a `.part` and is invisible to the count — that is the whole point of the extension. Room is therefore *made* for the caller's own transcript rather than it being seen: the newest `keptLogs - 1` completed logs survive here, and the close that publishes this one makes the fifth. Counting it where it stands would leave six on disk in the steady state, which is a bound but not the one every doc states.
    ///
    /// What a `.part` is not invisible to is age: an orphan left by a run that died mid-write goes at ``abandonedPartAge``, so a crash costs one file for a day rather than forever.
    private static func prune(in directory: URL, prefix: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        let logs = names
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(fileSuffix) }
            .map { (name: $0, created: created(directory.appendingPathComponent($0))) }
            .sorted { ($0.created, $0.name) > ($1.created, $1.name) }
        for log in logs.dropFirst(keptLogs - 1) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(log.name))
        }
        dropAbandonedParts(in: directory, prefix: prefix, names: names)
    }

    /// Removes the `.part` files under `prefix` that no run can still be writing.
    private static func dropAbandonedParts(in directory: URL, prefix: String, names: [String]) {
        let cutoff = Date().addingTimeInterval(-abandonedPartAge)
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(partSuffix) {
            let part = directory.appendingPathComponent(name)
            guard let created = try? part.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  created < cutoff
            else {
                continue
            }
            try? FileManager.default.removeItem(at: part)
        }
    }

    /// When `url` was created, or the distant past when the filesystem will not say — an unreadable age sorts oldest, so a file nothing can date is the first to go rather than the last.
    private static func created(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    /// Moves the finished transcript at `path` out of reach of the count that prunes the others, and answers where it now stands, or `nil` where it could not be moved.
    ///
    /// For a transcript that has to outlive the next few runs to be read: one explaining a lost result, or a selected run that did not build. Each ``KeptPool`` is bounded on its own, at ``keptLogs``, so neither kind can push out the other.
    static func keep(_ path: String, in pool: KeptPool = .lostResult) -> String? {
        let source = URL(fileURLWithPath: path)
        let directory = source.deletingLastPathComponent()
        let name = source.lastPathComponent
        guard name.hasPrefix(filePrefix) || name.hasPrefix(temporaryPrefix), name.hasSuffix(fileSuffix) else {
            return nil
        }
        let prefix = pool.rawValue
        let kept = directory.appendingPathComponent(prefix + name)
        guard (try? FileManager.default.moveItem(at: source, to: kept)) != nil else {
            return nil
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let older = names
            .filter { ($0.hasPrefix(prefix + filePrefix) || $0.hasPrefix(prefix + temporaryPrefix)) && $0.hasSuffix(fileSuffix) }
            .map { (name: $0, created: created(directory.appendingPathComponent($0))) }
            .sorted { ($0.created, $0.name) > ($1.created, $1.name) }
            .dropFirst(keptLogs)
        for log in older {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(log.name))
        }
        return kept.path
    }

    /// Which count a kept transcript is bounded in, spelled as the prefix its name takes — one no pruning by ``filePrefix`` matches.
    ///
    /// Two pools, because an edit-compile loop keeps a transcript per run that did not build, and in one pool those would push out the transcript explaining a sharded run's lost result.
    enum KeptPool: String, Sendable {
        /// A transcript explaining a result a run lost — a shard's missing tests, a listing that could not confirm them.
        case lostResult = "kept-"
        /// The transcript of a selected test run that did not build, without which its summary is the only record of what failed.
        case didNotBuild = "unbuilt-"
    }

    /// Moves this finished transcript into `pool`, out of reach of the count that prunes, and points ``url`` at where it now stands; where it cannot be moved, ``url`` stays as it was.
    func keep(in pool: KeptPool) {
        if let kept = Self.keep(url.path, in: pool) {
            url = URL(fileURLWithPath: kept)
        }
    }

    /// Creates the in-flight `.part` beside where the finished transcript will stand.
    private static func open(at url: URL, creating parent: URL?) -> RunLog? {
        if let parent {
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let part = URL(fileURLWithPath: url.path + partSuffix.dropFirst(fileSuffix.count))
        guard FileManager.default.createFile(atPath: part.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: part)
        else {
            return nil
        }
        return RunLog(url: url, partURL: part, handle: handle)
    }

    func append(_ data: Data) {
        try? handle.write(contentsOf: data)
    }

    /// Closes the handle and publishes the transcript under the name the receipt names.
    ///
    /// The rename is the moment the file becomes prunable, and it happens after the last byte is written — which is the whole guarantee. It cannot collide: the name carries this run's own stamp and token, so nothing else is standing there.
    func close() {
        try? handle.close()
        try? FileManager.default.moveItem(at: partURL, to: url)
    }

    /// The whole transcript, for the fail-open path that serves raw output instead of a filtered answer.
    ///
    /// Falls back to the `.part` so a rename that did not happen — a read before ``close()``, a filesystem that refused the move — costs the caller nothing. The bytes are the point; which of the two names they are under is not.
    func contents() -> Data? {
        (try? Data(contentsOf: url)) ?? (try? Data(contentsOf: partURL))
    }
}
