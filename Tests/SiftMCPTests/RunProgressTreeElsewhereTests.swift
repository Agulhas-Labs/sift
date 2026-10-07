//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// What tree a `sift run` writes into its progress file when the command builds some other checkout.
@Suite(.temporaryDirectories)
struct RunProgressTreeElsewhereTests {
    /// A build pointed at another checkout names no tree in the file, which sits under the checkout `sift run` was started in: the Stop gate would otherwise tell a context to wait for a build of a different `.build`.
    @Test(arguments: ["--package-path", "-C"])
    func aBuildOfAnotherCheckoutWritesNoTreeIntoItsProgressFile(flag: String) throws {
        let root = try #require(GitContext.discoverRoot(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
        let directory = try TemporaryDirectory.make("run-progress-tree-elsewhere")
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = try TemporaryDirectory.make("run-progress-tree-built")
        defer { try? FileManager.default.removeItem(at: built) }
        try Self.initialiseRepository(at: built)
        let swift = directory.appendingPathComponent("swift")
        try "#!/bin/sh\necho 'Build complete!'\nexit 0\n".write(to: swift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
        var command = try RunCommand.parse(["--", swift.path, "build", flag, built.path])
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory
        command.environment = [:]

        try command.run()
        let files = RunProgressPaths.directory(in: root, writesUnder: directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: files.path).filter(RunProgressPaths.isRunFile)
        let snapshot = try RunProgressSnapshot.decoded(from: Data(contentsOf: files.appendingPathComponent(#require(names.first))))

        #expect(names.count == 1)
        #expect(snapshot.tree == nil)
        #expect(TreeKey.of(repositoryRoot: built) != nil, "the checkout built has a tree the file could have named")
    }
}

private extension RunProgressTreeElsewhereTests {
    static func initialiseRepository(at url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "-q"]
        process.currentDirectoryURL = url
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, sourceLocation: sourceLocation)
    }
}
