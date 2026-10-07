//
// Copyright © Agulhas Labs
//

import CryptoKit
import Foundation
import SiftCore

/// Each transcript's counts from an earlier `report`, so a transcript that has not changed is not read again.
///
/// A sweep over a month of transcripts reads gigabytes at the speed of a JSON parse per line, and almost all of it is the same bytes the last report read. A stored scan stands in for a transcript only while all of these still hold: the file's path, size and modification date; the window, as far as it reached into the file; the time zone its days were dated in; and the build that scanned it, so a change to the scanner never reads a count the old one made.
///
/// The window is stored as the scan saw it. A window that opens at or before the earliest line it judged reports every line, exactly as no window does, so such a scan is stored without one and stands for every window that also opens before that line — which is every transcript wholly inside a sliding `30d`. Only a transcript that straddles the window's start is keyed by the start itself.
///
/// What a scan asked the disk (a file's size against the floor, whether an index could answer a name, the hook's suppression log) is held as it was answered when the transcript was first read.
///
/// The file holds counts and dates only: a transcript is named by a hash of its path, never the path, which spells out the project directory and the session.
public struct TranscriptTallyCache: Sendable {
    /// Raised when what an entry holds changes shape, beside the build identity that changes with every install.
    static let format = 2

    /// How long after its transcript was last written an entry is kept: three times the widest window a report is usually asked for (`30d`), so a window that wide never misses for want of an entry, and the file stays bounded while Claude Code keeps its transcripts.
    static let retention: TimeInterval = 90 * 86400

    /// How many windows one transcript keeps, newest stored last: `7d` and `30d` alternating in one day need two, and the day's own starts moving with the clock need room beside them.
    static let windowsKept = 4

    public let fileURL: URL
    let build: String

    /// `~/.sift/transcript-tallies.json`.
    public static var standardFileURL: URL {
        SiftPaths.home.appendingPathComponent("transcript-tallies.json")
    }

    /// A cache at `fileURL` for the binary running now, or `nil` where its identity cannot be read — a count stored by an unknown build could be any build's.
    public init?(fileURL: URL) {
        guard let identity = BinaryIdentity.capture(at: BinaryIdentity.executablePath) else { return nil }
        self.init(fileURL: fileURL, build: "\(identity.inode)-\(identity.mtime)")
    }

    init(fileURL: URL, build: String) {
        self.fileURL = fileURL
        self.build = build
    }

    /// The working copy one sweep reads and adds to, read from disk the first time it is asked for a scan; `now` is when the sweep ran, the date `retention` is counted back from.
    func open(timeZone: TimeZone, now: Date) -> Store {
        Store(fileURL: fileURL, header: Header(format: Self.format, build: build, timeZone: timeZone.identifier), now: now)
    }

    /// The name `path`'s transcript is stored under.
    static func key(of path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The window a scan was made under, as far as it reached into the transcript: `nil` where it opened at or before the earliest line judged.
    static func reach(of since: Date?, earliest: Double?) -> Double? {
        guard let start = since?.timeIntervalSince1970, let earliest, start > earliest else { return nil }
        return start
    }
}

extension TranscriptTallyCache {
    struct Header: Codable, Equatable {
        let format: Int
        let build: String
        let timeZone: String
    }

    /// One transcript's stored scans: the size and date they were read at, and one scan per window that reached into it differently.
    struct Entry: Codable, Equatable {
        let size: Int
        let modified: Double
        var windows: [Window]
    }

    /// One window's scan of a transcript: how far the window reached, and the counts `tallies` reads — none for a context that made no Swift lookup.
    struct Window: Codable, Equatable {
        let since: Double?
        let earliest: Double?
        var tally: TranscriptTally?
        var byDay: [String: TranscriptTally]?
    }

    struct Contents: Codable {
        let header: Header
        var transcripts: [String: Entry]
    }

    /// One sweep's view of the cache.
    ///
    /// A file that cannot be read or decoded, or was written by another build, format or time zone, holds nothing and is rewritten; nothing here is ever an error.
    final class Store {
        let fileURL: URL
        let header: Header
        let now: Date
        private var loaded: [String: Entry]?
        private var changed = false

