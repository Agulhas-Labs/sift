//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore

/// The coverage section of a `sift run --coverage` run: of `swift test`, read from the profile SwiftPM merged and the test bundles it ran; of `xcodebuild test`, from its result bundle.
struct RunCoverage {
    let workingDirectory: URL
    let root: URL
    /// The argv the run launched, `--enable-code-coverage` included.
    let arguments: [String]
    let from: String?
    let treeBefore: TreeKey?
    let started: Date
}

extension RunCoverage {
    /// `arguments` with coverage turned on, where they do not already turn it on.
    static func enabling(_ arguments: [String], run: String = XcodebuildCoverage.runID) -> [String] {
        if RunCommandKind.recognize(arguments) == .xcodebuild {
            return XcodebuildCoverage.enabling(arguments, run: run)
        }
        return arguments.contains("--enable-code-coverage") ? arguments : arguments + ["--enable-code-coverage"]
    }

    /// Refuses a line `--coverage` cannot answer for, before anything runs.
    ///
    /// Kept out of line because, inlined into `RunCommand.run()`, it crashes the Swift 6.4 optimizer's copy propagation in a release build.
    @inline(never)
    static func validate(_ arguments: [String], coverage: Bool, from: String?, setsAside: Bool, restoresOrProves: Bool) throws {
        guard coverage else {
            if from != nil {
                throw ValidationError("sift run --from names the revision --coverage measures a change from, and means nothing without --coverage.")
            }
            return
        }
        guard !setsAside, !restoresOrProves else {
            throw ValidationError("sift run --coverage takes no --without, --without-line, --restore or --proved: it measures one run of the tree as it stands.")
        }
        switch RunCommandKind.recognize(arguments) {
        case .swiftTest:
            break
        case .xcodebuild:
            try XcodebuildCoverage.validate(arguments)
            return
        default:
            throw ValidationError("sift run --coverage measures a `swift test` or `xcodebuild test` run only, not \(arguments.first ?? "nothing").")
        }
        if arguments.contains("--disable-code-coverage") {
            throw ValidationError("sift run --coverage cannot measure a run that says --disable-code-coverage.")
        }
        if arguments.contains("--skip-build") {
            throw ValidationError("sift run --coverage refuses --skip-build: coverage of binaries this run did not build cannot be tied to this tree.")
        }
    }

    /// Refuses a `--from` that names no commit, before anything runs: a run that has already spent the whole suite cannot then answer the one question it was asked.
    static func validateRevision(_ from: String?, in root: URL?) throws {
        guard let from, let root, !GitContext(repoRoot: root).resolvesToCommit(from) else {
            return
        }
        throw ValidationError("sift run --from \(from) names no commit to measure a change from.")
    }

    /// The section for a run started in `root`, or the refusal that says why there is none where the run is outside any repository.
    static func section(workingDirectory: URL, root: URL?, arguments: [String], from: String?, treeBefore: TreeKey?, started: Date) -> [String] {
        guard let root else {
            return CoverageAnswer.refused("this directory is in no git repository, so there is no change to measure")
        }
        return RunCoverage(workingDirectory: workingDirectory, root: root, arguments: arguments, from: from, treeBefore: treeBefore, started: started).lines()
    }

