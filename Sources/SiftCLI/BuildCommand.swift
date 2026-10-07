//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore

/// `sift build --analyse` — builds a SwiftPM package clean with the compiler's own timers on, and answers with which code was slowest to type-check.
struct BuildCommand: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "build",
            abstract: "Build a SwiftPM package clean and rank the code slowest to type-check.",
            discussion: """
            `--analyse` is the only mode. Unlike `sift test --analyse`, which builds nothing, this one \
            builds: it deletes .build/sift-timing, runs `swift build --build-system native` into that \
            scratch path with -debug-time-function-bodies and -debug-time-expression-type-checking passed \
            on the command line (the manifest is never edited, and your own .build products are \
            untouched). --build-system native is deprecated by SwiftPM, but it is the only one that \
            prints these timing lines on Swift 6.4. It answers with the slowest function bodies and the \
            slowest expressions, each \
            named by the declaration enclosing it, the files holding the most time, and both totals with \
            the share the listed rows hold. A body's time includes its expressions', so the two totals are \
            never added. `swift build` skips test targets, so the ranking covers the compiled targets only \
            and says so; --build-tests adds the test targets to the build. The raw log is kept under \
            .sift/runs/ and the answer's last line names it.

            SwiftPM only: a tree with an Xcode project and no Package.swift is refused. A failed build is \
            answered as `sift run` answers it, and a successful build that printed no timing line is \
            refused rather than read as nothing being slow. `sift help build-output` reads the answer.

            Examples:
              sift build --analyse
              sift build --analyse --top 20 --root Packages/Kit
            """
        )
    }

    @Flag(name: .customLong("analyse"), help: "Build clean with the compiler's timers on and rank the slowest bodies and expressions. The only mode.")
    var analyse: Bool = false

    @Flag(name: .customLong("build-tests"), help: "Build the test targets too (swift build --build-tests), so their code is timed and ranked. Without it the ranking covers the compiled targets only.")
    var buildTests: Bool = false

    @Option(name: .customLong("top"), help: "How many bodies, expressions and files to list. Defaults to 10.")
    var top: Int = 10

    @OptionGroup var rootOptions: RootOptions

    /// Where the answer goes, injected so a test can read what the command printed.
    var output: CommandOutput = .standard

    /// How the build is run, injected so a test can hand back a captured build instead of compiling one.
    var launch: @Sendable (_ arguments: [String], _ root: URL) throws -> RunOutcome = { arguments, root in
        try RunLauncher(workingDirectory: root, repositoryRoot: GitContext.discoverRoot(from: root)).run(arguments)
    }

    /// Where the timed build writes, inside the package's own gitignored `.build/`.
    static var scratchPath: String {
        ".build/sift-timing"
    }

    /// The build `--analyse` runs: the native build system, which prints the timing lines one per line where the default one drops them.
    static let arguments = arguments(buildingTests: false)

    /// ``arguments``, with `--build-tests` after the scratch path when the test targets are to be timed too.
    static func arguments(buildingTests: Bool) -> [String] {
        [
            "swift", "build",
            "--build-system", "native",
            "--scratch-path", scratchPath,
        ] + (buildingTests ? ["--build-tests"] : []) + [
            "-Xswiftc", "-Xfrontend", "-Xswiftc", "-debug-time-function-bodies",
            "-Xswiftc", "-Xfrontend", "-Xswiftc", "-debug-time-expression-type-checking",
        ]
    }

    func validate() throws {
        guard analyse else {
            throw ValidationError("sift build has one mode, --analyse: it builds the package clean with the compiler's timers on and ranks what was slowest to type-check.")
        }
        guard top > 0 else {
            throw ValidationError("--top takes a count of at least 1.")
        }
    }

    func run() throws {
        let requested = rootOptions.root == nil ? rootOptions.directory : rootOptions.directory.standardizedFileURL
        let gitRoot = GitContext.discoverRoot(from: requested)
        let packageRoot = Self.resolvePackageRoot(from: requested, stopAt: gitRoot)
        let treeRoot = gitRoot ?? packageRoot
        if let refusal = Self.scopeRefusal(at: packageRoot) {
            output.emitError(refusal)
            throw ExitCode.failure
        }
        // Deleted rather than `swift package clean`, which keeps what it thinks is still good: a second run
        // into the same scratch path would otherwise rebuild nothing and time nothing.
        let scratch = packageRoot.appendingPathComponent(Self.scratchPath, isDirectory: true)
        if FileManager.default.fileExists(atPath: scratch.path) {
            try FileManager.default.removeItem(at: scratch)
        }
        output.emitError("building \(packageRoot.lastPathComponent) clean into .build/sift-timing with the compiler's timing flags — this rebuilds every module and can take minutes.")
        let started = Date()
        let outcome = try launch(Self.arguments(buildingTests: buildTests), packageRoot)
        let seconds = Date().timeIntervalSince(started)
        guard outcome.exitCode == 0 else {
            reportFailure(outcome, root: packageRoot)
            throw ExitCode(outcome.exitCode)
        }
        let text = outcome.log?.contents().map { String(decoding: $0, as: UTF8.self) } ?? "" // swiftlint:disable:this optional_data_string_conversion no_swiftlint_disable
        let timings = BuildTimingParser.timings(in: text)
        guard !timings.isEmpty else {
            let location = outcome.log.map { "raw output at \(RunAnswerPaths.read(in: packageRoot).shown($0.url.path))" } ?? "the raw log was not recorded"
            output.emitError("sift build --analyse: the build printed no timing lines; it succeeded, so this is not an answer that nothing is slow — this toolchain's `swift build --build-system native` did not print what -debug-time-function-bodies asks for (\(location)).")
            throw ExitCode.failure
        }
        let analysis = BuildTimingAnalysis(timings: timings, packageRoot: packageRoot, treeRoot: treeRoot, top: top)
        let logLines = text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0)
        output.emit(BuildTimingRenderer(root: packageRoot).render(analysis, seconds: seconds, logLines: logLines, logURL: outcome.log?.url, top: top, builtWithTests: buildTests, packageHasTestTargets: SwiftPMManifest.declaresTestTargets(inPackageAt: packageRoot)))
    }

    /// The package root: what was requested when it holds a manifest itself, else the nearest ancestor, no further up than the git root, that does.
    static func resolvePackageRoot(from requested: URL, stopAt gitRoot: URL?) -> URL {
        let manager = FileManager.default
        let stopPath = gitRoot?.standardizedFileURL.path
        var candidate = requested.standardizedFileURL
        while true {
            if manager.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path) {
                return candidate
            }
            guard candidate.path != stopPath, candidate.path != "/" else {
                return requested.standardizedFileURL
            }
            candidate = candidate.deletingLastPathComponent()
        }
    }

    /// The one line owed a tree this command cannot build: no package at its root.
    static func scopeRefusal(at root: URL) -> String? {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: root.appendingPathComponent("Package.swift").path) else {
            return nil
        }
        let entries = (try? manager.contentsOfDirectory(atPath: root.path)) ?? []
        if entries.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            return "sift build --analyse: SwiftPM packages only — \(root.path) has an Xcode project and no Package.swift, and an xcodebuild build is not analysed; pass --root <a package directory> to time one of its packages."
        }
        return "sift build --analyse: no Package.swift at \(root.path) — pass --root <the package directory>."
    }
}

private extension BuildCommand {
    /// A failed build's own answer, as `sift run` gives it, or its raw log where the filter could not explain it.
    func reportFailure(_ outcome: RunOutcome, root: URL) {
        if let answer = outcome.filteredAnswer(workingDirectory: root) {
            output.emit(answer.text)
            return
        }
        guard let log = outcome.log, let raw = log.contents() else {
            output.emitError("sift build --analyse: the build failed, and no raw log of it could be read — run `\(Self.arguments(buildingTests: buildTests).joined(separator: " "))` in \(root.path) to see why.")
            return
        }
        output.emitError("sift build --analyse: the build failed, and the filter found nothing that explains it — raw output follows.")
        output.emitRaw(RunReportRenderer.clippingLongLines(of: raw, log: log.url))
    }
}

extension BuildCommand {
    /// Only the flags and options come off the command line.
    ///
    /// Spelled out for the reason ``TestCommand``'s keys are: neither an output nor a launcher is something a decoder can produce.
    enum CodingKeys: String, CodingKey {
        case analyse
        case buildTests
        case top
        case rootOptions
    }
}