        init(fileURL: URL, header: Header, now: Date) {
            self.fileURL = fileURL
            self.header = header
            self.now = now
        }

        private var entries: [String: Entry] {
            get {
                if let loaded {
                    return loaded
                }
                let read = (try? Data(contentsOf: fileURL))
                    .flatMap { try? JSONDecoder().decode(Contents.self, from: $0) }
                    .flatMap { $0.header == header ? $0.transcripts : nil }
                changed = read == nil
                loaded = read ?? [:]
                return loaded ?? [:]
            }
            set { loaded = newValue }
        }

        /// `blank`'s transcript as the cache stored it, where its key still matches the snapshot and the window; `nil` sends the caller to read it.
        func scan(of blank: TranscriptAudit.Scan, in snapshot: TranscriptSnapshot, since: Date?) -> TranscriptAudit.Scan? {
            let path = blank.transcript
            guard let size = snapshot.sizes[path], let modified = snapshot.modified[path],
                  let entry = entries[TranscriptTallyCache.key(of: path)], entry.size == size, entry.modified == modified.timeIntervalSince1970,
                  let window = entry.windows.first(where: { $0.since == TranscriptTallyCache.reach(of: since, earliest: $0.earliest) })
            else {
                return nil
            }
            var scan = blank
            scan.tally = window.tally ?? TranscriptTally()
            scan.byDay = window.byDay ?? [:]
            return scan
        }

        /// `blank`'s transcript as stored where that still holds, and otherwise what `read` returns, kept for the next sweep.
        func recalled(_ blank: TranscriptAudit.Scan, in snapshot: TranscriptSnapshot, since: Date?, reading read: () -> TranscriptAudit.Scan) -> TranscriptAudit.Scan {
            if let held = scan(of: blank, in: snapshot, since: since) {
                return held
            }
            let fresh = read()
            store(fresh, in: snapshot, since: since)
            return fresh
        }

        /// Keeps `scan` for the next sweep, where its transcript was read and its key is known, beside the other windows stored for the same bytes.
        func store(_ scan: TranscriptAudit.Scan, in snapshot: TranscriptSnapshot, since: Date?) {
            let path = scan.transcript
            guard scan.wasRead, let size = snapshot.sizes[path], let modified = snapshot.modified[path] else { return }
            let earliest = scan.earliestStamp?.timeIntervalSince1970
            let window = Window(
                since: TranscriptTallyCache.reach(of: since, earliest: earliest),
                earliest: earliest,
                tally: scan.contributed ? scan.tally : nil,
                byDay: scan.contributed ? scan.byDay : nil
            )
            let key = TranscriptTallyCache.key(of: path)
            var entry = Entry(size: size, modified: modified.timeIntervalSince1970, windows: [])
            if let held = entries[key], held.size == entry.size, held.modified == entry.modified {
                entry.windows = held.windows.filter { $0.since != window.since }
            }
            entry.windows = Array((entry.windows + [window]).suffix(TranscriptTallyCache.windowsKept))
            entries[key] = entry
            changed = true
        }

        /// Drops what no later sweep should read and writes the file whole, temporary file then rename, where anything changed: two reports at once leave one of their copies, never a mix.
        ///
        /// Two kinds of entry go. One the sweep's window covers whose transcript `snapshot` did not list: the snapshot lists every transcript last written inside the window, so it is gone. One whose transcript was last written before both `retention` and the window: a window that wide is the only one that could ask for it.
        func save(listing snapshot: TranscriptSnapshot, since: Date?) {
            // Read here where no scan read it, so a window that lists no transcript still prunes.
            guard loaded != nil || FileManager.default.fileExists(atPath: fileURL.path) else { return }
            var kept = entries
            let listed = Set(snapshot.sizes.keys.map(TranscriptTallyCache.key(of:)))
            let windowStart = since?.timeIntervalSince1970 ?? -.infinity
            let horizon = min(now.timeIntervalSince1970 - TranscriptTallyCache.retention, windowStart)
            for (key, entry) in kept where entry.modified < horizon || (entry.modified >= windowStart && !listed.contains(key)) {
                kept[key] = nil
                changed = true
            }
            guard changed, let data = try? JSONEncoder().encode(Contents(header: header, transcripts: kept)) else { return }
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
