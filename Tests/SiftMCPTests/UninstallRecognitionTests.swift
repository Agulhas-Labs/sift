//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftCore
@testable import SiftMCP
import Testing

/// What `sift uninstall` recognises as this tool's own: the MCP registrations the README and `install.sh` make, at every scope Claude Code reads.
@Suite(.temporaryDirectories)
struct UninstallRecognitionTests {
    private typealias Fixture = UninstallCommandTests

    private static var package: String {
        "@agulhas-labs/sift"
    }

    /// The README's registration run at user scope, and the same with `--yes` and a pinned version, is this tool's and is taken out.
    @Test(arguments: [["-y", package, "mcp"], ["--yes", "\(package)@1.2.0", "mcp"], [package, "mcp"]])
    func theNpxRegistrationTheReadmeGivesIsRemovedAtUserScope(arguments: [String]) throws {
        let installed = try Self.installed(user: ["command": "npx", "args": arguments])
        let remover = Fixture.ServerRemover()

        let (lines, status) = try Fixture.exiting(installed, remover: remover)

        #expect(remover.calls == 1)
        #expect(status == 0, "\(lines)")
        #expect(lines.contains("mcp: removed the user-scope server — npx \(arguments.joined(separator: " "))"), "\(lines)")
    }

    /// Another package whose name starts with this one's, this package run as a CLI, or other arguments are not this tool's server.
    @Test(arguments: [["-y", "\(package)-darwin-arm64", "mcp"], ["-y", package], ["-y", package, "mcp", "serve"], ["-y", "other", "mcp"]])
    func anNpxServerThatIsNotThisPackagesMcpIsLeftAlone(arguments: [String]) throws {
        let installed = try Self.installed(user: ["command": "npx", "args": arguments])
        let remover = Fixture.ServerRemover()

        let lines = try Fixture.uninstall(installed, remover: remover)

        #expect(remover.calls == 0)
        #expect(lines.contains("mcp: the user-scope server named sift runs npx \(arguments.joined(separator: " ")), not a registration sift recognises — left alone"), "\(lines)")
    }

    /// A local-scope registration can only be removed from its project's directory, so this tool's in a project that is not on this machine is named with the edit that removes it and counted as not removed, and someone else's is named and left.
    @Test
    func aLocalScopeRegistrationWhoseProjectIsGoneIsCountedAsNotRemoved() throws {
        let installed = try Fixture.install()
        try Self.writeConfig(installed, user: ["command": "/bin/sift", "args": ["mcp"]], projects: [
            "/work/app": ["mcpServers": ["sift": ["command": "npx", "args": ["-y", Self.package, "mcp"]]]],
            "/work/tool": ["mcpServers": ["sift": ["command": "sift", "args": ["mcp"]]]],
            "/work/other": ["mcpServers": ["sift": ["command": "/opt/siftscience/bin/mcp-server", "args": ["mcp"]]]],
        ])
        let remover = Fixture.ServerRemover()

        let (lines, status) = try Fixture.exiting(installed, remover: remover)

        #expect(status == 1)
        #expect(remover.calls == 1)
        #expect(lines.first?.hasPrefix("uninstall: 2 not removed, ") == true, "\(lines)")
        let gone = "is not a directory here, so `claude mcp remove sift --scope local` cannot be run from it"
        let config = installed.claudeConfig.path
        #expect(lines.contains("mcp: not removed — the local-scope server in /work/app runs npx -y \(Self.package) mcp; /work/app \(gone): remove projects[\"/work/app\"].mcpServers.sift from \(config) by hand"), "\(lines)")
        #expect(lines.contains("mcp: not removed — the local-scope server in /work/tool runs sift mcp; /work/tool \(gone): remove projects[\"/work/tool\"].mcpServers.sift from \(config) by hand"), "\(lines)")
        #expect(lines.contains("mcp: the local-scope server named sift in /work/other runs /opt/siftscience/bin/mcp-server mcp, not a registration sift recognises — left alone"), "\(lines)")
    }

