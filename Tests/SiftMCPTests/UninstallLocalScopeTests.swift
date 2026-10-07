//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
@testable import SiftCore
@testable import SiftMCP
import Testing

/// The README's registration, `claude mcp add --scope local`, taken back out by the command that undoes it, run in the project's directory by a stand-in `claude` that logs how it was run.
@Suite(.temporaryDirectories)
struct UninstallLocalScopeTests {
    private typealias Fixture = UninstallCommandTests

    static var registration: [String: Any] {
        ["command": "npx", "args": ["--yes", "@agulhas-labs/sift", "mcp"]]
    }

    @Test
    func theReadmesLocalRegistrationIsRemovedFromItsProjectsDirectory() throws {
        let installed = try Fixture.install()
        let project = try Self.project()
        let claude = try Self.fakeClaude(installed, registering: [project], edits: true)

        let (lines, status) = try Self.uninstall(installed, bin: claude.bin)

        #expect(status == 0, "\(lines)")
        #expect(lines.contains("mcp: removed the local-scope server in \(project) — npx --yes @agulhas-labs/sift mcp"), "\(lines)")
        let projects = try #require(Fixture.object(at: installed.claudeConfig)["projects"] as? [String: Any])
        #expect(((projects[project] as? [String: Any])?["mcpServers"] as? [String: Any])?["sift"] == nil)
        let log = try String(contentsOf: claude.log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(log == ["mcp remove sift --scope local", project, installed.home.path], "\(log)")
    }

    @Test
    func aRemovalThatLeavesTheEntryIsCountedAsNotRemoved() throws {
        let installed = try Fixture.install()
        let project = try Self.project()
        let claude = try Self.fakeClaude(installed, registering: [project], edits: false)

        let (lines, status) = try Self.uninstall(installed, bin: claude.bin)

        #expect(status == 1, "\(lines)")
        #expect(lines.first?.hasPrefix("uninstall: 1 not removed") == true, "\(lines)")
        let still = "mcp: not removed — `claude mcp remove sift --scope local` run in \(project) succeeded and the server is still registered (\(installed.claudeConfig.path))"
        #expect(lines.contains(still), "\(lines)")
        #expect(FileManager.default.fileExists(atPath: claude.log.path))
    }

    /// A project path that goes through a link is not where Claude Code would look from, so no `claude` runs there and the entry is named with the edit that removes it.
    @Test
    func aProjectPathThroughASymlinkIsNamedAndNeverRunIn() throws {
        let installed = try Fixture.install()
        let real = try Self.project()
        let link = try CanonicalPath.of(TemporaryDirectory.make("uninstall-local-link").path) + "/project"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        let claude = try Self.fakeClaude(installed, registering: [link], edits: true)

        let (lines, status) = try Self.uninstall(installed, bin: claude.bin)

        #expect(status == 1, "\(lines)")
        #expect(!FileManager.default.fileExists(atPath: claude.log.path))
        let named = "mcp: not removed — the local-scope server in \(link) runs npx --yes @agulhas-labs/sift mcp; that path resolves to \(real), so `claude mcp remove sift --scope local` run there could reach another project's entry: remove projects[\"\(link)\"].mcpServers.sift from \(installed.claudeConfig.path) by hand"
        #expect(lines.contains(named), "\(lines)")
    }

    /// `claude` may find its project from `PWD` rather than the directory it runs in, so both name the project, never the directory this ran from.
    @Test
    func aLocalRemovalRunsInTheProjectWithPwdNamingIt() {
        let project = URL(fileURLWithPath: "/work/app", isDirectory: true)
        let environment = ["PWD": "/work/tool", "CFFIXED_USER_HOME": "/Users/dev", "PATH": "/bin"]

        let local = UninstallCommand.claudeInvocation(scope: .local(project), environment: environment)
        let user = UninstallCommand.claudeInvocation(scope: .user, environment: environment)

        #expect(local.directory == project)
        #expect(local.environment["PWD"] == "/work/app")
        #expect(local.environment["HOME"] == "/Users/dev")
        #expect(user.directory == nil)
        #expect(user.environment["PWD"] == "/work/tool")
    }
}

extension UninstallLocalScopeTests {
    /// A project directory, by its resolved path: the key Claude Code writes for a directory it was started in.
    static func project() throws -> String {
        try CanonicalPath.of(TemporaryDirectory.make("uninstall-local-project").path)
    }

    /// A config holding the README's registration in each of `projects` and no user-scope server, and a stand-in `claude` that logs its arguments, working directory and HOME, then, when it `edits`, replaces the config with one that no longer has those registrations.
    ///
    /// The paths it writes are spelled into the script, never read from its environment, so a wrong HOME can only show in the log.
    static func fakeClaude(_ installed: UninstallCommandTests.Installed, registering projects: [String], edits: Bool) throws -> (bin: URL, log: URL) {
        let scratch = try TemporaryDirectory.make("uninstall-fake-claude")
        let config: [String: Any] = ["mcpServers": [:], "projects": Dictionary(uniqueKeysWithValues: projects.map { ($0, ["mcpServers": ["sift": registration]]) })]
        try JSONSerialization.data(withJSONObject: config).write(to: installed.claudeConfig)
        let after = scratch.appendingPathComponent("after.json")
        if edits {
            let edited: [String: Any] = ["mcpServers": [:], "projects": Dictionary(uniqueKeysWithValues: projects.map { ($0, ["mcpServers": [:]]) })]
            try JSONSerialization.data(withJSONObject: edited).write(to: after)
        }
        let log = scratch.appendingPathComponent("claude.log")
        let bin = scratch.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" "$(pwd -P)" "$HOME" >> '\(log.path)'
        if [ -f '\(after.path)' ]; then /bin/cp '\(after.path)' '\(installed.claudeConfig.path)'; fi
        """
        let claude = bin.appendingPathComponent("claude")
        try (script + "\n").write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        return (bin, log)
    }

    /// The uninstall with the real `claude` runner and only `bin` on PATH, and the status it exits with.
    static func uninstall(_ installed: UninstallCommandTests.Installed, bin: URL) throws -> (lines: [String], status: Int32) {
        let recorded = RecordedOutput()
        var command = try UninstallCommand.parse([])
        command.environment = installed.environment.merging(["PATH": bin.path]) { $1 }
        command.arguments = ["sift", "uninstall"]
        command.output = recorded.output
        var status: Int32 = 0
        do {
            try command.run()
        } catch let exit as ExitCode {
            status = exit.rawValue
        }
        return (recorded.printed.split(separator: "\n").map(String.init), status)
    }
}
