//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import Testing

/// `ExternalReplayHook.isSupported`: a binary predating `replay-hook` answers an unknown subcommand's `--help` with the root command's own help, at exit 0, so the probe must not trust `--help` alone.
@Suite(.temporaryDirectories) struct ReplayHookProbeTests {
    /// A binary with no `replay-hook` entry point, whose `anything --help` prints root-style help at exit 0 exactly as the deployed binary's `scan-dump --help` was observed to, is judged unsupported.
    @Test func aBinaryThatAnswersAnyHelpAtExitZeroIsNotSupported() throws {
        let stub = try Self.script(#"""
        case " $* " in *" --help "*) echo "USAGE: sift <subcommand>"; exit 0 ;; esac
        cat > /dev/null
        exit 1
        """#)

        #expect(!ExternalReplayHook.isSupported(by: stub, within: 5))
    }

    /// `audit --replay --against` a binary judged unsupported prints the one-line refusal, not `failedRule` verdicts for every call.
    @Test func anAgainstBinaryWithNoReplayHookIsRefused() async throws {
        let sift = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)")
        let stub = try Self.script(#"""
        case " $* " in *" --help "*) echo "USAGE: sift <subcommand>"; exit 0 ;; esac
        cat > /dev/null
        exit 1
        """#)
        let scratch = try TemporaryDirectory.make("unsupported-against")
        let projects = scratch.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let transcript = projects.appendingPathComponent("replayed-session.jsonl")
        let lines = try [TranscriptAuditReplayTests.call("echo one", id: "c1", cwd: scratch.path, at: "2026-09-20T10:00:00Z")]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)

        let (status, errors) = await InPlaceAnswerTests.onItsOwnThread {
            let process = Process()
            process.executableURL = sift
            process.arguments = ["audit", "--replay", "--projects", projects.path, "--transcript", transcript.path, "--against", stub.path]
            let errors = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            guard (try? process.run()) != nil else { return (Int32(-1), "") }
            let text = String(bytes: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            return (process.terminationStatus, text)
        }

        #expect(status != 0 && status != -1, "audit exited \(status)")
        #expect(errors.contains("has no replay-hook entry point"), "\(errors)")
        #expect(!errors.contains("unanswered"), "\(errors)")
    }

    /// A stand-in for a sift binary that runs `body` for every request, whatever it asks.
    private static func script(_ body: String) throws -> URL {
        let script = try TemporaryDirectory.make("hook-probe-stub").appendingPathComponent("sift")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}
