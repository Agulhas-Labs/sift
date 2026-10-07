//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// Covers `sift build --analyse` through the command itself, with a captured clean build handed back in place of a real one.
@Suite(.temporaryDirectories)
struct BuildCommandTests {
    private static var slowSource: String {
        """
        struct Ledger {
            var rates = [1, 2.5, 3, 4.25, 5, 6.5, 7, 8.75]

            func total() -> Double {
                let sum = 1.0 + 2 + 3.5 + 4 + 5.0 + 6 + 7 + 8.25 + 9 + 10 + 11 + 12.5 + 13 + 14 + 15.5 + 16 + 17 + 18.0
                return sum
            }

            func mixed() -> [Any] {
                let values: [Any] = [1, "two", 3.0, [4, 5], ["six": 6], 7, "eight", 9.0]
                return values
            }

            func pick(_ flag: Int) -> Int {
                flag > 3 ? 1 : flag > 2 ? 2 : flag > 1 ? 3 : 4
            }

            func doubled() -> [Double] {
                rates.map { $0 * 2 }
            }
        }

        func box<T>(_ value: T) -> [T] { [value, value] }

        """
    }

    private static var mainSource: String {
        """
        let ledger = Ledger()
        _ = ledger.total()
        _ = ledger.mixed()
        _ = ledger.pick(2)
        _ = ledger.doubled()
        _ = box(1)

        """
    }