    /// The section's lines: refused with its reason, or each changed declaration measured, which is then recorded for `diff --coverage`.
    func lines() -> [String] {
        let git = GitContext(repoRoot: root)
        let revision = from ?? "HEAD"
        guard git.resolvesToCommit(revision) else {
            return CoverageAnswer.refused("\(revision) names no commit to measure a change from")
        }
        let treeAfter = TreeKey.of(repositoryRoot: root)
        // The bundle is read once, below, and only the one this run's own name gave is removed with the run.
        defer {
            if XcodebuildCoverage.writesOwnResultBundle(arguments), let bundle = XcodebuildCoverage.bundlePath(of: arguments, in: workingDirectory) {
                try? FileManager.default.removeItem(at: bundle)
            }
        }
        let measure: ([String]) throws -> [String: [Int: UInt64]]
        if RunCommandKind.recognize(arguments) == .xcodebuild {
            guard let bundle = XcodebuildCoverage.bundlePath(of: arguments, in: workingDirectory) else {
                return CoverageAnswer.refused("the `xcodebuild` line names no result bundle")
            }
            if let reason = ResultBundleCoverage.refusal(bundle: bundle, treeBefore: treeBefore, treeAfter: treeAfter, runStarted: started) {
                return CoverageAnswer.refused(reason)
            }
            measure = { try XcodebuildCoverage(bundle: bundle, workingDirectory: workingDirectory).counts(for: $0, root: root) }
        } else {
            guard let exported = Self.output(["swift"] + Self.askingPath(arguments), in: workingDirectory) else {
                return CoverageAnswer.refused("`swift test --show-codecov-path` named no coverage file for this run")
            }
            let codecov = URL(fileURLWithPath: (String(bytes: exported, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)).deletingLastPathComponent()
            let profile = codecov.appendingPathComponent("default.profdata")
            let written = (try? profile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let reason = CoverageAnswer.refusal(treeBefore: treeBefore, treeAfter: treeAfter, profileWritten: written, runStarted: started) {
                return CoverageAnswer.refused(reason)
            }
            measure = { try swiftTestCounts(for: $0, products: codecov.deletingLastPathComponent(), profile: profile) }
        }
        let change = from.map { "the working tree against \($0)" } ?? "the working tree against HEAD"
        guard let declarations = try? ChangedDeclaration.inWorkingTree(against: revision, git: git) else {
            return CoverageAnswer.refused("git could not list the change")
        }
        let paths = Array(Set(declarations.map(\.path))).sorted()
        guard !paths.isEmpty else {
            return CoverageAnswer.render([], counts: [:], change: change)
        }
        let counts: [String: [Int: UInt64]]
        do {
            counts = try measure(paths)
        } catch let refusal as CoverageObjectsRefusal {
            return CoverageAnswer.refused(refusal.reason)
        } catch {
            return CoverageAnswer.refused("the coverage could not be read")
        }
        if let treeAfter {
            try? CoverageRecord(tree: treeAfter.value, command: arguments, measured: counts, unmeasured: paths.filter { counts[$0] == nil }).write(in: root)
        }
        return CoverageAnswer.render(declarations, counts: counts, change: change)
    }

    /// Each changed file's line counts from `llvm-cov export` over the declared test bundles beside SwiftPM's profile.
    private func swiftTestCounts(for paths: [String], products: URL, profile: URL) throws -> [String: [Int: UInt64]] {
        let present = ((try? FileManager.default.contentsOfDirectory(atPath: products.path)) ?? []).filter { $0.hasSuffix(".xctest") }
        let objects = try CoverageObjects.select(declared: RunTestBundles.declaredNames(forRunOf: arguments, in: workingDirectory), present: present)
            .compactMap { Self.executable(ofBundle: products.appendingPathComponent($0)) }
        guard let first = objects.first else {
            throw CoverageObjectsRefusal(reason: "no declared test bundle has an executable beside the profile")
        }
        let export = ["xcrun", "llvm-cov", "export", "-skip-functions", "-skip-expansions", "-skip-branches", "-instr-profile", profile.path, first.path]
            + objects.dropFirst().flatMap { ["-object", $0.path] } + ["-sources"] + Self.sourcesToExport(paths, root: root)
        guard let json = Self.output(export, in: workingDirectory), let byName = try? CoverageAnswer.lineCounts(fromExport: json) else {
            throw CoverageObjectsRefusal(reason: "`llvm-cov export` could not read this run's profile")
        }
        return Self.matching(paths, root: root, counts: byName, measured: Array(byName.keys))
    }

    /// The changed files' counts keyed by repository-relative path: a file the tool measured, or one compiled beside a measured file with no code to run; a file neither is left out, as not measured.
    static func matching(_ paths: [String], root: URL, counts byName: [String: [Int: UInt64]], measured: [String]) -> [String: [Int: UInt64]] {
        var counts: [String: [Int: UInt64]] = [:]
        for path in paths {
            let wanted = CanonicalPath.of(root.appendingPathComponent(path).path)
            if let match = byName.first(where: { CanonicalPath.of($0.key) == wanted }) {
                counts[path] = match.value
            } else if CoverageAnswer.isCompiledBeside(path, root: root, measured: measured) {
                counts[path] = [:]
            }
        }
        return counts
    }

    /// The same argv asking only where SwiftPM keeps its coverage, so every path-changing option it carries is honoured.
    static func askingPath(_ arguments: [String]) -> [String] {
        guard let test = arguments.firstIndex(of: "test") else {
            return arguments
        }
        return Array(arguments[1 ... test]) + ["--show-codecov-path"] + arguments[(test + 1)...]
    }

    /// The changed files and the Swift files beside them, so a changed file with no executable code can be told from one no bundle compiled.
    static func sourcesToExport(_ paths: [String], root: URL) -> [String] {
        var sources = Set(paths.map { root.appendingPathComponent($0).path })
        for directory in Set(paths.map { root.appendingPathComponent($0).deletingLastPathComponent() }) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            sources.formUnion(names.filter { $0.hasSuffix(".swift") }.map { directory.appendingPathComponent($0).path })
        }
        return sources.sorted()
    }

    /// The executable inside a test bundle, or the bundle itself where it is a single file, or `nil` where neither exists.
    static func executable(ofBundle bundle: URL) -> URL? {
        if let executable = Bundle(url: bundle)?.executableURL, FileManager.default.fileExists(atPath: executable.path) {
            return executable
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: bundle.path, isDirectory: &isDirectory) && !isDirectory.boolValue ? bundle : nil
    }

    /// One command's stdout, or `nil` where it could not start or exited nonzero.
    static func output(_ arguments: [String], in directory: URL) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        guard (try? process.run()) != nil else {
            ProcessStreams.abandon(stdout, stderr)
            return nil
        }
        let (data, _) = ProcessStreams.drain(stdout: stdout, stderr: stderr)
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
