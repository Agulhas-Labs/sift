//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// Covers `xcodebuild build-for-testing` drawing the `sift run --` wrapping when nothing on its line runs the other half of a split gate.
///
/// In a package that builds only for a simulator, `build-for-testing` is the everyday build, and leaving it raw cost a whole build log for a green build. `test-without-building`, and a line running both actions, stay gate legs.
@Suite(.temporaryDirectories)
struct BuildForTestingWrapTests {
    private static var build: String {
        "xcodebuild build-for-testing -scheme GizmoKit-Package -destination 'platform=iOS Simulator,name=iPhone 17'"
    }

    /// A `build-for-testing` alone is wrapped where it stands, like any other build, and is not recorded as a gate leg.
    @Test
    func aLoneBuildForTestingIsWrapped() {
        #expect(RunAdvice.suggestion(for: Self.build)?.call == "sift run -- " + Self.build)
        #expect(RunAdvice.wrappedLegs(of: Self.build) == ["sift run -- " + Self.build])
        #expect(!RunAdvice.silencedAsAGateLeg(Self.build))
        #expect(
            RunAdvice.suggestion(for: "cd Kit && xcodebuild build-for-testing -scheme Gizmo -derivedDataPath build")?.call
                == "cd Kit && sift run -- xcodebuild build-for-testing -scheme Gizmo -derivedDataPath build"
        )
    }

    /// `test-without-building` alone stays a gate leg: no wrapping, and the withholding is recorded under that rule.
    @Test
    func aLoneTestWithoutBuildingIsNotWrapped() {
        let run = "xcodebuild test-without-building -scheme Gizmo -derivedDataPath build"

        #expect(RunAdvice.suggestion(for: run) == nil)
        #expect(RunAdvice.silencedAsAGateLeg(run))
    }

    /// A line running both actions is a gate script, whether they share one invocation or are chained, and `build-for-testing` on it stays a leg.
    @Test(arguments: [
        "xcodebuild build-for-testing -scheme Gizmo && xcodebuild test-without-building -scheme Gizmo",
        "xcodebuild build-for-testing -scheme Gizmo; xcodebuild test-without-building -scheme Gizmo",
        "xcodebuild -scheme Gizmo build-for-testing test-without-building",
    ])
    func aLineRunningBothActionsIsNotWrapped(line: String) {
        #expect(RunAdvice.suggestion(for: line) == nil)
        #expect(RunAdvice.wrappedLegs(of: line).isEmpty)
        #expect(RunAdvice.silencedAsAGateLeg(line))
    }

    /// A lone `build-for-testing` sent to a log of its own is withheld by the redirect rule, as any build is.
    @Test
    func aLoneBuildForTestingRedirectedToAFileIsNotWrapped() {
        let redirected = Self.build + " > build.log"

        #expect(RunAdvice.suggestion(for: redirected) == nil)
        #expect(RunAdvice.silencedAsAGateLeg(redirected))
    }

    /// The hook answers a lone `build-for-testing` with the wrapping and logs nothing, and still logs `gateLeg` for a line running both actions.
    @Test
    func theHookWrapsALoneBuildForTestingAndStillLogsASplitGate() throws {
        let recording = try AdviceAgreementTests.Recording()
        defer { recording.cleanup() }
        let shell: (String) -> [String: Any] = { command in ["tool_name": "Bash", "tool_input": ["command": command]] }

        let lookup = PreToolUseCommand.lookup(command: nil, payload: shell(Self.build), noting: recording.log, couldAnswer: { _, _ in true })
        #expect(lookup?.suggestion.calls == ["sift run -- " + Self.build])
        #expect(recording.rules.isEmpty)

        let gate = "xcodebuild build-for-testing -scheme Gizmo && xcodebuild test-without-building -scheme Gizmo"
        #expect(PreToolUseCommand.lookup(command: nil, payload: shell(gate), noting: recording.log, couldAnswer: { _, _ in true }) == nil)
        #expect(recording.rules == ["gateLeg"])
    }
}
