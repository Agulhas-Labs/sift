//
// Copyright © Agulhas Labs
//

import Foundation

/// Where a working tree's set-aside lives, and how its record is written and removed.
///
/// One per working tree, at a fixed place under the repository's own `.sift/`, because the set-aside is a fact about the tree rather than about whoever asked: any `sift run` started anywhere in it has to find the record, and two set-asides of one tree at once could only fight over the same files.
public struct SetAsideStore: Sendable {
    public let repositoryRoot: URL

    public init(repositoryRoot: URL) {
        self.repositoryRoot = repositoryRoot
    }
}

public extension SetAsideStore {
    /// `.sift/set-aside/` — the record and the copies it points at.
    var directory: URL {
        SiftPaths.cache(in: repositoryRoot).appendingPathComponent("set-aside", isDirectory: true)
    }

    var recordURL: URL {
        directory.appendingPathComponent("record.json")
    }

    /// `.sift/set-aside.lock` — held by the one process allowed to change the set-aside, for as long as it may.
    ///
    /// Beside the directory rather than in it, because the directory is removed once the tree is restored and a lock on a removed file excludes nobody.
    var lockURL: URL {
        SiftPaths.cache(in: repositoryRoot).appendingPathComponent("set-aside.lock")
    }

    /// `.sift/set-aside.watch` — held shared by every watcher for as long as it lives, so a refusal can tell a watcher about to put the tree back from one that is gone.
    ///
    /// A file of its own rather than the lock, because a watcher holds it the whole time its run holds the lock.
    var watchURL: URL {
        SiftPaths.cache(in: repositoryRoot).appendingPathComponent("set-aside.watch")
    }

    /// The directory as a caller would name it, relative to the repository.
    var shownDirectory: String {
        "\(SiftPaths.directoryName)/set-aside/"
    }

    internal var copies: URL {
        directory.appendingPathComponent("copies", isDirectory: true)
    }

    internal var blobs: URL {
        directory.appendingPathComponent("blobs", isDirectory: true)
    }

    /// HEAD's version of each path, under the path's own name, written here by `git checkout-index` — through the repository's own filters — before anything in the tree moves, so the set-aside can put it in place itself, one exclusive rename at a time.
    internal var heads: URL {
        directory.appendingPathComponent("heads", isDirectory: true)
    }

    /// The index `checkout-index` reads HEAD's entries from: the repository's own is the caller's, and stages their changes.
    internal var headsIndex: URL {
        directory.appendingPathComponent("heads.index")
    }

    /// The files the set-aside moved out of the tree, each checked against its copy the moment it arrived here.
    internal var moved: URL {
        directory.appendingPathComponent("moved", isDirectory: true)
    }

    /// Each file a restore puts back, built here in full — cloned, its bits and timestamp set — before it goes into the tree in one rename.
    ///
    /// In the store rather than beside the path, so a restore killed part-way leaves nothing in the tree under a name nobody chose, and a name too long to take a suffix is never given one.
    internal var staging: URL {
        directory.appendingPathComponent("staging", isDirectory: true)
    }

    /// Whatever a restore took out of the tree to put a path back — what a swap brought out, what stood at a path that goes back to being deleted — kept here until the sweep before the record goes has looked at every one, and moved beside its path anything that is not this tool's own.
    ///
    /// Named `<entry>-<n>`, so the sweep knows which path each came from.
    internal var displaced: URL {
        directory.appendingPathComponent("displaced", isDirectory: true)
    }

    /// Every session the run started a child in — its pid and when it was started — one per line, written before the child runs: what `run --restore` ends before it restores, when the run and its watcher are both gone.
    internal var sessionsURL: URL {
        directory.appendingPathComponent("sessions")
    }

    /// What this tool itself has left, or will leave, at each path — written before the tree is touched, and added to by every restore attempt — which is how a restore tells its own work from a change somebody made while the tests ran.
    ///
    /// Its absence is a fact too: it is written before the index or any file changes, so a record without it is a set-aside that never touched anything.
    internal var asideURL: URL {
        directory.appendingPathComponent("aside.json")
    }

    /// What `aside.json` holds, or `nil` when it was never written; one that exists and cannot be read throws, and is never taken for one that was never written — that reading would call a touched tree untouched.
    internal func ours() throws -> [String: [SetAsideFingerprint]]? {
        guard FileManager.default.fileExists(atPath: asideURL.path) else {
            return nil
        }
        do {
            return try JSONDecoder().decode([String: [SetAsideFingerprint]].self, from: Data(contentsOf: asideURL))
        } catch {
            throw SetAsideError.store("\(shownDirectory)aside.json could not be read (\(error))")
        }
    }

    /// The record on disk, or `nil` when there is none.
    ///
    /// A record that exists and cannot be read throws, and is never treated as absent: an unreadable record is still somebody's work, and reading it as "nothing to restore" would clear the way for the next run to overwrite the copies it points at.
    func record() throws -> SetAsideRecord? {
        guard FileManager.default.fileExists(atPath: recordURL.path) else {
            return nil
        }
        do {
            let record = try JSONDecoder().decode(SetAsideRecord.self, from: Data(contentsOf: recordURL))
            guard record.format == SetAsideRecord.currentFormat else {
                throw SetAsideError.unreadableRecord(path: shownDirectory + "record.json", reason: "it was written in format \(record.format), and this binary reads format \(SetAsideRecord.currentFormat)")
            }
            return record
        } catch let error as SetAsideError {
            throw error
        } catch {
            throw SetAsideError.unreadableRecord(path: shownDirectory + "record.json", reason: "\(error)")
        }
    }

    /// Writes `value` as JSON to `url`, durably and all at once: a temporary file, flushed to disk, renamed into place, and the directory flushed behind it.
    ///
    /// The record is the one file whose absence after a crash would lose work, so a half-written record is not an acceptable state: the rename is the commit point, and before it there is no record at all.
    internal func writeDurably(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        do {
            try DurableFile.replace(url, with: data, fsync: true, cleanUpOnFailure: false)
        } catch let DurableFileError.create(temporary) {
            throw SetAsideError.store("could not create \(temporary) in \(shownDirectory)")
        } catch let DurableFileError.rename(temporary, reason) {
            throw SetAsideError.store("could not move \(temporary) into place: \(reason)")
        }
    }

    /// Removes the record and then everything it pointed at.
    ///
    /// **The record goes first**, because it is the only file whose presence means "unrestored": a crash between the two steps leaves copies nobody points at, which the next set-aside clears, and never a record pointing at copies that are gone.
    internal func discard() throws {
        if FileManager.default.fileExists(atPath: recordURL.path) {
            try FileManager.default.removeItem(at: recordURL)
            DurableFile.synchronize(directory: directory)
        }
        try FileManager.default.removeItem(at: directory)
    }
}
