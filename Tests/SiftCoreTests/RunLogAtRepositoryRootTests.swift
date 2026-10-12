//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A run started inside a nested package files its transcript under the repository's `.sift/`, where the index and every other reader of the last run look.
@Suite(.temporaryDirectories)
struct RunLogAtRepositoryRootTests {
    private func makeRepository(withPackageNamed package: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> (root: URL, package: URL) {
        let scratch = try TemporaryDirectory.make("run-log-root")
        let root = scratch.appendingPathComponent("depot", isDirectory: true)
        let nested = root.appendingPathComponent(package, isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let inside = root.resolvingSymlinksInPath().path.hasPrefix(scratch.resolvingSymlinksInPath().path + "/")

        #expect(inside, "the repository this test makes must be inside its own temporary directory", sourceLocation: sourceLocation)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "init", "--quiet", root.path]
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0, sourceLocation: sourceLocation)

        return (root, nested)
    }

    @Test
    func aRunFromANestedPackageWritesItsLogUnderTheRepositoryRoot() throws {
        let (root, nested) = try makeRepository(withPackageNamed: "DepotKit")

        let outcome = try RunLauncher(workingDirectory: nested).run(["sh", "-c", "true"])

        let log = try #require(outcome.log).url.resolvingSymlinksInPath()
        let runs = SiftPaths.cache(in: root).appendingPathComponent(RunLog.runsDirectoryName, isDirectory: true).resolvingSymlinksInPath()

        #expect(log.deletingLastPathComponent() == runs)
        #expect(!FileManager.default.fileExists(atPath: SiftPaths.cache(in: nested).path), "the nested package gained a .sift/ of its own")
    }

    @Test
    func theRepositoryRootsRunsDirectoryHoldsTheLogForEveryRunWhereverItStarted() throws {
        let (root, nested) = try makeRepository(withPackageNamed: "DepotKit")

        _ = try RunLauncher(workingDirectory: root).run(["sh", "-c", "true"])
        _ = try RunLauncher(workingDirectory: nested).run(["sh", "-c", "true"])

        let runs = SiftPaths.cache(in: root).appendingPathComponent(RunLog.runsDirectoryName, isDirectory: true)
        let logs = try FileManager.default.contentsOfDirectory(atPath: runs.path).filter { $0.hasSuffix(".log") }

        #expect(logs.count == 2)
    }

    @Test
    func aRunOutsideAnyRepositoryKeepsItsLogUnderTheWorkingDirectory() throws {
        let scratch = try TemporaryDirectory.make("run-log-no-root")
        let directory = scratch.appendingPathComponent("Orchard", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let outcome = try RunLauncher(workingDirectory: directory, repositoryRoot: nil).run(["sh", "-c", "true"])

        let log = try #require(outcome.log).url.resolvingSymlinksInPath()
        let runs = SiftPaths.cache(in: directory).appendingPathComponent(RunLog.runsDirectoryName, isDirectory: true).resolvingSymlinksInPath()

        #expect(log.deletingLastPathComponent() == runs)
    }
}
