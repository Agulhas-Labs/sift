//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftCore
@testable import SiftMCP
import Testing

/// What the uninstall itself leaves behind or writes on the way out: the settings backup it makes, the line that removes the binary.
@Suite(.temporaryDirectories)
struct UninstallResidueTests {
    private typealias Fixture = UninstallCommandTests

    @Test
    func theSettingsBackupTheHooksStepWritesIsListedAndKeptWithoutPurge() throws {
        let installed = try Fixture.install()
        let backup = installed.settings.appendingPathExtension("bak-sift")

        let lines = try Fixture.uninstall(installed, remover: Fixture.ServerRemover())

        #expect(PathKind.of(backup) == .file)
        let listed = "backup: \(backup.path) — the settings as they were before this uninstall, sift's hooks included; `sift uninstall --purge` deletes it"
        #expect(lines.contains(listed), "\(lines)")
    }

    @Test
    func purgeDeletesTheBackupBesideTheSettingsFileItWasPointedAt() throws {
        let installed = try Fixture.install()
        let settings = installed.home.appendingPathComponent("elsewhere.json")
        try FileManager.default.moveItem(at: installed.settings, to: settings)
        let backup = settings.appendingPathExtension("bak-sift")

        let (lines, status) = try Fixture.exiting(installed, ["--purge", "--settings", settings.path], remover: Fixture.ServerRemover())

        #expect(status == 0)
        #expect(PathKind.of(backup) == .absent)
        #expect(lines.first == "uninstall: removed 9 registrations, purged 3 .sift directories, deleted the settings backup")
        #expect(lines.contains("backup: deleted \(backup.path)"), "\(lines)")
    }

    @Test
    func aBackupThatIsASymlinkIsRefusedAndKept() throws {
        let installed = try Fixture.install()
        let target = installed.home.appendingPathComponent("kept.json")
        try "{}".write(to: target, atomically: true, encoding: .utf8)
        let backup = installed.settings.appendingPathExtension("bak-sift")
        try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: target)

        let (lines, status) = try Fixture.exiting(installed, ["--purge"], remover: Fixture.ServerRemover())

        #expect(status == 1)
        #expect(PathKind.of(backup) == .symlink(target.path))
        #expect(lines.contains("not purged: \(backup.path) is a symlink to \(target.path), not a file — remove it by hand"), "\(lines)")
    }

    @Test
    func runByBareNameTheRemoveLineNamesTheBinaryPathFound() throws {
        let installed = try Fixture.install()
        let empty = installed.home.appendingPathComponent("empty")
        let bin = installed.home.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let binary = bin.appendingPathComponent(SiftPaths.binaryName)
        try "#!/bin/sh\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let lines = try Self.uninstall(installed, invokedAs: SiftPaths.binaryName, path: "\(empty.path):\(bin.path)")

        #expect(lines.last == "binary: rm \(binary.path) — a running binary does not delete itself")
    }

    @Test
    func runByABareNameNotOnPathTheRemoveLineNamesThisExecutable() throws {
        let installed = try Fixture.install()
        let executable = try #require(Bundle.main.executablePath)

        let lines = try Self.uninstall(installed, invokedAs: SiftPaths.binaryName, path: installed.home.path)

        #expect(lines.last == "binary: rm \(executable) — a running binary does not delete itself")
    }

    @Test
    func purgeLeavesTheRepositoryExcludeFileByteForByte() throws {
        let installed = try Fixture.install()
        try RunWithoutCommandTests.git(["init", "-q"], in: installed.recorded)
        let exclude = installed.recorded.appendingPathComponent(".git/info/exclude")
        let before = try? Data(contentsOf: exclude)

        let lines = try Fixture.uninstall(installed, ["--purge"], remover: Fixture.ServerRemover())

        #expect(lines.contains("purged: \(Fixture.cachePath(of: installed.recorded))"), "\(lines)")
        #expect((try? Data(contentsOf: exclude)) == before)
    }

    /// Climbs from the working directory into a scratch directory, so the relative root names a `.sift` this test owns.
    @Test
    func purgeSkipsARecordedRootThatIsNotAnAbsolutePath() throws {
        let installed = try Fixture.install()
        let elsewhere = try TemporaryDirectory.make("uninstall-relative").appendingPathComponent("other")
        let foreign = SiftPaths.cache(in: elsewhere).appendingPathComponent("other-tool.txt")
        try FileManager.default.createDirectory(at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "theirs".write(to: foreign, atomically: true, encoding: .utf8)
        let depth = FileManager.default.currentDirectoryPath.split(separator: "/").count
        let relative = String(repeating: "../", count: depth) + elsewhere.path.dropFirst()
        try #require(CanonicalPath.of(relative) == CanonicalPath.of(elsewhere.path))
        let registry = try JSONSerialization.data(withJSONObject: ["roots": [installed.recorded.path, relative]])
        try registry.write(to: RootsRegistry.fileURL(in: installed.siftHome))

        let lines = try Fixture.uninstall(installed, ["--purge"], remover: Fixture.ServerRemover())

        #expect(FileManager.default.fileExists(atPath: foreign.path))
        #expect(lines.contains("skipped: 1 recorded root is not an absolute path, so no .sift under it was looked for"), "\(lines)")
        #expect(lines.contains("purged: \(Fixture.cachePath(of: installed.recorded))"), "\(lines)")
    }

    /// The same climb, to a scratch directory whose `.mcp.json` registers this tool: a root skipped for the caches is skipped for the servers too, so the answer names no file under it and exits 0.
    @Test
    func aRecordedRootThatIsNotAnAbsolutePathNeverReachesAMcpJson() throws {
        let installed = try Fixture.install()
        let elsewhere = try TemporaryDirectory.make("uninstall-relative-mcp")
        let mcp = elsewhere.appendingPathComponent(".mcp.json")
        try #"{"mcpServers":{"sift":{"command":"sift","args":["mcp"]}}}"#.write(to: mcp, atomically: true, encoding: .utf8)
        let depth = FileManager.default.currentDirectoryPath.split(separator: "/").count
        let relative = String(repeating: "../", count: depth) + elsewhere.path.dropFirst()
        try #require(CanonicalPath.of(relative) == CanonicalPath.of(elsewhere.path))
        let registry = try JSONSerialization.data(withJSONObject: ["roots": [installed.recorded.path, relative]])
        try registry.write(to: RootsRegistry.fileURL(in: installed.siftHome))

        let (lines, status) = try Fixture.exiting(installed, remover: Fixture.ServerRemover())

        #expect(status == 0, "\(lines)")
        #expect(lines.contains("skipped: 1 recorded root is not an absolute path, so no .sift under it was looked for"), "\(lines)")
        #expect(lines.allSatisfy { !$0.contains(".mcp.json") }, "\(lines)")
    }

    private static func uninstall(_ installed: UninstallCommandTests.Installed, invokedAs name: String, path: String) throws -> [String] {
        let recorded = RecordedOutput()
        var command = try UninstallCommand.parse([])
        command.environment = installed.environment.merging(["PATH": path]) { $1 }
        command.arguments = [name, "uninstall"]
        command.output = recorded.output
        let remover = Fixture.ServerRemover()
        let config = installed.claudeConfig
        command.removeServer = { _, scope in remover.remove(from: config, scope: scope) }
        try command.run()
        return recorded.printed.split(separator: "\n").map(String.init)
    }
}
