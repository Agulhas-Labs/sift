//
// Copyright © Agulhas Labs
//

import Foundation

/// The coverage an `xcodebuild test` run leaves in its result bundle, read from what `xccov view --archive` prints.
public struct ResultBundleCoverage: Sendable {
    private init() {}
}

public extension ResultBundleCoverage {
    /// Why no coverage may be read from `bundle` for a run, or `nil` where it was written by this run of the tree the caller has now.
    ///
    /// The bundle's `Info.plist` is written when `xcodebuild` finishes it and is not touched by later reads, which do rewrite the bundle's database, so its date is the one that says which run made the bundle.
    static func refusal(bundle: URL, treeBefore: TreeKey?, treeAfter: TreeKey?, runStarted: Date) -> String? {
        let info = bundle.appendingPathComponent("Info.plist")
        guard FileManager.default.fileExists(atPath: info.path) else {
            return "this run left no result bundle at \(bundle.path)"
        }
        let written = (try? info.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return CoverageAnswer.refusal(treeBefore: treeBefore, treeAfter: treeAfter, profileWritten: written, runStarted: runStarted)
    }

    /// The absolute paths of the files the bundle measured, from `xccov view --archive --file-list --json`.
    static func files(fromFileList data: Data) throws -> [String] {
        guard let files = try JSONSerialization.jsonObject(with: data) as? [String] else {
            throw CoverageObjectsRefusal(reason: "`xccov` listed the measured files in a shape this tool does not read")
        }
        return files
    }

    /// Each file's executable lines and how many times each ran, keyed by the path `xccov` names, from `xccov view --archive --file <path> --json`.
    ///
    /// A line `xccov` marks not executable is left out, as `llvm-cov` leaves out a line no region counts, so a declaration made of such lines reads as having no code to run.
    static func lineCounts(fromFile data: Data) throws -> [String: [Int: UInt64]] {
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]] else {
            throw CoverageObjectsRefusal(reason: "`xccov` printed a file's lines in a shape this tool does not read")
        }
        var counts: [String: [Int: UInt64]] = [:]
        for (path, lines) in document {
            var file: [Int: UInt64] = [:]
            for line in lines where line["isExecutable"] as? Bool == true {
                guard let number = line["line"] as? Int else { continue }
                file[number] = (line["executionCount"] as? NSNumber)?.uint64Value ?? 0
            }
            counts[path] = file
        }
        return counts
    }
}
