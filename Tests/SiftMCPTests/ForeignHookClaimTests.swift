//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// Covers the settings file end to end: a hook or status line whose path merely contains the tool's name is someone else's, and both `install-hook` and `uninstall-hook` leave it where it is, while every registration the installer has written is still found and removed.
@Suite(.temporaryDirectories)
struct ForeignHookClaimTests {
    private static var foreignPrimer: String {
        "/opt/siftscience/x session-start"
    }

    private static var foreignAdvice: String {
        "/opt/siftscience/x pre-tool-use"
    }

    private static var foreignStatusline: String {
        "/opt/siftscience/x statusline"
    }

    /// The `PreToolUse` matcher the install writes, so a foreign hook under it sits in the entry the install merges into.
    private static let adviceMatcher = HookRegistration.events.first { $0.subcommand == "pre-tool-use" }?.matchers.first ?? "(none)"

    /// A settings file holding only the foreign registrations: a primer, an advice hook under the install's own matcher, and the status line.
    private static func foreignSettings() -> [String: Any] {
        [
            "hooks": [
                "SessionStart": [["hooks": [["type": "command", "command": foreignPrimer]]]],
                "PreToolUse": [["matcher": adviceMatcher, "hooks": [["type": "command", "command": foreignAdvice]]]],
            ],
            "statusLine": ["type": "command", "command": foreignStatusline],
        ]
    }

    private static func object(at url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
            sourceLocation: sourceLocation
        )
    }

    /// Every hook command registered for `event`, across its entries.
    private static func commands(_ event: String, in settings: [String: Any]) -> [String] {
        let entries = (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return entries.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    private static func statusline(in settings: [String: Any]) -> String? {
        (settings["statusLine"] as? [String: Any])?["command"] as? String
    }

    /// The uninstall takes this tool's registrations out of a file that also holds foreign ones with the name in their path, and leaves the foreign ones exactly as they were.
    @Test
    func uninstallLeavesAForeignHookAndStatusLineWithTheNameInTheirPath() throws {
        let settings = try TemporaryDirectory.make("foreign-claim").appendingPathComponent("settings.json")
        var current: Data? = try JSONSerialization.data(withJSONObject: Self.foreignSettings())
        for event in HookRegistration.events {
            current = try HookRegistration.apply(
                to: current,
                command: "/bin/sift \(event.subcommand)",
                event: event.name,
                subcommand: event.subcommand,
                matchers: event.matchers,
                timeout: event.timeout
            ).data
        }
        try #require(current).write(to: settings)
        #expect(try Self.commands("PreToolUse", in: Self.object(at: settings)).contains("/bin/sift pre-tool-use"))

        try UninstallHookCommand.parse(["--settings", settings.path]).run()

        let after = try Self.object(at: settings)
        #expect(Self.commands("SessionStart", in: after) == [Self.foreignPrimer])
        #expect(Self.commands("PreToolUse", in: after) == [Self.foreignAdvice])
        #expect(Self.commands("SubagentStart", in: after).isEmpty)
        #expect(Self.commands("Stop", in: after).isEmpty)
        #expect(Self.statusline(in: after) == Self.foreignStatusline)
    }

    /// A re-run of the install adds its own hook beside a foreign one under the same matcher rather than repointing it, and leaves a status-line slot a foreign command holds without a word about it.
    @Test
    func installLeavesAForeignHookAndStatusLineWithTheNameInTheirPath() throws {
        let settings = try TemporaryDirectory.make("foreign-claim").appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: Self.foreignSettings()).write(to: settings)

        var command = try InstallHookCommand.parse(["--settings", settings.path, "--no-allow-run"])
        let recorded = RecordedOutput()
        command.output = recorded.output
        try command.run()

        let after = try Self.object(at: settings)
        let entries = (after["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] ?? []
        let merged = try #require(entries.first { $0["matcher"] as? String == Self.adviceMatcher })
        let inner = (merged["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }

        #expect(inner.first == Self.foreignAdvice)
        #expect(inner.count == 2)
        #expect(inner.last?.hasSuffix(" pre-tool-use") == true)
        #expect(Self.commands("SessionStart", in: after).first == Self.foreignPrimer)
        #expect(Self.commands("SessionStart", in: after).count == 1 + HookRegistration.defaultMatchers.count)
        #expect(Self.statusline(in: after) == Self.foreignStatusline)
        #expect(!recorded.printed.contains("replaced stale registration"))
        #expect(!recorded.printed.contains("statusline"), "\(recorded.printed)")
    }

    /// Every executable spelling a registration can carry — any path, a directory with a space in it (unquoted, as the installer writes it, or quoted by a `--command`), and bare on `PATH` (only a hand-written `--command`; the installer always writes a path) — is still found and removed whole by the uninstall.
    @Test(arguments: [
        "/Users/me/.local/bin/sift",
        "/Users/me/My Tools/sift",
        "\"/Users/me/My Tools/sift\"",
        "'/Users/me/My Tools/sift'",
        "sift",
    ])
    func everyInstalledShapeIsRemovedWhole(executable written: String) throws {
        let scratch = try TemporaryDirectory.make("foreign-claim")
        // The unquoted spaced shape is claimed only for a file that exists, so the example path is made real.
        let spaced = scratch.appendingPathComponent("My Tools/sift")
        try FileManager.default.createDirectory(at: spaced.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: spaced)
        let executable = written.replacingOccurrences(of: "/Users/me/My Tools/sift", with: spaced.path)
        let settings = scratch.appendingPathComponent("settings.json")
        var current: Data?
        for event in HookRegistration.events {
            current = try HookRegistration.apply(
                to: current,
                command: "\(executable) \(event.subcommand)",
                event: event.name,
                subcommand: event.subcommand,
                matchers: event.matchers,
                timeout: event.timeout
            ).data
        }
        try LegacyStatusLine.adding(command: "\(executable) statusline", to: current).write(to: settings)

        try UninstallHookCommand.parse(["--settings", settings.path]).run()

        #expect(try Self.object(at: settings).isEmpty)
    }

    /// What `--only-advice` leaves behind is still this tool's: a full uninstall afterwards takes the primer, the gate and the status line too.
    @Test
    func aFullUninstallAfterOnlyAdviceTakesTheRest() throws {
        let settings = try TemporaryDirectory.make("foreign-claim").appendingPathComponent("settings.json")
        var current: Data?
        for event in HookRegistration.events {
            current = try HookRegistration.apply(
                to: current,
                command: "/bin/sift \(event.subcommand)",
                event: event.name,
                subcommand: event.subcommand,
                matchers: event.matchers,
                timeout: event.timeout
            ).data
        }
        try LegacyStatusLine.adding(command: "/bin/sift statusline", to: current).write(to: settings)

        try UninstallHookCommand.parse(["--settings", settings.path, "--only-advice"]).run()
        #expect(try Set(Self.commands("SessionStart", in: Self.object(at: settings))) == ["/bin/sift session-start"])
        try UninstallHookCommand.parse(["--settings", settings.path]).run()

        #expect(try Self.object(at: settings).isEmpty)
    }
}
