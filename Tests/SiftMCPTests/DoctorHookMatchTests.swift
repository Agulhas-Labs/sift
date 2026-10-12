//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftCore
import Testing

/// Which hook commands `sift doctor` takes for sift's own when it looks for traces of an agent's install.
@Suite(.temporaryDirectories)
struct DoctorHookMatchTests {
    private static func hooks(command: String) throws -> Data {
        let object: [String: Any] = ["hooks": ["PreToolUse": [["hooks": [["type": "command", "command": command]]]]]]
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test
    func aCommandWhosePathMerelyContainsTheNameIsNotSifts() throws {
        try #expect(DoctorTraces.hooksHoldNothing(Self.hooks(command: "/Users/sifton/bin/lint.sh")))
    }

    @Test
    func theFormInstallHookWritesIsSifts() throws {
        let command = "\(ShellWord.quoted("/Users/me/Apps With Space/sift")) pre-tool-use"

        try #expect(!DoctorTraces.hooksHoldNothing(Self.hooks(command: command)))
    }

    @Test
    func anAbsolutePathToTheBinaryIsSifts() throws {
        try #expect(!DoctorTraces.hooksHoldNothing(Self.hooks(command: "/opt/x/bin/sift pre-tool-use --agent codex")))
    }

    @Test
    func aVersionPinnedNpxPackageIsSiftsAndALongerNameIsNot() throws {
        try #expect(!DoctorTraces.hooksHoldNothing(Self.hooks(command: "npx -y @agulhas-labs/sift@0.1.3 session-start")))
        try #expect(DoctorTraces.hooksHoldNothing(Self.hooks(command: "npx -y @agulhas-labs/sifton@0.1.3 session-start")))
    }

    @Test
    func aPathComponentOrAnArgumentNamedSiftIsNotTheProgram() throws {
        for command in ["cd ~/sift && make", "foo --name sift", "/opt/sift/bin/other pre-tool-use", "/opt/sift/bin/other hook"] {
            try #expect(DoctorTraces.hooksHoldNothing(Self.hooks(command: command)), "\(command)")
        }
    }

    @Test
    func theProgramWordIsReadAfterEnvironmentAssignmentsAndExec() throws {
        for command in ["/Users/x/.local/bin/sift stop", "SIFT_HOME=/tmp/h exec /Users/x/.local/bin/sift post-tool-use", "\"/path with space/sift\" session-start"] {
            try #expect(!DoctorTraces.hooksHoldNothing(Self.hooks(command: command)), "\(command)")
        }
    }

    @Test
    func theSiftBinaryRunningSomethingThatIsNoHookIsNotAHook() throws {
        try #expect(DoctorTraces.hooksHoldNothing(Self.hooks(command: "/Users/x/.local/bin/sift digest .")))
    }

    /// A binary named `sift` under a directory with a space in it, as an older install registered it without quoting.
    private static func withSpacedBinary(_ body: (_ binary: String, _ root: URL) throws -> Void) throws {
        let root = try TemporaryDirectory.make("doctor-hook-match")
        let directory = root.appendingPathComponent("My Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("sift")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try body(binary.path, root)
    }

    @Test
    func theUnquotedSpacedPathAnOlderInstallWroteIsSifts() throws {
        try Self.withSpacedBinary { binary, _ in
            for subcommand in ["pre-tool-use", "session-start"] {
                try #expect(!DoctorTraces.hooksHoldNothing(Self.hooks(command: "\(binary) \(subcommand)")), "\(subcommand)")
            }
        }
    }

    /// The same unquoted shape still counts once its binary is gone, the most broken trace a check for any trace must report.
    @Test
    func theUnquotedSpacedPathCountsAfterItsBinaryIsDeleted() throws {
        try Self.withSpacedBinary { binary, _ in
            try FileManager.default.removeItem(atPath: binary)
            for subcommand in ["pre-tool-use", "session-start"] {
                try #expect(!DoctorTraces.hooksHoldNothing(Self.hooks(command: "\(binary) \(subcommand)")), "\(subcommand)")
            }
            try #expect(DoctorTraces.hooksHoldNothing(Self.hooks(command: "\(binary) digest .")))
        }
    }

    @Test
    func claudeHoldingOnlyTheUnquotedSpacedPathHooksIsNotNothingOfSifts() throws {
        try Self.withSpacedBinary { binary, root in
            let events = HookRegistration.events
            var hooks: [String: Any] = [:]
            for event in events {
                hooks[event.name] = [["hooks": [["type": "command", "command": "\(binary) \(event.subcommand)"]]]]
            }
            let configuration = root.appendingPathComponent("claude", isDirectory: true)
            try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["hooks": hooks]).write(to: configuration.appendingPathComponent("settings.json"))
            let probe = try DoctorProbe(environment: [:])
            probe.close()

            let doctor = DoctorClaude(environment: ["CLAUDE_CONFIG_DIR": configuration.path], probe: probe)

            #expect(!doctor.hasNothingOfSift)
        }
    }
}
