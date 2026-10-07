//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftCore
import Testing

/// A `settings.json` that is a symlink into a dotfiles repository is written through by `install-hook`, `uninstall-hook` and `uninstall`: the link stays a link, the dotfiles file is the one that changes, and its backup sits beside it.
@Suite(.temporaryDirectories)
struct SymlinkedSettingsTests {
    /// The link as a dotfiles manager writes one, relative to its own directory.
    private static var destination: String {
        "../dotfiles/settings.json"
    }

    @Test
    func installAndUninstallChangeTheFileTheLinkLeadsToAndKeepTheLink() throws {
        let (link, target) = try Self.linkedSettings(#"{"theme":"dark"}"#)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)

        let printed = try Self.install(link)

        #expect(PathKind.of(link) == .symlink(Self.destination))
        let installed = try Self.object(at: target)
        #expect(installed["theme"] as? String == "dark")
        let hooks = try #require(installed["hooks"] as? [String: Any])
        #expect(Set(hooks.keys).isSuperset(of: ["SessionStart", "PreToolUse", "PostToolUse", "Stop"]))
        #expect(try Self.mode(of: target) == 0o600)
        #expect(try Data(contentsOf: Self.backup(beside: target)) == Data(#"{"theme":"dark"}"#.utf8))
        #expect(!FileManager.default.fileExists(atPath: Self.backup(beside: link).path))
        #expect(printed.contains("      \(link.path) → "), "\(printed)")
        #expect(printed.contains("dotfiles/settings.json\n"), "\(printed)")

        let outcome = try HookUninstall.run(settings: link, onlyAdvice: false)

        #expect(outcome.changed)
        #expect(PathKind.of(link) == .symlink(Self.destination))
        let uninstalled = try Self.object(at: target)
        #expect(uninstalled["theme"] as? String == "dark")
        #expect((uninstalled["hooks"] as? [String: Any])?.values.contains { ($0 as? [Any])?.isEmpty == false } != true, "\(uninstalled)")
        #expect(try Self.mode(of: target) == 0o600)
        #expect(try Self.object(at: Self.backup(beside: target))["hooks"] != nil)
        #expect(!FileManager.default.fileExists(atPath: Self.backup(beside: link).path))
    }

    /// `sift uninstall --settings` takes the hooks out of the file the link leads to, and finds the backup beside that file, where `--purge` deletes it.
    @Test(arguments: [false, true])
    func uninstallThroughALinkRemovesTheHooksFromItsTarget(purge: Bool) throws {
        let installed = try UninstallCommandTests.install()
        let target = installed.home.appendingPathComponent("dotfiles/settings.json")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: installed.settings, to: target)
        try FileManager.default.createSymbolicLink(atPath: installed.settings.path, withDestinationPath: Self.destination)
        let link = installed.settings

        let (lines, status) = try UninstallCommandTests.exiting(
            installed,
            ["--settings", link.path] + (purge ? ["--purge"] : []),
            remover: UninstallCommandTests.ServerRemover()
        )

        #expect(status == 0, "\(lines)")
        #expect(lines.first?.hasPrefix("uninstall: removed 9 registrations") == true, "\(lines)")
        #expect(PathKind.of(link) == .symlink(Self.destination))
        let settings = try UninstallCommandTests.object(at: target)
        #expect(settings["statusLine"] == nil)
        #expect(settings["theme"] as? String == "dark")
        let hooks = try #require(settings["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == ["PreToolUse"])
        #expect(lines.contains { $0.hasPrefix("      \(link.path) → ") && $0.hasSuffix("dotfiles/settings.json") }, "\(lines)")
        #expect(FileManager.default.fileExists(atPath: Self.backup(beside: target).path) == !purge)
        #expect(!FileManager.default.fileExists(atPath: Self.backup(beside: link).path))
    }

    /// A link that leads to nothing is refused before anything is written: the link stays, and nothing appears at its destination or beside it.
    @Test
    func aDanglingLinkIsRefusedByInstallAndNamedByUninstall() throws {
        let (link, target) = try Self.linkedSettings(nil)

        #expect {
            try Self.install(link)
        } throws: { error in
            InstallHookCommand.message(for: error).contains("\(link.path) is a symlink to \(Self.destination), which leads to nothing")
        }

