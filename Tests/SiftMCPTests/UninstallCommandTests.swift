//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
@testable import SiftCore
@testable import SiftMCP
import Testing

/// `sift uninstall` run against a scratch home holding a whole installation: settings, the MCP server, the rule, and caches in repositories the logs name.
@Suite(.temporaryDirectories)
struct UninstallCommandTests {
    private static var foreignHook: String {
        #"{"matcher":"Write","hooks":[{"type":"command","command":"~/.claude/protect.sh"}]}"#
    }

    static func install(serverCommand: String = "/bin/sift") throws -> Installed {
        let home = try TemporaryDirectory.make("uninstall-home")
        let repositories = try TemporaryDirectory.make("uninstall-repos")
        let installed = Installed(
            home: home,
            recorded: repositories.appendingPathComponent("recorded"),
            logged: repositories.appendingPathComponent("logged"),
            uncached: repositories.appendingPathComponent("uncached")
        )
        let manager = FileManager.default
        try manager.createDirectory(at: installed.rule.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createDirectory(at: installed.siftHome, withIntermediateDirectories: true)

        var settings = Data(#"{"theme":"dark","hooks":{"PreToolUse":[\#(foreignHook)]}}"#.utf8)
        for event in HookRegistration.events {
            settings = try HookRegistration.apply(
                to: settings,
                command: "/bin/sift \(event.subcommand)",
                event: event.name,
                subcommand: event.subcommand,
                matchers: event.matchers
            ).data
        }
        try LegacyStatusLine.adding(command: "/bin/sift statusline", to: settings).write(to: installed.settings)

        let config = #"{"mcpServers":{"sift":{"type":"stdio","command":"\#(serverCommand)","args":["mcp"]},"other":{"type":"stdio","command":"/bin/other","args":[]}},"theme":"dark"}"#
        try config.write(to: installed.claudeConfig, atomically: true, encoding: .utf8)
        try "rule".write(to: installed.rule, atomically: true, encoding: .utf8)
        try "kept".write(to: installed.rule.deletingLastPathComponent().appendingPathComponent("other.md"), atomically: true, encoding: .utf8)

        for repository in [installed.recorded, installed.logged, installed.uncached] {
            try manager.createDirectory(at: repository, withIntermediateDirectories: true)
            try "source".write(to: repository.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        }
        for repository in [installed.recorded, installed.logged] {
            let cache = SiftPaths.cache(in: repository)
            try manager.createDirectory(at: cache.appendingPathComponent("runs"), withIntermediateDirectories: true)
            try "index".write(to: cache.appendingPathComponent(SiftPaths.indexFileName), atomically: true, encoding: .utf8)
        }
        let registry = try JSONSerialization.data(withJSONObject: ["roots": [installed.recorded.path, installed.uncached.path]])
        try registry.write(to: RootsRegistry.fileURL(in: installed.siftHome))
        let usage = #"{"ts":"2026-01-01T00:00:00Z","tool":"digest","root":"\#(installed.logged.path)"}"# + "\n"
        try usage.write(to: installed.siftHome.appendingPathComponent("usage.jsonl"), atomically: true, encoding: .utf8)
        return installed
    }

    static func uninstall(
        _ installed: Installed,
        _ arguments: [String] = [],
        remover: ServerRemover
    ) throws -> [String] {
        try exiting(installed, arguments, remover: remover).lines
    }

    /// The same run, with the status it exits with: the exit code the command throws, or 0 when it throws none.
    static func exiting(
        _ installed: Installed,
        _ arguments: [String] = [],
        remover: ServerRemover
    ) throws -> (lines: [String], status: Int32) {
        let recorded = RecordedOutput()
        var command = try UninstallCommand.parse(arguments)
        command.environment = installed.environment
        command.output = recorded.output
        let config = installed.claudeConfig
        command.removeServer = { _, scope in remover.remove(from: config, scope: scope) }
        var status: Int32 = 0
        do {
            try command.run()
        } catch let exit as ExitCode {
            status = exit.rawValue
        }
        return (recorded.printed.split(separator: "\n").map(String.init), status)
    }

    static func object(at url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], sourceLocation: sourceLocation)
    }

    static func cachePath(of repository: URL) -> String {
        SiftPaths.cache(in: URL(fileURLWithPath: CanonicalPath.of(repository.path))).path
    }

    @Test
    func everythingTheInstallWroteGoesAndEverythingElseStays() throws {
        let installed = try Self.install()
        let remover = ServerRemover()

        let (lines, status) = try Self.exiting(installed, remover: remover)

        #expect(status == 0)
        #expect(lines.first == "uninstall: removed 9 registrations")
        let settings = try Self.object(at: installed.settings)
        #expect(settings["statusLine"] == nil)
        #expect(settings["theme"] as? String == "dark")
        let hooks = try #require(settings["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == ["PreToolUse"])
        #expect((hooks["PreToolUse"] as? [Any])?.count == 1)

        #expect(remover.calls == 1)
        let config = try Self.object(at: installed.claudeConfig)
        #expect((config["mcpServers"] as? [String: Any])?.keys.sorted() == ["other"])
        #expect(lines.contains("mcp: removed the user-scope server — /bin/sift mcp"))

        #expect(FileManager.default.fileExists(atPath: installed.rule.path) == false)
        #expect(FileManager.default.fileExists(atPath: installed.rule.deletingLastPathComponent().appendingPathComponent("other.md").path))
        #expect(lines.contains("rule: removed \(installed.rule.path)"))

        #expect(lines.last?.hasPrefix("binary: rm ") == true)
    }

    @Test
    func withoutPurgeEveryCacheIsListedAndNoneIsDeleted() throws {
        let installed = try Self.install()

        let lines = try Self.uninstall(installed, remover: ServerRemover())

        let left = lines.filter { $0.hasPrefix("left: ") }
        #expect(left == [
            "left: \(Self.cachePath(of: installed.logged))",
            "left: \(Self.cachePath(of: installed.recorded))",
            "left: \(installed.siftHome.path)",
        ])
        for repository in [installed.recorded, installed.logged] {
            #expect(FileManager.default.fileExists(atPath: SiftPaths.cache(in: repository).appendingPathComponent(SiftPaths.indexFileName).path))
        }
        #expect(FileManager.default.fileExists(atPath: RootsRegistry.fileURL(in: installed.siftHome).path))
        #expect(lines.contains { $0.hasPrefix("purged: ") } == false)
    }

    @Test
    func aSecondRunHasNothingToDoAndChangesNothing() throws {
        let installed = try Self.install()
        let remover = ServerRemover()
        _ = try Self.uninstall(installed, remover: remover)
        let settings = try Data(contentsOf: installed.settings)
        let config = try Data(contentsOf: installed.claudeConfig)

        let lines = try Self.uninstall(installed, remover: remover)

        #expect(lines.first == "uninstall: nothing to do")
        #expect(remover.calls == 1)
        #expect(try Data(contentsOf: installed.settings) == settings)
        #expect(try Data(contentsOf: installed.claudeConfig) == config)
        #expect(lines.contains { $0.hasPrefix("hook: ") || $0.hasPrefix("mcp: ") || $0.hasPrefix("rule: ") } == false)
    }

    @Test
    func purgeDeletesEveryListedCacheAndLeavesTheRepositories() throws {
        let installed = try Self.install()

        let lines = try Self.uninstall(installed, ["--purge"], remover: ServerRemover())

        #expect(lines.first == "uninstall: removed 9 registrations, purged 3 .sift directories, deleted the settings backup")
        #expect(lines.filter { $0.hasPrefix("purged: ") } == [
            "purged: \(Self.cachePath(of: installed.logged))",
            "purged: \(Self.cachePath(of: installed.recorded))",
            "purged: \(installed.siftHome.path)",
        ])
        for repository in [installed.recorded, installed.logged, installed.uncached] {
            #expect(FileManager.default.fileExists(atPath: SiftPaths.cache(in: repository).path) == false)
            #expect(FileManager.default.fileExists(atPath: repository.appendingPathComponent("main.swift").path))
        }
        #expect(FileManager.default.fileExists(atPath: installed.siftHome.path) == false)

        let again = try Self.uninstall(installed, ["--purge"], remover: ServerRemover())
        #expect(again.first == "uninstall: nothing to do")
        #expect(again.contains { $0.hasPrefix("purged: ") || $0.hasPrefix("left: ") } == false)
    }

    @Test
    func aServerNamedSiftThatRunsSomethingElseIsLeftAlone() throws {
        let installed = try Self.install(serverCommand: "/opt/tools/serve")
        let remover = ServerRemover()

        let lines = try Self.uninstall(installed, remover: remover)

        #expect(remover.calls == 0)
        #expect(try (Self.object(at: installed.claudeConfig)["mcpServers"] as? [String: Any])?["sift"] != nil)
        #expect(lines.contains("mcp: the user-scope server named sift runs /opt/tools/serve mcp, not a registration sift recognises — left alone"))
    }

    @Test
    func aServerThatCouldNotBeRemovedIsCountedAndTheCommandNamed() throws {
        let installed = try Self.install()

        let (lines, status) = try Self.exiting(installed, remover: ServerRemover(result: .noClaude))

        #expect(status == 1)
        #expect(lines.first == "uninstall: 1 not removed, removed 8 registrations")
        #expect(lines.contains("mcp: not removed — `claude` is not on PATH; run: claude mcp remove sift --scope user"))
    }

    @Test
    func aRuleThatIsASymlinkIsLeftWhereItIs() throws {
        let installed = try Self.install()
        let target = installed.home.appendingPathComponent("checkout.md")
        try FileManager.default.moveItem(at: installed.rule, to: target)
        try FileManager.default.createSymbolicLink(at: installed.rule, withDestinationURL: target)

        let lines = try Self.uninstall(installed, remover: ServerRemover())

        #expect(lines.contains("rule: \(installed.rule.path) is a symlink to \(target.path) — left as is"))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: installed.rule.path)) == target.path)
    }

    /// The logs' own fallback follows the home the environment names, so an environment with a scratch home and no log override never reaches the real `~/.sift`.
    @Test
    func theLogsFollowTheHomeTheEnvironmentNames() throws {
        let home = try TemporaryDirectory.make("uninstall-logs")
        let environment = ["CFFIXED_USER_HOME": home.path]

        #expect(UsageLog.standardFileURL(environment: environment).path == home.appendingPathComponent(".sift/usage.jsonl").path)
        #expect(RunUsageLog.standardFileURL(environment: environment).path == home.appendingPathComponent(".sift/run.jsonl").path)
    }
}

