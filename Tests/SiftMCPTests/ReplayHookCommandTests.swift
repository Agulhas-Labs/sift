//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import Testing

/// `replay-hook --show` — the answer text a reviewer needs to check an answered window against the real command, beside the verdict `replay-hook` already prints.
@Suite(.temporaryDirectories) struct ReplayHookCommandTests {
    @Test func showPrintsTheAnswerAfterTheVerdict() async throws {
        let (status, output) = try await Self.replay(showing: true)

        #expect(status == 0)
        let lines = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first?.contains(#""hooked":true"#) == true, "\(output)")
        #expect(output.contains("--- answer ---"), "\(output)")
        #expect(output.contains("digest Sources/SiftCore/SiftPaths.swift"), "\(output)")
        #expect(output.contains("public struct SiftPaths"), "\(output)")
    }

    @Test func withoutShowOutputIsUnchanged() async throws {
        let (plainStatus, plainOutput) = try await Self.replay(showing: false)
        let (shownStatus, shownOutput) = try await Self.replay(showing: true)

        #expect(plainStatus == 0)
        #expect(shownStatus == 0)
        #expect(!plainOutput.contains("--- answer ---"), "\(plainOutput)")
        // The verdict line itself — everything `--show` adds is appended after it, never changing it.
        #expect(shownOutput.hasPrefix(plainOutput.trimmingCharacters(in: .newlines)), "plain: \(plainOutput) shown: \(shownOutput)")
    }

    /// The bytes after the marker must be the reason itself, not a re-rendering that merely happens to contain the same call and symbol — the failure a `.contains` pin would miss.
    @Test func showPrintsExactlyTheReasonTheLiveHookWouldWriteAsPermissionDecisionReason() async throws {
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-09-20T10:00:00Z"))
        let cwd = FileManager.default.currentDirectoryPath
        let command = "sed -n '30,150p' Sources/SiftCore/SiftPaths.swift"

        let groundTruthState = try TemporaryDirectory.make("ground-truth")
        let hook = HookReplay(directory: groundTruthState, timeBudget: InPlaceAnswerTests.roomy)
        let verdict = await InPlaceAnswerTests.onItsOwnThread {
            let payload: [String: Any] = ["session_id": "ground-truth", "tool_name": "Bash", "tool_input": ["command": command]]
            return hook.verdict(payload: payload, cwd: cwd, at: instant, decides: true)
        }
        let reason = try #require(verdict?.reason)

        let (status, output) = try await Self.replay(showing: true, label: "byte-for-byte", command: command, at: instant)

        #expect(status == 0)
        let marker = "--- answer ---\n"
        let afterMarker = try #require(output.range(of: marker), "\(output)")
        #expect(String(output[afterMarker.upperBound...]) == reason + "\n", "\(output)")
    }

    /// A bare toolchain command draws the wrapping's own refusal, `deny` rather than `in-place` — the path the two `.contains` tests never reach.
    @Test func aPlainDenyPrintsItsOwnAnswer() async throws {
        let (status, output) = try await Self.replay(showing: true, label: "plain-deny", command: "swift test")

        #expect(status == 0)
        let lines = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first?.contains(#""token":"deny""#) == true, "\(output)")
        #expect(output.contains("--- answer ---"), "\(output)")
        #expect(output.contains("sift run -- swift test"), "\(output)")
    }

    /// A verdict with nothing to show — an allowed call is never a lookup the hook judged — prints no marker at all, `--show` given or not.
    @Test func showOnAnAllowedVerdictPrintsNoMarker() async throws {
        let (status, output) = try await Self.replay(showing: true, label: "allowed", command: "echo hi")

        #expect(status == 0)
        #expect(!output.contains("--- answer ---"), "\(output)")
    }

    /// A call a rule withholds is written to `suppressions.jsonl` in the `--state` directory, so a probe can read which rule fired rather than the "(logged)" suffix alone.
    @Test func aWithheldCallIsWrittenToTheStateDirectorysSuppressionLog() async throws {
        let state = try TemporaryDirectory.make("Depot")

        let (status, _) = try await Self.replay(showing: false, label: "Depot", command: "xcodebuild build-for-testing -scheme Gizmo -derivedDataPath build", state: state)

        #expect(status == 0)
        let text = try String(contentsOf: state.appendingPathComponent("suppressions.jsonl"), encoding: .utf8)
        let rules = text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["rule"] as? String }
        #expect(rules == ["gateLeg"], "\(text)")
    }

    /// `--show` names nothing for `--answered` or `--located` to judge, so the pair is refused the way `audit --root --replay` is.
    @Test func showBesideAnsweredOrLocatedIsRefused() {
        #expect(throws: (any Error).self) {
            try ReplayHookCommand.parse(["--state", "/tmp/replay-state", "--cwd", "/tmp", "--show", "--answered"])
        }
        #expect(throws: (any Error).self) {
            try ReplayHookCommand.parse(["--state", "/tmp/replay-state", "--cwd", "/tmp", "--show", "--located", "Sources/SiftCore/SiftPaths.swift"])
        }
    }
}

private extension ReplayHookCommandTests {
    /// The verdict `replay-hook` gives for a cold window of this repository's own `SiftPaths.swift`, `--show` on or off, each against a state directory of its own so neither run's denial is read back as the other's identical re-run.
    static func replay(showing show: Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws -> (status: Int32, output: String) {
        try await replay(showing: show, label: show ? "shown" : "plain", command: "sed -n '30,150p' Sources/SiftCore/SiftPaths.swift", sourceLocation: sourceLocation)
    }

    /// The verdict `replay-hook` gives for one `command`, run from this repository's own working directory, against a state directory named for `label` so no two calls in the suite share one.
    static func replay(showing show: Bool, label: String, command: String, at instant: Date? = nil, state keptState: URL? = nil, sourceLocation: SourceLocation = #_sourceLocation) async throws -> (status: Int32, output: String) {
        let sift = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)", sourceLocation: sourceLocation)
        let cwd = FileManager.default.currentDirectoryPath
        let state = try keptState ?? TemporaryDirectory.make(label, sourceLocation: sourceLocation)
        let escapedCommand = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let payload = Data(#"{"session_id":"\#(label)","tool_name":"Bash","tool_input":{"command":"\#(escapedCommand)"}}"#.utf8)

        return await InPlaceAnswerTests.onItsOwnThread {
            let process = Process()
            process.executableURL = sift
            // The child's budget is the roomy one too: a loaded machine must not turn the verdict `overTime` in either process.
            var arguments = ["replay-hook", "--state", state.path, "--cwd", cwd, "--time-budget", String(InPlaceAnswerTests.roomy)]
            if let instant {
                arguments.append(contentsOf: ["--at", String(instant.timeIntervalSince1970)])
            }
            if show {
                arguments.append("--show")
            }
            process.arguments = arguments
            // The user's own Claude Code settings decide whether a build is rewritten or refused, so the child reads an empty configuration instead.
            var environment = ProcessInfo.processInfo.environment
            environment["CLAUDE_CONFIG_DIR"] = state.appendingPathComponent("claude").path
            environment["CLAUDE_PROJECT_DIR"] = nil
            process.environment = environment
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return (Int32(-1), "") }
            try? input.fileHandleForWriting.write(contentsOf: payload)
            try? input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(bytes: data, encoding: .utf8) ?? "")
        }
    }
}
