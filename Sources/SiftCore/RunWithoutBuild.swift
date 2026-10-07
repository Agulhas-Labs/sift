//
// Copyright © Agulhas Labs
//

import Foundation

/// Where `run --without` builds the tree with the change set aside: a build directory of its own under `.sift/`, never the one the caller's builds use.
///
/// **An incremental build trusts what it last recorded, not what it last wrote** — observed by ending a build with `SIGINT` mid-compile: the interrupted build recompiled unchanged dependents against the set-aside tree without recording that it had, and its stale objects were in files the set-aside never touched. What is inferred, not reproduced, is what happens next: once the changes are back, byte for byte what that build directory last recorded, nothing the next build there can see has changed, so it links those stale objects against the restored tree — a struct copied at the size it had without the change would be a `SIGBUS` in the next test run. A new timestamp on the restored files cannot reach them, because they belong to files that were never set aside. So the run without the change never writes where the run with it, or the caller's next build, reads: SwiftPM is handed `--scratch-path` and `xcodebuild` `-derivedDataPath`, both into this directory, in place of any the command named.
///
/// **It is built on again only after a build of the same package or scheme that reached its tests** — the one sign a build finished, and so recorded everything it wrote — with nothing it started left running. After any other run, and before a run for another package, project, workspace or scheme, it is removed before the next one builds in it, so a proof never rests on what a stopped build, or another package's, left there either.
public struct RunWithoutBuild: Sendable {
    /// The build directory: `.sift/without-build/swiftpm` or `.sift/without-build/xcodebuild`, one per tool, since the two lay a build directory out differently.
    public let directory: URL
    /// Present only while ``directory`` holds a build that reached its tests, and holding the ``subject`` that build was for.
    let finished: URL
    /// What a build here is for: the directory the command runs in, and the package path, project, workspace and scheme it names — written into ``finished``, so only a run for the same one builds on what is there.
    ///
    /// A build directory is laid out by package and target *name*, not by path — `Intermediates.noindex/<Package>.build/…` under SwiftPM's build system, observed — so nothing says one package's build never trusts what another's left under the same name.
    let subject: String
    private let kind: RunCommandKind
    private let name: String
    /// The repository the command runs in, whose own git configuration ``environment`` carries.
    private let repositoryRoot: URL
    /// Where the command runs — what ``shownDirectory`` names the directory from.
    private let workingDirectory: URL
    /// The command this build directory is for — the one ``kind`` was read from, and the one ``rewrittenArguments`` rewrites, so the two are never asked to agree about different commands.
    private let arguments: [String]

    /// The build directory for `arguments`, a command `RunWithoutArguments.check` accepted, run in `workingDirectory` in the repository at `repositoryRoot`.
    public init(repositoryRoot: URL, workingDirectory: URL, arguments: [String]) {
        self.arguments = arguments
        self.repositoryRoot = repositoryRoot
        self.workingDirectory = workingDirectory
        kind = RunCommandKind.recognize(arguments)
        name = kind == .xcodebuild ? "xcodebuild" : "swiftpm"
        let parent = SiftPaths.cache(in: repositoryRoot).appendingPathComponent("without-build")
        directory = parent.appendingPathComponent(name)
        finished = parent.appendingPathComponent("\(name).finished")
        subject = Self.subject(of: arguments, kind: kind, in: workingDirectory)
    }
}

public extension RunWithoutBuild {
    /// The directory as the caller would name it from where the command runs — relative to that directory when it is inside it, and by its whole path from anywhere below the repository root — the way the answer's receipt names it.
    var shownDirectory: String {
        RunAnswerPaths.read(in: workingDirectory).shown(directory.path)
    }

    /// The command this directory was made for, building in ``directory``: any build location it named taken out, and this one put in.
    var rewrittenArguments: [String] {
        guard let executable = arguments.first else {
            return arguments
        }
        switch kind {
        case .xcodebuild:
            return [executable, "-derivedDataPath", directory.path] + Self.removing(["-derivedDataPath"], joined: false, from: arguments.dropFirst())
        case .swiftTest, .swiftBuild:
            var rest = Self.removing(["--scratch-path", "--build-path"], joined: true, from: arguments.dropFirst())
            // Straight after the subcommand, which is the first argument that is not a flag — the reading
            // `RunCommandKind.recognize` accepted the command on.
            let subcommand = rest.firstIndex { !$0.hasPrefix("-") }.map { $0 + 1 } ?? rest.endIndex
            rest.insert(contentsOf: ["--scratch-path", directory.path], at: subcommand)
            return [executable] + rest
        case .linter, .unrecognized:
            return arguments
        }
    }

