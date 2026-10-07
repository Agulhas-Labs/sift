//
// Copyright © Agulhas Labs
//

import Foundation

/// Where runs' live progress files sit: one file per run, in one directory per repository.
public struct RunProgressPaths {
    /// The directory's name inside the repository's cache directory, beside the run logs.
    public static var directoryName: String {
        "progress"
    }

    /// What every run file's name starts with; a temporary never does, so a lister matching it sees only whole files.
    public static var filePrefix: String {
        "run-"
    }

    /// What every run file's name ends with.
    public static var fileSuffix: String {
        ".json"
    }

    /// `<repoRoot>/.sift/progress`, or the same under `writesUnder` where a test or probe scoped the run's writes there: the seam the run log and the ledger already take.
    public static func directory(in repoRoot: URL, writesUnder: URL?) -> URL {
        SiftPaths.cache(in: writesUnder ?? repoRoot).appendingPathComponent(directoryName, isDirectory: true)
    }

    /// `run-<runId>.json` in `directory`.
    public static func file(runId: String, in directory: URL) -> URL {
        directory.appendingPathComponent(filePrefix + runId + fileSuffix)
    }

    /// Whether `name` is a run file's name rather than a temporary or anything else in the directory.
    public static func isRunFile(_ name: String) -> Bool {
        name.hasPrefix(filePrefix) && name.hasSuffix(fileSuffix)
    }

    /// The runs in the repository at `repoRoot` that are live at `now`, read from its `.sift/progress/`, in no order.
    ///
    /// A missing directory, a file that vanished between the listing and the read, and one that is not a snapshot this version reads are no run. Nothing is written or removed.
    public static func liveRuns(inRepositoryAt repoRoot: URL, at now: Date = Date()) -> [RunProgressSnapshot] {
        let directory = Self.directory(in: repoRoot, writesUnder: nil)
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter(isRunFile)
            .compactMap { name in
                (try? Data(contentsOf: directory.appendingPathComponent(name)))
                    .flatMap { try? RunProgressSnapshot.decoded(from: $0) }
            }
            .filter { $0.isLive(at: now) }
    }
}
