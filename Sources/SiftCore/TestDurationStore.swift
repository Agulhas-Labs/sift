//
// Copyright © Agulhas Labs
//

import Foundation

/// What each test in a repository has recently cost, kept in `.sift/test-durations.json` so a later run can plan around it.
///
/// **A test's duration is a distribution, not a number, so what is kept is the last few observations and what is answered is their median.** Whichever test runs first in a bundle is charged the bundle's load — the images, the fixtures, the first allocation of every lazily built thing — so that one observation is seconds where the others are milliseconds, and it moves from run to run as the order changes. A mean carries that wandering observation into every answer; a median of five leaves it where it belongs, as one reading of five.
///
/// **The rule for which timings may be kept at all lives here, not in the caller.** A caller that has just reconciled a run knows whether anything was retried or went missing, and that is exactly the knowledge that decides whether its numbers mean anything: a test timed while something else in the run was failing is timing a retry, a rebuild and a machine under a debugger, and one such run silently poisons the median that a later run plans from. Putting the rule in the store means every caller obeys it, including the one written next year.
public struct TestDurationStore: Sendable {
    /// The repository the timings belong to — one file per repository, since a test's cost is a fact about this checkout's machine and suite.
    public let repositoryRoot: URL
    /// What each test has recently cost, newest last.
    private var tests: [String: [Observation]]
    /// Injected so a test can age observations past the cut-off without waiting ninety days for it.
    private let now: @Sendable () -> Date
    /// How this store names itself in the one note a failed write gets, following `JSONLineLog`: a timing that could not be saved costs the next run a plan, never its result.
    private let note: @Sendable (String) -> Void

    /// Opens the store, reading whatever is on disk.
    ///
    /// A file that is missing, unreadable or written in a format this binary does not know opens as an empty store rather than an error: these are timings, and a run that cannot read its last five is a run that plans from none, not a run that fails.
    public init(repositoryRoot: URL, now: @escaping @Sendable () -> Date = Date.init, note: @escaping @Sendable (String) -> Void = { _ in }) {
        self.repositoryRoot = repositoryRoot
        self.now = now
        self.note = note
        tests = Self.read(Self.fileURL(in: repositoryRoot), note: note)
    }
}

public extension TestDurationStore {
    /// One recorded cost: what the test took, and when it was seen.
    struct Observation: Sendable, Equatable, Codable {
        public var seconds: Double
        public var date: Date

        public init(seconds: Double, date: Date) {
            self.seconds = seconds
            self.date = date
        }
    }

    /// One test's cost in a run that has just finished.
    struct Timing: Sendable, Equatable {
        public var identifier: String
        public var seconds: Double
        /// Which run through the tests this cost was measured on, counting from 1; only the first is a timing of the test rather than of a retry.
        public var iteration: Int

        public init(identifier: String, seconds: Double, iteration: Int = 1) {
            self.identifier = identifier
            self.seconds = seconds
            self.iteration = iteration
        }
    }

    /// Everything one finished run offers the store, with the two facts that decide whether any of it may be kept.
    struct Recording: Sendable, Equatable {
        public var observations: [Timing]
        /// Whether the run retried anything at all.
        ///
        /// A retry means at least one test ran on a machine that had already run the suite once, and the run's other timings were taken beside it.
        public var retried: Bool
        /// How many tests the run was expected to report on and did not — a crash, a timeout, a bundle that never launched.
        public var missing: Int

        public init(observations: [Timing], retried: Bool = false, missing: Int = 0) {
            self.observations = observations
            self.retried = retried
            self.missing = missing
        }
    }
}

public extension TestDurationStore {
    /// `.sift/test-durations.json` — beside the index and the run logs, because it is the same kind of thing: derived, per-repository, and safe to delete.
    static func fileURL(in repositoryRoot: URL) -> URL {
        SiftPaths.cache(in: repositoryRoot).appendingPathComponent(fileName)
    }

    var fileURL: URL {
        Self.fileURL(in: repositoryRoot)
    }

