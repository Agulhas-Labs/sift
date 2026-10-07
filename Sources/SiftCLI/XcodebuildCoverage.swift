//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore

/// The coverage of a `sift run --coverage -- xcodebuild test` run, read from its result bundle with `xccov` for the changed files only.
struct XcodebuildCoverage {
    /// The identifier of this run, which names its own result bundle so two runs in one directory never share one.
    static let runID = String(ProcessInfo.processInfo.processIdentifier)

    /// Where a run that names no result bundle writes one, relative to the directory it runs in, inside the tool's own gitignored directory.
    static func ownResultBundle(run: String = runID) -> String {
        "\(SiftPaths.directoryName)/coverage-\(run).xcresult"
    }

    let bundle: URL
    let workingDirectory: URL
}

extension XcodebuildCoverage {
    /// `arguments` with coverage turned on and a result bundle named, where they do not already do either.
    static func enabling(_ arguments: [String], run: String = runID) -> [String] {
        var enabled = arguments
        if !arguments.contains("-enableCodeCoverage") {
            enabled += ["-enableCodeCoverage", "YES"]
        }
        if !arguments.contains("-resultBundlePath") {
            enabled += ["-resultBundlePath", ownResultBundle(run: run)]
        }
        return enabled
    }

    /// Refuses an `xcodebuild` line whose coverage cannot be tied to a build this run makes.
    static func validate(_ arguments: [String]) throws {
        if let flag = arguments.firstIndex(of: "-enableCodeCoverage"), arguments.dropFirst(flag + 1).first?.uppercased() != "YES" {
            throw ValidationError("sift run --coverage cannot measure a run that turns -enableCodeCoverage off.")
        }
        if arguments.contains("test-without-building") || arguments.contains("-xctestrun") {
            throw ValidationError("sift run --coverage refuses test-without-building and -xctestrun: coverage of binaries this run did not build cannot be tied to this tree.")
        }
        guard arguments.contains("test") else {
            throw ValidationError("sift run --coverage measures an `xcodebuild test` run, and this line has no test action.")
        }
        guard let path = arguments.firstIndex(of: "-resultBundlePath"), path + 1 < arguments.count else {
            throw ValidationError("sift run --coverage needs -resultBundlePath to name a path.")
        }
    }

    /// The result bundle `arguments` write, resolved against the directory the run starts in.
    static func bundlePath(of arguments: [String], in workingDirectory: URL) -> URL? {
        guard let flag = arguments.firstIndex(of: "-resultBundlePath"), let path = arguments.dropFirst(flag + 1).first else {
            return nil
        }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : workingDirectory.appendingPathComponent(path)
    }

    /// Whether `arguments` write the result bundle this run's own name gives, and so one this run may delete.
    static func writesOwnResultBundle(_ arguments: [String], run: String = runID) -> Bool {
        guard RunCommandKind.recognize(arguments) == .xcodebuild, let flag = arguments.firstIndex(of: "-resultBundlePath") else {
            return false
        }
        return arguments.dropFirst(flag + 1).first == ownResultBundle(run: run)
    }

    /// The names of bundles an earlier run of this tool left in its directory, past the window a record stands for, so none is one a live run still reads.
    static func abandonedBundles(among entries: [(name: String, modified: Date)], now: Date) -> [String] {
        entries.filter { entry in
            entry.name.range(of: #"^coverage-[0-9]+\.xcresult$"#, options: .regularExpression) != nil && now.timeIntervalSince(entry.modified) > RunLedger.trustWindow
        }.map(\.name)
    }

    /// Removes this run's own bundle where one is left over, which `xcodebuild` would refuse to write over, and the bundles earlier runs abandoned; a bundle the caller named is never touched.
    static func clearOwnResultBundle(for arguments: [String], in workingDirectory: URL, run: String = runID, now: Date = Date()) {
        guard writesOwnResultBundle(arguments, run: run) else {
            return
        }
        let directory = workingDirectory.appendingPathComponent(SiftPaths.directoryName)
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).map { name in
            (name: name, modified: (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.modificationDate] as? Date) ?? now)
        }
        for name in abandonedBundles(among: entries, now: now) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        try? FileManager.default.removeItem(at: workingDirectory.appendingPathComponent(ownResultBundle(run: run)))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The changed files' counts keyed by repository-relative path: a file `xccov` measured, or one it listed with no executable line; a file it did not list is left out, as not measured.
    static func matching(_ paths: [String], root: URL, counts byName: [String: [Int: UInt64]], listed: [String]) -> [String: [Int: UInt64]] {
        var counts: [String: [Int: UInt64]] = [:]
        let listedPaths = Set(listed.map { CanonicalPath.of($0) })
        for path in paths {
            let wanted = CanonicalPath.of(root.appendingPathComponent(path).path)
            if let match = byName.first(where: { CanonicalPath.of($0.key) == wanted }) {
                counts[path] = match.value
            } else if listedPaths.contains(wanted) {
                counts[path] = [:]
            }
        }
        return counts
    }

    /// Each changed file's line counts, keyed by repository-relative path, for the files the bundle measured or compiled with no code to run.
    func counts(for paths: [String], root: URL) throws -> [String: [Int: UInt64]] {
        let list = ["xcrun", "xccov", "view", "--archive", "--file-list", "--json", bundle.path]
        guard let listed = RunCoverage.output(list, in: workingDirectory) else {
            throw CoverageObjectsRefusal(reason: "`xccov` found no coverage in the result bundle at \(bundle.path)")
        }
        let files = try ResultBundleCoverage.files(fromFileList: listed)
        let wanted = Set(paths.map { CanonicalPath.of(root.appendingPathComponent($0).path) })
        var byName: [String: [Int: UInt64]] = [:]
        for file in files where wanted.contains(CanonicalPath.of(file)) {
            guard let data = RunCoverage.output(["xcrun", "xccov", "view", "--archive", "--file", file, "--json", bundle.path], in: workingDirectory) else {
                throw CoverageObjectsRefusal(reason: "`xccov` could not read the lines of \(file) from the result bundle")
            }
            try byName.merge(ResultBundleCoverage.lineCounts(fromFile: data)) { $1 }
        }
        return Self.matching(paths, root: root, counts: byName, listed: files)
    }
}
