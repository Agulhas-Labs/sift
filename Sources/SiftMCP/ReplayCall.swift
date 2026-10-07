//
// Copyright © Agulhas Labs
//

import Foundation

/// One recorded call as the harness would have handed it to the hook, or with no `cwd` where the directory it runs in is not on disk now.
///
/// **A shell command that opens by moving runs in the directory it moves to**, so a `cd` to a path gone from disk (a sibling clone since deleted) is judged no more than a call whose own working directory is gone: judged from the cwd it left, it would read as a lookup in no repository. A relative target is resolved against the mapped cwd first, since that is the directory the shell would have resolved it from.
///
/// **A `Read`/`Grep`/`Glob` pointed at an absolute path whose directory is gone is the same withholding**, one argument earlier: nothing about the call's own cwd says so, so this is the one place that path is read at all.
struct ReplayCall {
    let payload: [String: Any]
    let cwd: String?

    init(block: [String: Any], line: [String: Any], identity: ReplayIdentity, origins: WorktreeOrigins, prompt: LatestPrompt? = nil, permissionMode: String? = nil, contextTokens: Int? = nil) {
        // Mapped whatever the cwd is: a worktree the cwd itself never mentions can still be a path an argument
        // names — a `Read` of a file under `.claude/worktrees/<name>` from a session whose cwd is the repository.
        var input = (block["input"] as? [String: Any] ?? [:]).mapValues { value -> Any in
            guard let text = value as? String else { return value }
            return origins.mapping(in: text)
        }
        let mappedCWD = (line["cwd"] as? String).map(origins.mapping(directory:))
        var isDirectory: ObjCBool = false
        let exists = mappedCWD.map { FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) } ?? false
        let moved = (input["command"] as? String).flatMap(InPlaceShape.firstChangeOfDirectory(inShell:))
        var resolvedMove = moved.flatMap { candidate -> String? in
            guard !candidate.hasPrefix("/") else { return candidate }
            return mappedCWD.map { URL(fileURLWithPath: candidate, relativeTo: URL(fileURLWithPath: $0)).standardizedFileURL.path }
        }
        // A move into a gone worktree itself is written onto the repository it was cut from, so the hook reads the command where that worktree's files are now.
        if let target = moved, let gone = resolvedMove, !Self.isDirectory(gone), case let onto = origins.mapping(directory: gone), Self.isDirectory(onto),
           let command = input["command"] as? String, let opening = ShellSyntax.statementRanges(of: command).first,
           let written = command.range(of: target, range: opening.range)
        {
            input["command"] = command.replacingCharacters(in: written, with: onto)
            resolvedMove = onto
        }
        let movesNowhere = resolvedMove.map { !Self.isDirectory($0) } ?? false
        let namedPath = LookupTool.rule(for: block["name"] as? String ?? "").flatMap { rule -> String? in
            rule == "Read" ? LookupTool.readPath(in: input) : (input["path"] as? String)
        }
        let namedPathGone = namedPath.map { $0.hasPrefix("/") && !Self.isDirectory(($0 as NSString).deletingLastPathComponent) } ?? false
        cwd = exists && isDirectory.boolValue && !movesNowhere && !namedPathGone ? mappedCWD : nil
        var payload: [String: Any] = [
            "tool_name": block["name"] as? String ?? "",
            "tool_input": input,
            "session_id": line["sessionId"] as? String ?? identity.fallbackSession,
            "transcript_path": identity.sessionTranscript,
            // Moved off a gone worktree as the call's own paths are, so a path the prompt names still names the file the call reads.
            TranscriptReplay.promptKey: prompt.map {
                LatestPrompt(text: origins.mapping(in: $0.text), cwd: $0.cwd.map(origins.mapping(directory:))).payloadValue
            } ?? [String: String](),
            // The size of the context as of the call, 0 where none has been read yet: the hook reads the key rather than the transcript's last line.
            ContextSize.replayKey: contextTokens ?? 0,
        ]
        if let cwd {
            payload["cwd"] = cwd
        }
        if let permissionMode {
            payload["permission_mode"] = permissionMode
        }
        // Only a subagent's transcript speaks for an agent; the session's own lines are the session's.
        if let fallback = identity.fallbackAgent {
            payload["agent_id"] = (line["agentId"] as? String) ?? fallback
        }
        self.payload = payload
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
