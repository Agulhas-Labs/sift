//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// Covers what counts as this context taking the advice, and — the point of the whole change — that it is *this* context's.
///
/// The quiet rule promises the advice "goes quiet for a while only when a run of these draws no index call at all". It never comes due if the run can be cleared by another context: a subagent holding no MCP tools takes refusal after refusal, while the run that should quiet the hook is cleared over and over by its *parent's* index calls. A reset read off machine-wide log files has exactly that defect, because a log line records `tool`, `target` and `root` and no conversation identity. These pin the reset to the same context the counter is on.
@Suite(.temporaryDirectories)
struct AdviceComplianceTests {
    /// A call to this server's own tools is the advice being taken.
    @Test
    func anIndexCallIsRecognisedAsTheAdviceBeingTaken() {
        #expect(PreToolUseCommand.takesTheAdvice(command: nil, payload: ["tool_name": "mcp__sift__digest"]))
        #expect(PreToolUseCommand.takesTheAdvice(command: nil, payload: ["tool_name": "mcp__sift__where"]))
    }

    /// So is reaching for the tool in the shell, which is the only route left to a context an allowlist has stripped the MCP server from.
    ///
    /// `sift run --` is the wrapping the other advisor offers, and a bare `sift where` is the CLI face of the same answer. Both are the tool being used, and quieting a context for using it is the compliance-punishing shape this mechanism must never take.
    @Test
    func reachingForTheToolInTheShellCountsTheSameWay() {
        let wrapped = ["tool_name": "Bash", "tool_input": ["command": "sift run -- swift test"]] as [String: Any]
        let cli = ["tool_name": "Bash", "tool_input": ["command": "cd Tools && sift where SummaryState"]] as [String: Any]

        #expect(PreToolUseCommand.takesTheAdvice(command: nil, payload: wrapped))
        #expect(PreToolUseCommand.takesTheAdvice(command: nil, payload: cli))
    }

    /// The tool run inside a command substitution is the tool being used, at the hook, in the scan and to the advisor alike; spelled inside single quotes it is text, and runs nothing.
    @Test(arguments: [
        (#"echo "$(sift where SummaryState)""#, true),
        ("echo `sift digest SummaryState`", true),
        ("found=$(cd Tools && sift where SummaryState)", true),
        (#"grep -rn Foo Sources --include='*.swift' --exclude="$(sift where Foo | head -1)""#, true),
        ("echo '$(sift where SummaryState)'", false),
    ])
    func reachingForTheToolInASubstitutionCountsTheSameWay(command: String, runsTheTool: Bool) {
        let payload = ["tool_name": "Bash", "tool_input": ["command": command]] as [String: Any]
        var state = TranscriptScanState()
        let events = TranscriptScan.events(
            line: TranscriptFixture.toolUse("Bash", input: ["command": command]),
            state: &state,
            belowFloor: { _ in false },
            couldAnswer: { _, _ in true }
        )

        #expect(PreToolUseCommand.takesTheAdvice(command: nil, payload: payload) == runsTheTool)
        #expect(events.contains(.cliCall) == runsTheTool)
        if runsTheTool {
            #expect(ShellAdvice.suggestion(for: command) == nil)
        }
    }

    /// A search *for* the word is not a use of the tool, in the one repository where that is an easy mistake to make.
    @Test
    func namingTheToolIsNotUsingIt() {
        let search = ["tool_name": "Bash", "tool_input": ["command": "grep -rn sift Sources/"]] as [String: Any]
        let read = ["tool_name": "Read", "tool_input": ["file_path": "/repo/SummaryState.swift"]] as [String: Any]

        #expect(!PreToolUseCommand.takesTheAdvice(command: nil, payload: search))
        #expect(!PreToolUseCommand.takesTheAdvice(command: nil, payload: read))
    }
}
