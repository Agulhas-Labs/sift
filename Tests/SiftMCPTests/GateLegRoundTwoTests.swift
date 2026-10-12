//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// Covers a split gate whose `test-without-building` leg is reached through a wrapper — `xcrun`, `env`, `time` — still making the line a gate script.
///
/// The `build-for-testing` beside such a leg is the other half of the gate and stays unwrapped, logged as `gateLeg`, as it is when both legs are written bare.
@Suite(.temporaryDirectories)
struct GateLegRoundTwoTests {
    /// A wrapped second leg makes the line a gate script: no wrapping on either half, and the withholding recorded under the gate-leg rule.
    @Test(arguments: [
        "xcodebuild build-for-testing -scheme GK && xcrun xcodebuild test-without-building -scheme GK",
        "xcodebuild build-for-testing -scheme GK && env FOO=1 xcodebuild test-without-building -scheme GK",
        "xcodebuild build-for-testing -scheme GK && time xcodebuild test-without-building -scheme GK",
        "xcodebuild build-for-testing -scheme GK; /usr/bin/env xcrun xcodebuild test-without-building -scheme GK",
    ])
    func aWrappedTestWithoutBuildingLegStillMakesASplitGate(line: String) {
        #expect(RunAdvice.suggestion(for: line) == nil)
        #expect(RunAdvice.wrappedLegs(of: line).isEmpty)
        #expect(RunAdvice.silencedAsAGateLeg(line))
    }

    /// The hook stays silent on such a line and logs `gateLeg`.
    @Test
    func theHookLogsAWrappedSplitGateAsAGateLeg() throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }
        let gate = "xcodebuild build-for-testing -scheme GK && xcrun xcodebuild test-without-building -scheme GK"
        let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": gate]]

        #expect(PreToolUseCommand.lookup(command: nil, payload: payload, noting: recording.log, couldAnswer: { _, _ in true }) == nil)
        #expect(recording.rules == ["gateLeg"])
    }

    /// A wrapper running some other tool is not a gate leg, so a lone `build-for-testing` beside it is still wrapped.
    @Test
    func aWrapperRunningAnotherToolLeavesALoneBuildForTestingWrapped() {
        let line = "xcodebuild build-for-testing -scheme GK && xcrun simctl list devices"

        #expect(RunAdvice.suggestion(for: line)?.call == "sift run -- xcodebuild build-for-testing -scheme GK && xcrun simctl list devices")
        #expect(!RunAdvice.silencedAsAGateLeg(line))
    }
}