    /// What this test usually costs, over the observations kept for it, or `nil` where it has none.
    ///
    /// An even number of observations is answered with the mean of the middle two, which is the ordinary definition and keeps the answer between the two readings either side of it rather than picking one of them by position.
    func median(for identifier: String) -> Double? {
        let seconds = (tests[identifier] ?? []).map(\.seconds).sorted()
        guard !seconds.isEmpty else {
            return nil
        }
        let middle = seconds.count / 2
        return seconds.count.isMultiple(of: 2) ? (seconds[middle - 1] + seconds[middle]) / 2 : seconds[middle]
    }

    /// The observations kept for one test, oldest first — empty for a test this store has never seen.
    func observations(for identifier: String) -> [Observation] {
        tests[identifier] ?? []
    }

    /// Keeps what this run measured, if this run measured anything worth keeping, and writes the file.
    ///
    /// **A run that retried anything, or lost anything, is discarded whole** — not narrowed to its healthy-looking tests. A retry is a second pass over a machine the suite has already warmed, and a missing test is a run that ended in a way nobody planned; the tests that appear to have finished normally beside either one were timed in that same run, and there is no way to tell from the outside which of them the trouble touched. Within a kept recording, only the first iteration of each test is a timing of the test itself.
    mutating func record(_ recording: Recording) {
        guard !recording.retried, recording.missing == 0 else {
            return
        }
        let timings = recording.observations.filter { $0.iteration == 1 }
        guard !timings.isEmpty else {
            return
        }
        let seenAt = now()
        for timing in timings {
            var kept = tests[timing.identifier] ?? []
            kept.append(Observation(seconds: timing.seconds, date: seenAt))
            tests[timing.identifier] = Array(kept.suffix(Self.keptObservations))
        }
        forget(before: seenAt.addingTimeInterval(-Self.retention))
        write()
    }
}

extension TestDurationStore {
    static var fileName: String {
        "test-durations.json"
    }

    /// Five: enough that the bundle-load observation is outvoted, few enough that a suite's timings follow it as it changes rather than averaging in what it used to cost.
    static let keptObservations = 5
    /// Ninety days, after which a test nobody has run is forgotten.
    ///
    /// A test unseen for a season has been renamed, deleted or moved to another bundle far more often than it is one that is about to run again, and its entry would otherwise sit in the file forever.
    static let retention: TimeInterval = 90 * 24 * 60 * 60
    /// Bumped when the shape on disk changes; a file written in another version is read as no file at all, which is the whole migration story a derived cache needs.
    static let currentVersion = 1

    /// The file's shape, versioned so an older or newer binary's file is recognised as unreadable rather than half-decoded.
    struct File: Codable {
        var version: Int
        var tests: [String: [Observation]]
    }

    /// Drops every test whose newest observation is older than `cutoff`.
    ///
    /// A *test* is dropped, never an observation of a test still in use: five observations are what a median is taken over, and thinning them by age would narrow a live test's answer to its last few runs for no reason other than the calendar.
    private mutating func forget(before cutoff: Date) {
        tests = tests.filter { _, observations in
            observations.contains { $0.date >= cutoff }
        }
    }

    /// Replaces the file with the store's current contents, all at once: a temporary file in the same directory, renamed into place.
    ///
    /// The rename is the commit point, so a run interrupted mid-write leaves the previous timings rather than half a file — and it must be the *same* directory, since a rename across file systems is not atomic and a temporary directory is often another file system.
    private func write() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(File(version: Self.currentVersion, tests: tests))
            try DurableFile.replace(fileURL, with: data, fsync: false, createDirectory: true)
        } catch let DurableFileError.rename(temporary, reason) {
            note("test durations: could not move \(temporary) into place: \(reason)")
        } catch {
            note("test durations: could not write \(Self.fileName): \(error)")
        }
    }

    /// What the file holds, and nothing at all where there is no file, it cannot be read, or it was written in another version.
    private static func read(_ url: URL, note: @Sendable (String) -> Void) -> [String: [Observation]] {
        guard let data = try? Data(contentsOf: url) else {
            return [:]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data), file.version == currentVersion else {
            note("test durations: \(fileName) could not be read, starting from none")
            return [:]
        }
        return file.tests
    }
}