        #expect(PathKind.of(link) == .symlink(Self.destination))
        #expect(PathKind.of(target) == .absent)
        #expect(PathKind.of(Self.backup(beside: link)) == .absent)
        #expect {
            try HookUninstall.run(settings: link, onlyAdvice: false)
        } throws: { error in
            "\(error)" == "hooks: not checked — \(link.path) could not be read: a symlink to \(Self.destination), which leads to nothing"
        }
        #expect(PathKind.of(link) == .symlink(Self.destination))
    }

    /// Where the file the link leads to cannot be replaced, the install fails and changes nothing, rather than replacing the link with a copy.
    @Test
    func aTargetDirectoryThatCannotBeWrittenFailsTheInstallAndKeepsTheLink() throws {
        let (link, target) = try Self.linkedSettings(#"{"theme":"dark"}"#)
        let directory = target.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        #expect {
            try Self.install(link)
        } throws: { error in
            let message = InstallHookCommand.message(for: error)
            return message.hasPrefix("\(link.path) → ") && message.contains("dotfiles/settings.json could not be rewritten: ") && !message.contains("Domain=")
        }

        #expect(PathKind.of(link) == .symlink(Self.destination))
        #expect(try Data(contentsOf: target) == Data(#"{"theme":"dark"}"#.utf8))
    }
}

extension SymlinkedSettingsTests {
    /// `sift uninstall` that cannot rewrite the file the link leads to counts it as not removed, naming the link and its target, and leaves both as they were.
    @Test
    func uninstallThatCannotRewriteTheTargetSaysSoAndKeepsTheLink() throws {
        let installed = try UninstallCommandTests.install()
        let target = installed.home.appendingPathComponent("dotfiles/settings.json")
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: installed.settings, to: target)
        try FileManager.default.createSymbolicLink(atPath: installed.settings.path, withDestinationPath: Self.destination)
        let before = try Data(contentsOf: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        let (lines, status) = try UninstallCommandTests.exiting(
            installed,
            ["--settings", installed.settings.path],
            remover: UninstallCommandTests.ServerRemover()
        )

        #expect(status == 1, "\(lines)")
        let note = lines.first { $0.hasPrefix("hooks: not removed — \(installed.settings.path) → ") }
        #expect(note?.contains("dotfiles/settings.json: ") == true, "\(lines)")
        #expect(note?.contains("Domain=") == false, "\(lines)")
        #expect(PathKind.of(installed.settings) == .symlink(Self.destination))
        #expect(try Data(contentsOf: target) == before)
    }
}

private extension SymlinkedSettingsTests {
    /// A `claude/settings.json` linked to `dotfiles/settings.json` in one scratch directory, holding `contents` or nothing at all.
    static func linkedSettings(_ contents: String?) throws -> (link: URL, target: URL) {
        let root = try TemporaryDirectory.make("linked-settings")
        let link = root.appendingPathComponent("claude/settings.json")
        let target = root.appendingPathComponent("dotfiles/settings.json")
        for directory in [link, target] {
            try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        if let contents {
            try Data(contents.utf8).write(to: target)
        }
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
        return (link, target)
    }

    /// Runs `install-hook` against `settings` without the allow rules, and returns what it printed.
    @discardableResult
    static func install(_ settings: URL) throws -> String {
        var command = try InstallHookCommand.parse(["--settings", settings.path, "--no-allow-run"])
        // Registered as a binary named `sift`, which is what the uninstall recognises as this tool's.
        command.arguments = ["/bin/sift", "install-hook"]
        command.executable = "/bin/sift"
        let recorded = RecordedOutput()
        command.output = recorded.output
        try command.run()
        return recorded.printed
    }

    static func object(at url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], sourceLocation: sourceLocation)
    }

    static func backup(beside settings: URL) -> URL {
        settings.appendingPathExtension("bak-sift")
    }

    static func mode(of url: URL) throws -> Int? {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }
}