    /// Readies ``directory`` for the run without the change: built on when the last build in it was for the same ``subject`` and reached its tests, removed otherwise — and either way no longer marked as finished, since the build about to run in it may not be.
    func prepare() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: finished.path) {
            let same = (try? String(contentsOf: finished, encoding: .utf8)) == subject
            try fileManager.removeItem(at: finished)
            if same {
                return
            }
        }
        do {
            try fileManager.removeItem(at: directory)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Nothing was ever built here.
        }
    }

    /// Marks ``directory`` as holding a build of ``subject`` that reached its tests, so the next run for the same one builds on it rather than from nothing.
    ///
    /// Best effort: a mark that cannot be written costs the next run a build from nothing, never a wrong one.
    func keep() {
        FileManager.default.createFile(atPath: finished.path, contents: Data(subject.utf8))
    }

    /// ``directory``'s size on disk, in bytes — `nil` while nothing has been built there.
    ///
    /// Walked in full each time it is asked for, which the answer does once, after the second run: a stat a file, measured at about a fifth of a second for a 950 MB build directory of 13 thousand files. Best effort: a directory that cannot be walked, or one a race removes mid-walk, reads as smaller than it is rather than throwing.
    var sizeOnDisk: Int64? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else {
            return nil
        }
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey]) else {
            return nil
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey]),
                  values.isDirectory != true, let size = values.totalFileAllocatedSize
            else {
                continue
            }
            total += Int64(size)
        }
        return total
    }

    /// The environment the command runs in here: this process's own, with the repository's `url.<base>.insteadof` rewrites carried in as git configuration.
    ///
    /// A package that names a dependency by one URL and relies on the repository's configuration to fetch it by another resolves in the caller's build directory and fails in this one, because the clone SwiftPM or `xcodebuild` makes into a build directory of its own runs a git that never finds the repository, and so never reads its configuration file.
    var environment: [String: String] {
        ProcessEnvironment.carrying(gitConfiguration: GitContext(repoRoot: repositoryRoot).localURLRewrites())
    }

    /// The one-line answer for a run here that stopped because the package's dependencies could not be fetched, quoting the line that says so — `nil` for any other outcome.
    ///
    /// No test ran without the change, so nothing was proven either way, and the run with it would add nothing to that.
    static func unresolvedAnswer(to outcome: RunOutcome, without pathspecs: String) -> String? {
        guard outcome.exitCode != 0, let report = outcome.report, report.testOutcomes.isEmpty else {
            return nil
        }
        let errors = report.errors.filter { $0.path == nil }
        let allLines = errors.flatMap { [$0.message] + $0.detail }
        guard let line = causeLine(among: errors) ?? allLines.first(where: isRepositoryCacheGitFailure) else {
            return nil
        }
        let quoted = RunFailureCensus.clipped(line.trimmingCharacters(in: .whitespaces), to: RunReportRenderer.lineCap)
        return "✘ could not build without \(pathspecs): dependency resolution failed — nothing was proven (\(quoted))"
    }

    /// What SwiftPM and `xcodebuild` print when a dependency could not be fetched, most specific first, so the line quoted is the one naming the repository.
    private static let resolutionMarkers = ["Failed to clone repository", "Could not resolve package dependencies"]

    /// The line among `errors` worth quoting — never a bare header.
    ///
    /// `xcodebuild` (and SwiftPM, where it does the same) sometimes names only the failure on that line and puts the cause on the indented lines beneath it; a marker that matches nothing but that bare header is followed to the first line under it instead. A header that already names the repository itself — `Failed to clone repository <url>:` — is not bare, and is quoted as it stands.
    private static func causeLine(among errors: [RunDiagnostic]) -> String? {
        for marker in resolutionMarkers {
            for error in errors {
                let lines = [error.message] + error.detail
                guard let matched = lines.first(where: { $0.localizedCaseInsensitiveContains(marker) }) else {
                    continue
                }
                guard matched == error.message, isBareHeader(matched, naming: marker), let cause = error.detail.first else {
                    return matched
                }
                return cause
            }
        }
        return nil
    }

    /// Whether `line` says no more than `marker` itself — the shape of a header that names the failure but leaves the cause to the lines beneath it, versus one, like `Failed to clone repository <url>:`, that already names what failed.
    private static func isBareHeader(_ line: String, naming marker: String) -> Bool {
        guard let range = line.range(of: marker, options: .caseInsensitive) else {
            return false
        }
        let tail = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return tail.isEmpty || tail == ":"
    }

    /// Whether `line` is SwiftPM saying a git command it ran in its shared cache of repositories failed.
    ///
    /// With that cache on, which is the default, a dependency that was never fetched fails this way rather than as a clone: SwiftPM asks the cached copy for its remote before it clones anything.
    private static func isRepositoryCacheGitFailure(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let command = trimmed.hasPrefix("error: ") ? trimmed.dropFirst("error: ".count) : Substring(trimmed)
        guard command.hasPrefix("Git command '"), let end = command.range(of: "' failed") else {
            return false
        }
        return command[..<end.lowerBound].contains("/repositories/")
    }
}

private extension RunWithoutBuild {
    /// What a build of `arguments`, run in `workingDirectory`, is for: that directory, then each package, project, workspace or scheme the command names, sorted — the arguments that choose what is built, and none of those that only choose which tests run.
    static func subject(of arguments: [String], kind: RunCommandKind, in workingDirectory: URL) -> String {
        let options: Set<String> = kind == .xcodebuild ? ["-project", "-workspace", "-scheme"] : ["--package-path"]
        var named: [String] = []
        var taking: String?
        for argument in arguments.dropFirst() {
            if let option = taking {
                named.append("\(option) \(argument)")
                taking = nil
            } else if options.contains(argument) {
                taking = argument
            } else if let option = options.first(where: { argument.hasPrefix("\($0)=") }) {
                named.append("\(option) \(argument.dropFirst(option.count + 1))")
            }
        }
        return ([workingDirectory.standardizedFileURL.path] + named.sorted()).joined(separator: "\n")
    }

    /// `arguments` without `options` and the value each takes — the next argument, or what follows `=` where `joined`.
    static func removing(_ options: Set<String>, joined: Bool, from arguments: ArraySlice<String>) -> [String] {
        var kept: [String] = []
        var takesValue = false
        for argument in arguments {
            if takesValue {
                takesValue = false
                continue
            }
            if options.contains(argument) {
                takesValue = true
                continue
            }
            if joined, options.contains(where: { argument.hasPrefix("\($0)=") }) {
                continue
            }
            kept.append(argument)
        }
        return kept
    }
}
