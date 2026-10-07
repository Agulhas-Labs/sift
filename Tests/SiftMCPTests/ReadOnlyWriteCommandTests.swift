//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
@testable import SiftCore
import Testing

/// `init --write` and `run --without` in a tree nobody may write refuse in one line of their own, where each ended in the platform's words about a file it never needed to name.
@Suite(.temporaryDirectories)
struct ReadOnlyWriteCommandTests {
    @Test
    func initWriteRefusesInOneLineWhereTheConfigCannotBeSaved() throws {
        let repository = try MCPTestRepo.make()
        let engine = try SiftEngine(directory: repository)
        try Self.chmod("a-w", repository)
        defer { try? Self.chmod("a+w", repository) }

        let refusal = try #require(#expect(throws: EngineError.self) {
            try engine.initializeConfig(write: true, force: false)
        }).description
        let preview = try engine.initializeConfig(write: false, force: false)

        #expect(refusal.contains("cannot be written, so there is nowhere to save .sift.json"), "\(refusal)")
        #expect(!refusal.contains("\n"), "\(refusal)")
        #expect(!preview.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: SiftPaths.config(in: repository).path))
    }

    @Test
    func initWriteForceOverwritesAReadOnlyConfigInAWritableFolder() throws {
        let repository = try MCPTestRepo.make()
        let engine = try SiftEngine(directory: repository)
        let config = SiftPaths.config(in: repository)
        try Data("{}\n".utf8).write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: config.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config.path) }

        try TreeWritability.requireConfigFile(repoRoot: repository)
        _ = try engine.initializeConfig(write: true, force: true)

        #expect(try String(contentsOf: config, encoding: .utf8) != "{}\n")
    }

    @Test
    func initWriteForceRefusesInOneLineWhereTheFolderCannotBeWrittenEvenWithAWritableConfig() throws {
        let repository = try MCPTestRepo.make()
        let engine = try SiftEngine(directory: repository)
        let config = SiftPaths.config(in: repository)
        try Data("{}\n".utf8).write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: repository.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repository.path) }

        let refusal = try #require(#expect(throws: EngineError.self) {
            try engine.initializeConfig(write: true, force: true)
        }).description

        #expect(refusal.contains("cannot be written, so there is nowhere to save .sift.json"), "\(refusal)")
        #expect(!refusal.contains("\n"), "\(refusal)")
        #expect(try String(contentsOf: config, encoding: .utf8) == "{}\n")
    }

    @Test
    func runWithoutRefusesBeforeItLooksForASetAsideStoreItCannotMake() throws {
        let repository = try MCPTestRepo.make()
        try Self.chmod("a-w", repository)
        defer { try? Self.chmod("a+w", repository) }
        let command = RunWithoutCommand(
            arguments: ["swift", "test", "--filter", "Depot"],
            pathspecs: ["Sources"],
            line: nil,
            since: nil,
            runKey: { _ in nil },
            file: { _, _, _, _ in }
        )

        let refusal = #expect(throws: EngineError.self) {
            try TreeWritability.requireSetAsideStore(repoRoot: repository)
        }
        let exit = #expect(throws: ExitCode.self) {
            try command.run(in: repository)
        }

        #expect(refusal.map(String.init(describing:))?.contains("cannot be written, so there is nowhere to set the change aside") == true)
        #expect(exit?.rawValue == RunWithoutCommand.Exit.refused.rawValue)
        #expect(!FileManager.default.fileExists(atPath: SiftPaths.cache(in: repository).path))
    }

    /// `chmod -R <mode>` over `root`.
    private static func chmod(_ mode: String, _ root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["-R", mode, root.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
