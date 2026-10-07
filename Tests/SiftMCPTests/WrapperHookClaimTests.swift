//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// A hook whose first shell word is another program is that program's, however the tool's binary appears later in the command: `uninstall-hook` leaves it in place, and still removes the commands `install-hook` writes, a quoted path with spaces in it included.
@Suite(.temporaryDirectories)
struct WrapperHookClaimTests {
    private static let wrappers = [
        "\"/opt/wrap\" \"/x/sift\" pre-tool-use",
        "python3 tools/sift pre-tool-use",
        "/opt/wrap '/x/sift' pre-tool-use",
        "env FOO=1 /x/sift pre-tool-use",
    ]

    /// The first word is read as a shell reads it, so a quoted wrapper is not mistaken for the quoted binary.
    @Test(arguments: wrappers)
    func aCommandWhoseFirstWordIsAnotherProgramIsNotClaimed(command: String) {
        #expect(!HookRegistration.isOurs(command, subcommand: "pre-tool-use"))
    }

    /// Quoting, escapes and a quote that joins words are read as one first word.
    @Test(arguments: [
        "\"/x/sift\" pre-tool-use",
        "'/x/My Tools/sift' pre-tool-use",
        "/x/My\\ Tools/sift pre-tool-use",
        "'/x/it'\\''s/sift' pre-tool-use",
        "\"/x/My Tools\"/sift pre-tool-use",
    ])
    func aQuotedFirstWordIsReadWhole(command: String) {
        #expect(HookRegistration.isOurs(command, subcommand: "pre-tool-use"))
    }

    @Test
    func uninstallLeavesWrapperHooksAndRemovesTheToolsOwn() throws {
        let settings = try TemporaryDirectory.make("wrapper-claim").appendingPathComponent("settings.json")
        let matcher = HookRegistration.events.first { $0.subcommand == "pre-tool-use" }?.matchers.first ?? "(none)"
        let foreign = Self.wrappers.map { ["type": "command", "command": $0] }
        var current: Data? = try JSONSerialization.data(withJSONObject: [
            "hooks": ["PreToolUse": [["matcher": matcher, "hooks": foreign]]],
        ])
        for event in HookRegistration.events {
            current = try HookRegistration.apply(
                to: current,
                command: "\(ShellWord.quoted("/Users/me/My Tools/sift")) \(event.subcommand)",
                event: event.name,
                subcommand: event.subcommand,
                matchers: event.matchers,
                timeout: event.timeout
            ).data
        }
        try #require(current).write(to: settings)

        try UninstallHookCommand.parse(["--settings", settings.path]).run()

        let after = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        let hooks = try #require(after["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == ["PreToolUse"])
        let entries = try #require(hooks["PreToolUse"] as? [[String: Any]])
        let commands = entries.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        #expect(commands == Self.wrappers)
    }
}
