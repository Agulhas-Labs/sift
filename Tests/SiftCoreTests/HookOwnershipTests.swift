//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// Covers which registered commands the install and the uninstall treat as this tool's own: every shape `install-hook` has written, and nothing whose path merely contains the name.
struct HookOwnershipTests {
    /// Every subcommand a registration runs: each hook event's, and the status line's.
    static let subcommands = Array(Set(HookRegistration.events.map(\.subcommand))).sorted() + ["statusline"]

    /// Whether the registration running `subcommand` would claim `command`.
    private static func claims(_ command: String, subcommand: String) -> Bool {
        subcommand == "statusline"
            ? StatuslineRegistration.isOurs(command)
            : HookRegistration.isOurs(command, subcommand: subcommand)
    }

    /// The binary at any path and under a directory with a space in it — unquoted, as the installer writes it, or quoted, as a `--command` may spell it — and bare on `PATH`, which only a hand-written `--command` spells (the installer always writes a path).
    @Test(arguments: subcommands)
    func everyShapeTheInstallerWritesIsRecognised(subcommand: String) throws {
        // The unquoted spaced shape is claimed only for a file that exists, so the path is a real one.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sift-ownership-\(UUID().uuidString)/My Tools")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let spaced = directory.appendingPathComponent("sift").path
        try Data().write(to: URL(fileURLWithPath: spaced))
        let executables = [
            "/opt/homebrew/bin/sift",
            "~/.local/bin/sift",
            "sift",
            spaced,
            "\"\(spaced)\"",
            "'\(spaced)'",
        ]
        for executable in executables {
            #expect(Self.claims("\(executable) \(subcommand)", subcommand: subcommand), "\(executable)")
        }
    }

    /// A path that contains the name, a binary merely named alike, anything after the subcommand, and a wrapper naming the binary as an argument are all someone else's.
    @Test(arguments: subcommands)
    func aCommandThatOnlyMentionsTheNameIsNotClaimed(subcommand: String) {
        let commands = [
            "/opt/siftscience/x \(subcommand)",
            "/opt/siftscience/sift-helper \(subcommand)",
            "/bin/sift \(subcommand)-extra",
            "/bin/sift \(subcommand) --verbose",
            "/usr/bin/env /x/sift \(subcommand)",
            "python3 tools/sift \(subcommand)",
            "bash ./hooks/sift \(subcommand)",
            " \(subcommand)",
            "/bin/sift",
        ]
        for command in commands {
            #expect(!Self.claims(command, subcommand: subcommand), "\(command)")
        }
    }

    /// An unquoted absolute path with a space in it is claimed only when a file is there: for a path that does not exist the words are a program and its argument.
    @Test(arguments: subcommands)
    func anUnquotedSpacedPathToNoFileIsNotClaimed(subcommand: String) {
        #expect(!Self.claims("/nonexistent-\(UUID().uuidString)/My Tools/sift \(subcommand)", subcommand: subcommand))
    }

    /// A subcommand that happens to appear in the path is not the one the command runs.
    @Test
    func aSubcommandInThePathIsNotTheOneRun() {
        #expect(!HookRegistration.isOurs("/Users/stopwatch/sift session-start", subcommand: "stop"))
        #expect(HookRegistration.isOurs("/Users/stopwatch/sift session-start", subcommand: "session-start"))
    }
}
