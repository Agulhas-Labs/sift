//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// Three corners of the `PostToolUse` hook: a relative path that names no file under the working directory, diagnostics a Bash call printed on stderr, and the `digest` miss a Bash call reports.
@Suite(.temporaryDirectories)
struct DiagnosticNoteLowsTests {
    @Test func aRelativePathThatNamesNoFileUnderTheWorkingDirectoryFallsBackToTheSuffixMatch() throws {
        let tests = DiagnosticNoteTests()
        let printed = try tests.answer { DiagnosticNoteTests.bash("Gone/Orchard/Logic/Producer.swift:6:25: error: x", cwd: CanonicalPath.of($0) + "/Sources") }

        #expect(try DiagnosticNoteTests.context(of: printed) == DiagnosticNoteTests.expected)
    }

    @Test func diagnosticsOnABashCallsStderrAreLocated() throws {
        let tests = DiagnosticNoteTests()
        let printed = try tests.answer { cwd in
            ["tool_name": "Bash", "tool_input": ["command": "swiftc Producer.swift"], "tool_response": ["stdout": "", "stderr": "\(cwd)/\(DiagnosticNoteTests.producerPath):6:25: error: x"], "session_id": "s1", "cwd": cwd]
        }

        #expect(try DiagnosticNoteTests.context(of: printed) == DiagnosticNoteTests.expected)
    }

    /// Seeds `ledger` with the digest `command` asks for in a repository, then runs the hook on a Bash call answering with `stdout`.
    private func forgotten(command: String, stdout: String, ledger: AdviceLedger) throws -> (result: Bool, held: [String: Set<String>]) {
        let repo = try MCPTestRepo.make(declaring: "Gizmo")
        let payload: [String: Any] = [
            "tool_name": "Bash", "tool_input": ["command": command], "tool_response": ["stdout": stdout, "stderr": ""],
            "session_id": "s1", "cwd": repo.path,
        ]
        let asked = PreToolUseCommand.digestsAsked(toolName: "Bash", input: ["command": command], cwd: repo.path)
        let context = AdviceContext.resolve(sessionID: "s1", transcriptPath: nil, agentID: nil)
        ledger.noteIndexCall(session: context.key, digests: asked)
        let result = PostToolUseCommand.forgetMissedDigest(payload: payload, ledger: ledger)
        return (result, ledger.digests(session: context.key))
    }

    @Test func aBashDigestThatMissedIsForgotten() throws {
        let ledger = try AdviceLedger(directory: TemporaryDirectory.make("advice"))
        let outcome = try forgotten(command: "sift digest Depot", stdout: "no symbol named Depot in the index\n", ledger: ledger)

        #expect(outcome.result)
        #expect(outcome.held.values.allSatisfy { !$0.contains("Depot") })
    }

    @Test func aBashDigestThatServedIsKept() throws {
        let ledger = try AdviceLedger(directory: TemporaryDirectory.make("advice"))
        let outcome = try forgotten(command: "sift digest Gizmo", stdout: "Sources/App/Gizmo.swift\nstruct Gizmo\n", ledger: ledger)

        #expect(!outcome.result)
        #expect(outcome.held.values.contains { $0.contains("Gizmo") })
    }
}
