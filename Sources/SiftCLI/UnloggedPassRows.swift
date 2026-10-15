//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import SiftMCP

/// The suppression rows for the two passes the hook lets through without judging them.
struct UnloggedPassRows {
    /// The advice-taken branch of the hook's `run`: ``PreToolUseCommand/adviceTaken(session:context:payload:command:cwd:serverDirectory:ledger:callers:)``, then the `besideIndexCall` row, answering what the hook should print.
    ///
    /// One function so that a test exercises the call `run` makes, with the three logs it writes injected.
    static func takeTheAdvice(
        session: String,
        context: AdviceContext,
        payload: [String: Any],
        command: String? = nil,
        cwd directory: String?,
        serverDirectory: String? = nil,
        ledger: AdviceLedger = .standard(),
        callers: CallAttribution = .standard(),
        suppressions: SuppressionLog = .standard()
    ) -> String? {
        let output = PreToolUseCommand.adviceTaken(
            session: session, context: context, payload: payload, command: command, cwd: directory, serverDirectory: serverDirectory, ledger: ledger, callers: callers
        )
        noteBesideIndexCall(command: command, payload: payload, in: directory, noting: suppressions)
        return output
    }

    /// Notes a Bash line that takes the advice and also reads a Swift file (`besideIndexCall`).
    ///
    /// The hook lets such a line through whole and never judges it leg by leg; the pass is deliberate, and this is only the row that lets the audit see it. Nothing else about the call changes.
    static func noteBesideIndexCall(command: String?, payload: [String: Any], in directory: String?, noting suppressions: SuppressionLog) {
        guard let shell = PreToolUseCommand.shellText(command: command, payload: payload), ShellInspection.isSwiftLookup(shell, in: directory) else { return }
        suppressions.note(symbol: nil, directory: directory, rule: "besideIndexCall", call: payload["tool_use_id"] as? String)
    }

    /// Notes a Swift window no index call located, let through as `noLookup` (`unlocatedWindow`), written through a log of its own so the verdict stays `noLookup`.
    ///
    /// Called only where no gate noted a rule, so nothing else logged this call; `holds` says whether this context wrote the file. Rowless on purpose: a window of a file this context wrote, a heredoc script, an in-place edit and a command that reads nothing stay rowless.
    static func noteUnlocatedWindow(
        of lookup: PreToolUseCommand.Lookup?,
        command: String?,
        payload: [String: Any],
        in directory: String?,
        holds: (String) -> Bool,
        noting suppressions: SuppressionLog
    ) {
        var paths: [String]
        if let lookup {
            guard lookup.isWindow || !lookup.windowPaths.isEmpty else { return }
            paths = lookup.readPaths(from: directory)
        } else if let shell = PreToolUseCommand.shellText(command: command, payload: payload),
                  let path = ShellInspection.windowedReadPath(shell, in: directory)
        {
            paths = SwiftTree.resolve(path, relativeTo: directory).map { [$0] } ?? [path]
        } else {
            return
        }
        paths = paths.filter { $0.hasSuffix(".swift") && !holds($0) }
        guard !paths.isEmpty else { return }
        suppressions.note(symbol: nil, directory: directory, rule: "unlocatedWindow", call: payload["tool_use_id"] as? String)
    }
}