extension UninstallCommandTests {
    /// A home with everything `install.sh` leaves in it, beside things it did not write that must survive.
    struct Installed {
        let home: URL
        let recorded: URL
        let logged: URL
        let uncached: URL

        var settings: URL {
            home.appendingPathComponent(".claude/settings.json")
        }

        var claudeConfig: URL {
            home.appendingPathComponent(".claude.json")
        }

        var rule: URL {
            home.appendingPathComponent(".claude/rules/sift.md")
        }

        var siftHome: URL {
            home.appendingPathComponent(".sift")
        }

        /// Every per-user path pointed into the scratch home, the log overrides included, so no run can reach the real `~/.sift`.
        var environment: [String: String] {
            [
                "CFFIXED_USER_HOME": home.path,
                "SIFT_USAGE_LOG": siftHome.appendingPathComponent("usage.jsonl").path,
                "SIFT_RUN_LOG": siftHome.appendingPathComponent("run.jsonl").path,
            ]
        }
    }

    /// Counts the calls to take a server out, and takes it out of the scratch config the way `claude mcp remove` would: at user scope from `mcpServers`, at local scope from that project's entry and nowhere else.
    final class ServerRemover: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let result: SiftUninstall.ServerRemoval

        init(result: SiftUninstall.ServerRemoval = .removed) {
            self.result = result
        }

        var calls: Int {
            lock.withLock { count }
        }

        func remove(from config: URL, scope: SiftUninstall.ServerScope) -> SiftUninstall.ServerRemoval {
            lock.withLock { count += 1 }
            guard result == .removed,
                  var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: config))) as? [String: Any]
            else {
                return result
            }
            switch scope {
            case .user:
                var servers = object["mcpServers"] as? [String: Any] ?? [:]
                servers.removeValue(forKey: "sift")
                object["mcpServers"] = servers
            case let .local(project):
                var projects = object["projects"] as? [String: Any] ?? [:]
                var entry = projects[project.path] as? [String: Any] ?? [:]
                var servers = entry["mcpServers"] as? [String: Any] ?? [:]
                servers.removeValue(forKey: "sift")
                entry["mcpServers"] = servers
                projects[project.path] = entry
                object["projects"] = projects
            }
            try? JSONSerialization.data(withJSONObject: object).write(to: config)
            return result
        }
    }
}
