//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers how `sift install` hears its children: `claude mcp add` and `codex mcp` are started without the terminal, and what they say when they fail reaches the reader with its cause.
struct InstallSpawnTests {
    /// A spawned child reads the null device, never the terminal `sift install` asked its questions on.
    ///
    /// Handed that terminal, `claude mcp add` was stopped on touching it and ended at its 60-second deadline, where run by hand it took under a second.
    @Test
    func aSpawnedChildReadsTheNullDevice() {
        let process = SimulatorAccessibility.process("/bin/sh", ["-c", "true"], in: nil, environment: nil)

        #expect((process.standardInput as? FileHandle) === FileHandle.nullDevice)
    }

    /// A `codex` failure with a `Caused by:` chain is reported with that chain, not only the line above it.
    @Test
    func aFailuresCauseComesWithIt() {
        let said = """
        Error: failed to load configuration

        Caused by:
            Your access token could not be refreshed because your refresh token was revoked. Please log out and sign in again.

        """
        let output = SimulatorAccessibility.Output(succeeded: false, standardOutput: "", standardError: said)

        #expect(CodexMcpServer.failureReason(of: output) == "Error: failed to load configuration: Your access token could not be refreshed because your refresh token was revoked. Please log out and sign in again.")
    }

    /// A failure without a chain is its first line, and one that said nothing says so.
    @Test
    func aFailureWithoutACauseIsItsFirstLine() {
        let plain = SimulatorAccessibility.Output(succeeded: false, standardOutput: "", standardError: "No MCP server named sift\nmore\n")
        let silent = SimulatorAccessibility.Output(succeeded: false, standardOutput: "", standardError: "")

        #expect(CodexMcpServer.failureReason(of: plain) == "No MCP server named sift")
        #expect(CodexMcpServer.failureReason(of: silent) == "no output")
    }
}