    /// A recorded repository's `.mcp.json` is that repository's file, shared with everyone who clones it: this tool's server there is named and counted, and the file is never written.
    @Test
    func aProjectMcpFileNamingThisToolIsNamedAndNeverEdited() throws {
        let installed = try Fixture.install()
        let file = installed.uncached.appendingPathComponent(".mcp.json")
        let contents = Data(#"{"mcpServers":{"sift":{"command":"npx","args":["-y","@agulhas-labs/sift","mcp"]}}}"#.utf8)
        try contents.write(to: file)
        let path = URL(fileURLWithPath: CanonicalPath.of(installed.uncached.path)).appendingPathComponent(".mcp.json").path

        let (lines, status) = try Fixture.exiting(installed, remover: Fixture.ServerRemover())

        #expect(status == 1)
        #expect(lines.contains("mcp: not removed — \(path) registers sift (npx -y \(Self.package) mcp) for everyone who opens that repository; it is the repository's own file, so remove its sift entry by hand"), "\(lines)")
        #expect(try Data(contentsOf: file) == contents)
    }

    /// Homebrew's link on PATH, run by bare name: an `rm` of the link would leave the Cellar copy and brew's record of it.
    @Test
    func aBinaryHomebrewLinkedIsRemovedWithBrew() throws {
        let installed = try Fixture.install()
        let cellar = try Self.executable(at: "Cellar/sift/1.0/bin/sift", in: installed.home)
        let bin = installed.home.appendingPathComponent("brewbin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("sift").path, withDestinationPath: "../Cellar/sift/1.0/bin/sift")

        let lines = try Self.uninstall(installed, invokedAs: SiftPaths.binaryName, path: bin.path)

        #expect(lines.last == "binary: brew uninstall sift — \(CanonicalPath.of(cellar.path)) is in Homebrew's Cellar")
    }

    /// The binary npm's launcher spawns, by its full path: from a global install, a project's own `node_modules`, and npx's cache.
    @Test
    func aBinaryNpmInstalledIsRemovedWithNpm() throws {
        let installed = try Fixture.install()
        let platform = "node_modules/@agulhas-labs/sift-darwin-arm64/bin/sift"
        let global = try Self.executable(at: "prefix/lib/\(platform)", in: installed.home)
        let local = try Self.executable(at: "app/\(platform)", in: installed.home)
        let cached = try Self.executable(at: ".npm/_npx/0a1b2c/\(platform)", in: installed.home)
        let home = CanonicalPath.of(installed.home.path)

        let lines = try [global, local, cached].map { try Self.uninstall(installed, invokedAs: $0.path, path: "").last }

        #expect(lines == [
            "binary: npm uninstall -g \(Self.package) — \(home)/prefix/lib/\(platform) is in npm's global packages under \(home)/prefix/lib",
            "binary: npm uninstall \(Self.package), run in \(home)/app — \(home)/app/\(platform) is in that project's node_modules",
            "binary: \(home)/.npm/_npx/0a1b2c/\(platform) is npx's cached copy of \(Self.package), which npx fetches again when next run; deleting \(home)/.npm/_npx/0a1b2c drops it",
        ])
    }

    /// A link into a checkout's build is someone's build, not a package: the `rm` names the link, as found.
    @Test
    func aBinaryLinkedIntoACheckoutKeepsTheRmOfTheLink() throws {
        let installed = try Fixture.install()
        let built = try Self.executable(at: "checkout/.build/release/sift", in: installed.home)
        let bin = installed.home.appendingPathComponent("local-bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("sift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: built)

        let lines = try Self.uninstall(installed, invokedAs: SiftPaths.binaryName, path: bin.path)

        #expect(lines.last == "binary: rm \(link.path) — a running binary does not delete itself")
    }

    /// A directory named `claude` on PATH is not `claude`: running it could only fail, and the answer would blame the removal.
    @Test
    func aDirectoryNamedClaudeOnPathIsNotClaude() throws {
        let scratch = try TemporaryDirectory.make("uninstall-claude-dir")
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("claude"), withIntermediateDirectories: true)

        let removal = UninstallCommand.claudeRemovesServer(environment: ["PATH": scratch.path, "CFFIXED_USER_HOME": scratch.path], scope: .user)

        #expect(removal == .noClaude)
    }

    /// A relative PATH entry resolves against wherever this process happens to be, so a `claude` found through one is never run.
    @Test
    func aClaudeOnlyOnARelativePathEntryIsNeverRun() throws {
        let scratch = try TemporaryDirectory.make("uninstall-claude-relative")
        let log = scratch.appendingPathComponent("claude.log")
        let claude = try Self.executable(at: "bin/claude", in: scratch)
        try "#!/bin/sh\necho ran > '\(log.path)'\n".write(to: claude, atomically: false, encoding: .utf8)
        let depth = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).pathComponents.count - 1
        let relative = String(repeating: "../", count: depth) + String(claude.deletingLastPathComponent().path.dropFirst())

        let removal = UninstallCommand.claudeRemovesServer(environment: ["PATH": relative, "CFFIXED_USER_HOME": scratch.path], scope: .user)

        #expect(removal == .noClaude)
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }
}

private extension UninstallRecognitionTests {
    static func installed(user: [String: Any]) throws -> UninstallCommandTests.Installed {
        let installed = try Fixture.install()
        try writeConfig(installed, user: user)
        return installed
    }

    /// Replaces the fixture's `.claude.json` with one holding `user` as the user-scope `sift` server and `projects` as the per-project entries.
    static func writeConfig(_ installed: UninstallCommandTests.Installed, user: [String: Any], projects: [String: Any] = [:]) throws {
        let config: [String: Any] = ["mcpServers": ["sift": user], "projects": projects]
        try JSONSerialization.data(withJSONObject: config).write(to: installed.claudeConfig)
    }

    /// An executable file at `relative` under `root`, with its directories.
    static func executable(at relative: String, in root: URL) throws -> URL {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    /// The uninstall as started by `name` with `path` as PATH, answering what it printed.
    static func uninstall(_ installed: UninstallCommandTests.Installed, invokedAs name: String, path: String) throws -> [String] {
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
