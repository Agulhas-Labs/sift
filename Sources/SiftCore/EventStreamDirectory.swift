//
// Copyright © Agulhas Labs
//

import Foundation

/// A directory under `.sift/` that one run's `swift test` event streams are written into, read back from, and removed with once the run is done.
///
/// **Asked for only where this `swift test` offers the option.** It is read from the hidden help of the very `swift test` that will run — the same command, in the same directory, with the same environment — because the option was renamed between toolchains and one `swift test` does not know fails the run it is given to. `PATH`'s `swift` is not that command where the caller named another toolchain's.
struct EventStreamDirectory {
    /// The option this `swift test` spells the stream's path with.
    let option: String

    /// The directory the streams are written into, one run's alone.
    let directory: URL

    /// How old another run's directory must be before it is taken for one a killed run left behind: a day, far longer than any real run, which keeps a concurrent run's live directory out of range without asking whether its process is alive — the rule ``RunLog`` reclaims an unfinished transcript by.
    static let abandonedAge = RunLog.abandonedPartAge

    /// How long the probe for the option may take, in seconds: far longer than a help takes to print, short enough that a wedged one costs a run little.
    static let probeDeadline: TimeInterval = 5

    /// A fresh directory under `purpose` in `root`'s `.sift/`, or `nil` where `command` — the `swift test` that will run, up to and including `test` — offers no event-stream option when asked from `workingDirectory` with `environment`, or where the directory cannot be made.
    ///
    /// Every run's directory under `purpose` older than ``abandonedAge`` is removed first, whether or not this one is made: a run killed before its own removal ran leaves its streams behind, and nothing else would ever reclaim them.
    static func make(
        in root: URL,
        for purpose: String,
        asking command: [String] = ["swift", "test"],
        from workingDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        probeDeadline: TimeInterval = EventStreamDirectory.probeDeadline
    ) -> EventStreamDirectory? {
        let parent = SiftPaths.cache(in: root).appendingPathComponent(purpose, isDirectory: true)
        removeAbandoned(in: parent)
        guard let option = option(asking: command, from: workingDirectory, environment: environment, deadline: probeDeadline) else {
            return nil
        }
        let directory = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // A directory that cannot be made is a stream that cannot be written: `swift test` handed its path fails the run, so none is asked for.
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        return EventStreamDirectory(option: option, directory: directory)
    }

    /// The arguments that ask `swift test` to write its stream to the file named `name`.
    func arguments(writing name: String) -> [String] {
        [option, directory.appendingPathComponent(name).path]
    }

    /// The stream written to the file named `name`, or `nil` where it is missing or unreadable.
    func read(_ name: String) -> String? {
        try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    /// Removes the directory and every stream in it, and the directory above it where that is left empty.
    func remove() {
        try? FileManager.default.removeItem(at: directory)
        // `rmdir` removes only an empty directory, so a concurrent run's streams beside this one's are left alone.
        rmdir(directory.deletingLastPathComponent().path)
    }

    /// Removes every run's directory in `parent` — a directory named by a UUID, as ``make(in:for:asking:from:environment:)`` names them — created more than ``abandonedAge`` ago.
    private static func removeAbandoned(in parent: URL) {
        let cutoff = Date().addingTimeInterval(-abandonedAge)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .creationDateKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: Array(keys))) ?? []
        for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil {
            guard let values = try? entry.resourceValues(forKeys: keys), values.isDirectory == true, let created = values.creationDate, created < cutoff else {
                continue
            }
            // Best effort: two runs starting together may both reach one directory, and the second finds it gone.
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// The event-stream option `command` accepts, asked of its own hidden help, or `nil` where it names none, could not be asked, or did not answer within `deadline`.
    ///
    /// Bounded, because the run has not begun and nothing else would end a help that never returns: the probe is ended at the deadline and the run goes on as though the option were unavailable.
    private static func option(asking command: [String], from workingDirectory: URL?, environment: [String: String], deadline: TimeInterval) -> String? {
        guard let help = try? SimulatorAccessibility.spawn("/usr/bin/env", command + ["--help-hidden"], deadline: deadline, in: workingDirectory, environment: environment),
              help.succeeded
        else {
            return nil
        }
        return SuiteSpans.outputOption(inHelp: help.standardOutput)
    }
}
