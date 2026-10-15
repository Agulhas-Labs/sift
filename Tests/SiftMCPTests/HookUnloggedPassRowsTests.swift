//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// Covers the suppression rows for the two passes that used to leave none: a Bash line that takes the advice and also reads a Swift file (`besideIndexCall`), and a window no index call located, let through as `noLookup` (`unlocatedWindow`).
@Suite(.temporaryDirectories) struct HookUnloggedPassRowsTests {
    private let file = "Sources/App/Alpha.swift"

    /// The hook deciding one Bash line, with a throwaway log of its own: the verdict and every rule it wrote.
    private func decide(_ command: String) throws -> (verdict: PreToolUseCommand.Verdict, rules: [String]) {
        let stores = try LocatedPassLogTests.Stores()
        let payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": command], "tool_use_id": "toolu_u1"]
        if PreToolUseCommand.takesTheAdvice(command: nil, payload: payload) {
            _ = UnloggedPassRows.takeTheAdvice(
                session: "s1",
                context: stores.context,
                payload: payload,
                cwd: stores.root.path,
                ledger: stores.ledger,
                callers: CallAttribution(directory: stores.suppressions.deletingLastPathComponent().appendingPathComponent("callers")),
                suppressions: SuppressionLog(fileURL: stores.suppressions)
            )
            return (PreToolUseCommand.Verdict(token: "allowed", rule: "adviceTaken"), LocatedPassLogTests.rules(in: stores.suppressions))
        }
        let decided = try PreToolUseCommand.decided(
            command: nil,
            payload: payload,
            cwd: stores.root.path,
            session: "s1",
            context: stores.context,
            answerer: InPlaceAnswerTests.scratchAnswerer(), ledger: stores.ledger,
            usage: UsageLog(fileURL: stores.usageLog),
            suppressions: stores.suppressions,
            couldAnswer: { _, _ in true }
        )
        return (decided.verdict, LocatedPassLogTests.rules(in: stores.suppressions))
    }

    /// A line that runs `sift` and also reads a Swift file is still taken as the advice, and writes one `besideIndexCall` row.
    @Test func aSiftLineThatAlsoReadsSwiftWritesABesideRow() throws {
        let judged = try decide("sift digest Ledger; cat \(file) | sed -n 1,60p; sift digest Other")

        #expect(judged.verdict.line == "allowed\t\tadviceTaken")
        #expect(judged.rules == ["besideIndexCall"])
    }

    /// A line of only index calls, or an index call beside a command that reads no Swift, writes nothing.
    @Test(arguments: ["sift digest Ledger; sift where Other", "sift digest Ledger; cat README.md", "sift digest Ledger && ls"])
    func aLineOfIndexCallsWritesNoRow(command: String) throws {
        #expect(try decide(command).rules.isEmpty)
    }

    /// A bare window of a Swift file no index call located is let through as `noLookup` and writes one `unlocatedWindow` row.
    @Test func anUnlocatedWindowWritesAnUnlocatedRow() throws {
        let judged = try decide("sed -n 10,40p \(file)")

        #expect(judged.verdict.line == "allowed\t\tnoLookup")
        #expect(judged.rules == ["unlocatedWindow"])
    }

    /// A heredoc script, an in-place edit and a command that reads nothing stay rowless.
    @Test(arguments: [
        "python3 - <<'EOF'\nprint(open('Sources/App/Alpha.swift').read())\nEOF",
        "sed -i '' 's/a/b/' Sources/App/Alpha.swift",
        "ls -la",
    ])
    func otherPassesStayRowless(command: String) throws {
        #expect(try decide(command).rules.isEmpty)
    }
}