    /// The real capture of a clean build of the package above, with its absolute paths moved into `root`.
    private static func capture(relocatedTo root: URL) throws -> String {
        let fixture = URL(filePath: #filePath)
            .deletingLastPathComponent() // SiftMCPTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("SiftCoreTests/Fixtures/RunOutput/swift-build-debug-time.txt")
        return try String(contentsOf: fixture, encoding: .utf8).replacingOccurrences(of: "/Users/dev/Widget", with: root.path)
    }

    /// A package directory holding a manifest and the captured sources.
    private static func package() throws -> URL {
        let root = try TemporaryDirectory.make("build-analyse")
        let sources = root.appendingPathComponent("Sources/Widget", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\n".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try slowSource.write(to: sources.appendingPathComponent("Slow.swift"), atomically: true, encoding: .utf8)
        try mainSource.write(to: sources.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        return root
    }

    /// A committed git repository whose `Package.swift` and captured sources sit below its root, at `relativePath`.
    private static func gitPackage(at relativePath: String) throws -> (repoRoot: URL, packageRoot: URL) {
        let repoRoot = try TemporaryDirectory.make("build-analyse-repo")
        for arguments in [
            ["init", "-b", "main"],
            ["config", "user.email", "test@example.com"],
            ["config", "user.name", "Tester"],
        ] {
            try Self.runGit(arguments, in: repoRoot)
        }
        let packageRoot = repoRoot.appendingPathComponent(relativePath, isDirectory: true)
        let sources = packageRoot.appendingPathComponent("Sources/Widget", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\n".write(to: packageRoot.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try slowSource.write(to: sources.appendingPathComponent("Slow.swift"), atomically: true, encoding: .utf8)
        try mainSource.write(to: sources.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try Self.runGit(["add", "-A"], in: repoRoot)
        try Self.runGit(["commit", "-m", "seed"], in: repoRoot)
        return (repoRoot.resolvingSymlinksInPath(), packageRoot.resolvingSymlinksInPath())
    }

    @discardableResult
    private static func runGit(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink
        try process.run()
        let output = sink.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: output, encoding: .utf8) ?? ""
            struct GitError: Error { let message: String }
            throw GitError(message: "git \(arguments.joined(separator: " ")) failed in test: \(text)")
        }
        return String(data: output, encoding: .utf8) ?? ""
    }

    /// Runs the command on `root` with a launcher that hands back `transcript` as the build's log, writing the arguments it was given to `asked.txt` in the root.
    private static func analyse(_ root: URL, transcript: String, exitCode: Int32 = 0, top: [String] = []) throws -> (output: RecordedOutput, exit: Int32?) {
        var command = try BuildCommand.parse(["--analyse", "--root", root.path] + top)
        let recorded = RecordedOutput()
        command.output = recorded.output
        command.launch = { arguments, directory in
            try arguments.joined(separator: " ").write(to: directory.appendingPathComponent("asked.txt"), atomically: true, encoding: .utf8)
            let log = RunLog.open(inDirectory: directory)
            log?.append(Data(transcript.utf8))
            log?.close()
            return RunOutcome(kind: .swiftBuild, logKey: "swift build", exitCode: exitCode, report: nil, log: log, repositoryRoot: nil)
        }
        do {
            try command.run()
            return (recorded, nil)
        } catch let exit as ExitCode {
            return (recorded, exit.rawValue)
        }
    }

    @Test
    func theHeaderSaysTheBuildWasCleanAndCountsTheTimingLinesAndFiles() throws {
        let root = try Self.package()

        let (output, exit) = try Self.analyse(root, transcript: Self.capture(relocatedTo: root))

        #expect(exit == nil)
        let header = try #require(output.printed.split(separator: "\n").first)
        #expect(header.hasPrefix("✔ sift build --analyse — clean build, "))
        #expect(header.hasSuffix(", 46 timing lines over 2 files"))
    }

    @Test
    func theSlowestBodyAndExpressionLeadTheirSectionsNamedByTheirDeclaration() throws {
        let root = try Self.package()

        let (output, _) = try Self.analyse(root, transcript: Self.capture(relocatedTo: root))

        let lines = output.printed.split(separator: "\n").map(String.init)
        let bodies = try #require(lines.firstIndex { $0.hasPrefix("slowest bodies — ") })
        let expressions = try #require(lines.firstIndex { $0.hasPrefix("slowest expressions — ") })

        #expect(lines[bodies + 1] == "  Sources/Widget/Slow.swift:4 · 7.09 ms · Ledger.total()")
        #expect(lines[expressions + 1] == "  Sources/Widget/Slow.swift:5 · 2.96 ms · Ledger.total() · long literal chain")
    }

    @Test
    func theTotalsStateBothSharesAndNeverAddTheTwo() throws {
        let root = try Self.package()

        let (output, _) = try Self.analyse(root, transcript: Self.capture(relocatedTo: root), top: ["--top", "1"])

        let totals = output.printed.split(separator: "\n").first { $0.hasPrefix("bodies ") }

        #expect(totals == "bodies 14.66 ms of which the 1 listed are 48% · expressions 12.62 ms, listed 23% — a body's time includes its expressions', so the two are not added")
    }

    @Test
    func theBuildIsTheNativeBuildSystemWithBothTimersIntoACleanedScratchPath() throws {
        let root = try Self.package()
        let stale = root.appendingPathComponent(".build/sift-timing/stale.o")
        try FileManager.default.createDirectory(at: stale.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "".write(to: stale, atomically: true, encoding: .utf8)

        let (output, _) = try Self.analyse(root, transcript: Self.capture(relocatedTo: root))

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        let asked = try String(contentsOf: root.appendingPathComponent("asked.txt"), encoding: .utf8)
        #expect(asked.hasPrefix("swift build --build-system native --scratch-path .build/sift-timing "))
        #expect(asked.contains("-Xswiftc -Xfrontend -Xswiftc -debug-time-function-bodies"))
        #expect(asked.contains("-Xswiftc -Xfrontend -Xswiftc -debug-time-expression-type-checking"))
        #expect(output.printed.contains(" — raw output at .sift/runs/"))
    }

    @Test
    func aGreenBuildThatPrintedNoTimingLineIsRefusedNotAnsweredAsNothingSlow() throws {
        let root = try Self.package()

        let (output, exit) = try Self.analyse(root, transcript: "Building for debugging...\nBuild complete! (0.54s)\n")

        #expect(exit == 1)
        #expect(output.printed.isEmpty)
        #expect(output.errors.last?.hasPrefix("sift build --analyse: the build printed no timing lines; ") == true)
    }

    @Test
    func anXcodeProjectWithNoPackageIsRefusedAsOutOfScope() throws {
        let root = try TemporaryDirectory.make("build-analyse-xcode")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Gizmo.xcodeproj"), withIntermediateDirectories: true)

        let (output, exit) = try Self.analyse(root, transcript: "")

        #expect(exit == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("asked.txt").path))
        #expect(output.errors.count == 1)
        #expect(output.errors.first?.hasPrefix("sift build --analyse: SwiftPM packages only — ") == true)
    }

    @Test
    func aFailedBuildServesItsOwnFailureAndExitsWithItsCode() throws {
        let root = try Self.package()

        let (output, exit) = try Self.analyse(root, transcript: "error: no such module 'Missing'\n", exitCode: 1)

        #expect(exit == 1)
        #expect(!output.printed.contains("slowest bodies"))
        #expect(output.errors.last?.contains("the build failed") == true)
    }

    /// From the repository root, `--root Packages/Probe` names rows repo-relative and builds at the package's own directory, never the repo root.
    @Test
    func aPackageBelowTheGitRootIsNamedRepoRelativeAndBuildsAtItsOwnDirectory() throws {
        let (repoRoot, packageRoot) = try Self.gitPackage(at: "Packages/Probe")

        let (output, exit) = try Self.analyse(packageRoot, transcript: Self.capture(relocatedTo: packageRoot))

        #expect(exit == nil)
        let lines = output.printed.split(separator: "\n").map(String.init)
        let bodies = try #require(lines.firstIndex { $0.hasPrefix("slowest bodies — ") })
        #expect(lines[bodies + 1] == "  Packages/Probe/Sources/Widget/Slow.swift:4 · 7.09 ms · Ledger.total()")
        #expect(FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent("asked.txt").path))
        #expect(!FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("asked.txt").path))
    }

    /// The package root the command builds at is found by ascending from what was requested, never jumping straight to the enclosing git root — the shape `cd Packages/Probe && sift build --analyse` needs, which `resolvePackageRoot` decides before a build ever runs.
    @Test
    func thePackageRootIsFoundByAscendingFromWhatWasRequestedNotTheGitRoot() throws {
        let (repoRoot, packageRoot) = try Self.gitPackage(at: "Packages/Probe")

        let resolved = BuildCommand.resolvePackageRoot(from: packageRoot, stopAt: repoRoot)

        #expect(resolved.standardizedFileURL.path == packageRoot.standardizedFileURL.path)
        #expect(BuildCommand.scopeRefusal(at: resolved) == nil)
        // The bug this pins: the old resolution always used the git root, which holds no manifest here.
        #expect(BuildCommand.scopeRefusal(at: repoRoot) != nil)
    }
}
