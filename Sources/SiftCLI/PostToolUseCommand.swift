//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore
import SiftMCP

/// `sift post-tool-use` — the body of the Claude Code `PostToolUse` hook, run after a write or an edit of a Swift file.
///
/// Where `similar` answers "does this helper already exist?" only for a model that thinks to ask, this asks it on the model's behalf just after a function is written, while undoing the duplicate is still one edit. It holds to the `PreToolUse` hook's invariants, for the same reason — a misbehaving hook degrades every session on the machine: it always exits 0, it prints nothing unless it has a nudge or a parse block, and it gives up in silence past its budget.
struct PostToolUseCommand: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "post-tool-use",
            abstract: "Block an edit that left a Swift file unparseable, or point out a declaration like one just added (PostToolUse hook).",
            discussion: """
            Reads the hook's payload on stdin. After a Write, Edit or MultiEdit of a .swift file that no longer parses, or a Codex apply_patch adding or updating one, it blocks with each syntax error placed at path:line:col, once per content. Otherwise, in an indexed repository, it brings every dirty file's index record up to date and ranks each function-like declaration the edit added — one the index did not hold for the file before — against the rest of its module, as similar does. The closest hit at similar's floor is handed to the model as one line, naming where the existing declaration is and the similar call that shows the whole ranking.

            Otherwise silent: when nothing clears the floor, for a file the index never held (a first write is not a reuse question), past a one-second budget, on any error, and for a nudge this context has already been given about the same declaration in the same file. SIFT_NO_ADVICE turns it off, as it does pre-tool-use.
            """
        )
    }

    @Option(name: .customLong("agent"), help: "The harness whose hook protocol to read and answer in: claude or cursor (default claude). Set by the registration, never guessed from the payload.")
    var agent: HookAgent = .claude

    func run() {
        let disabled = ProcessInfo.processInfo.environment["SIFT_NO_ADVICE"] ?? ""
        guard disabled.isEmpty else { return }
        let payload = Self.hookPayload()
        guard agent == .claude else {
            if let read = CursorPostToolUse.claudePayload(from: payload) {
                Self.answer(to: read, output: CursorPostToolUse.output)
            }
            return
        }
        guard !CursorHookPayload.recognises(payload) else { return }
        Self.forgetMissedDigest(payload: payload)
        Self.answer(toEach: CodexApplyPatch.claudePayloads(from: payload) ?? [payload])
    }

    /// Everything the hook does with one payload: a block on an edit that left the file unparseable, else the nudge, printed to `output` — the standard streams in every real run, a recorder in a test — or nothing.
    ///
    /// The block wins and the nudge is dropped, not carried in its reason: a nudge is never found in a file that does not parse, and the one thing the model should do next is fix it. Both share the one budget, the nudge taking what the parse left.
    static func answer(to payload: [String: Any], output: CommandOutput = .standard, marks: ReuseNudgeMarks = .standard(), timeBudget: TimeInterval = ReuseNudge.timeBudget) {
        answer(toEach: [payload], output: output, marks: marks, timeBudget: timeBudget)
    }

    /// The one answer for an edit of several files, as a Codex `apply_patch` makes: the first block across `payloads`, else the first nudge, all of them sharing the one budget.
    ///
    /// The files are taken in order until the budget is spent, and then no further, so a patch of hundreds of files costs the budget and not a check of each. Each file is judged against the repository that holds it, as the `Write` of that file alone would be, so a patch made from a folder above several checkouts is answered for each; the repository is looked up once per directory, so a patch of many files in one directory costs one lookup.
    static func answer(toEach payloads: [[String: Any]], output: CommandOutput = .standard, marks: ReuseNudgeMarks = .standard(), timeBudget: TimeInterval = ReuseNudge.timeBudget) {
        answer(toEach: payloads, output: output, marks: marks, timeBudget: timeBudget) { payload, root, left in
            parseBlock(for: payload, root: root, marks: marks, timeBudget: left)
        }
    }

    /// The same answer, with `check` in place of the parse block and `lookUp` in place of the repository lookup for a directory: the seams a test counts the parse checks and the lookups through.
    static func answer(
        toEach payloads: [[String: Any]],
        output: CommandOutput,
        marks: ReuseNudgeMarks,
        timeBudget: TimeInterval,
        lookUp: (_ directory: String) -> String? = CallerRoot.root(forCallerIn:),
        check: (_ payload: [String: Any], _ root: String?, _ left: TimeInterval) -> String?
    ) {
        let deadline = Date(timeIntervalSinceNow: timeBudget)
        var roots: [String: String?] = [:]
        var json: String?
        for payload in payloads {
            let left = deadline.timeIntervalSinceNow
            guard json == nil, left > 0 else { break }
            json = check(payload, editedSwiftFile(in: payload).flatMap { root(of: $0.file, in: &roots, lookUp: lookUp) }, left)
        }
        if json == nil {
            json = nudge(forEach: payloads, roots: &roots, lookUp: lookUp, marks: marks, deadline: deadline)
        }
        guard let json else { return }
        output.emit(json)
    }

    /// The repository holding `file`, or `nil` where none does, looked up by `lookUp` once for each directory `roots` has not seen.
    private static func root(of file: String, in roots: inout [String: String?], lookUp: (_ directory: String) -> String?) -> String? {
        let directory = URL(fileURLWithPath: file).deletingLastPathComponent().path
        if let known = roots[directory] {
            return known
        }
        let root = lookUp(directory)
        roots[directory] = .some(root)
        return root
    }

    /// The hook JSON blocking on an edit that left a Swift file unparseable, or `nil` where the file parses or the block has been given.
    ///
    /// Once per context for each content the file is left holding, so the hook can never wedge a session: an edit that leaves the same broken bytes goes through the second time, and only a change to the file can draw a block again. Silent without a `session_id` to record that against, on a file it cannot read, and past `timeBudget`.
    static func parseBlock(for payload: [String: Any], root: String?, marks: ReuseNudgeMarks, timeBudget: TimeInterval) -> String? {
        guard let (file, sessionID) = editedSwiftFile(in: payload) else { return nil }
        let (prior, hunks) = editPrior(in: payload)
        let result = ResultBox<EditParseCheck>()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            result.value = EditParseCheck.run(file: file, root: root, prior: prior, hunks: hunks)
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeBudget) == .success, let check = result.value else { return nil }
        let context = AdviceContext.resolve(
            sessionID: sessionID,
            transcriptPath: payload["transcript_path"] as? String,
            agentID: payload["agent_id"] as? String
        )
        guard marks.claim(context: context.key, file: file, declaration: "unparseable \(check.contentHash)") else { return nil }
        return HookOutput.postToolUseBlock(reason: check.reason)
    }

    /// Takes back what `PreToolUse` noted for a `digest` whose answer resolved nothing, answering whether it did.
    ///
    /// The note is made before the call runs (``PreToolUseCommand/adviceTaken(session:context:payload:command:cwd:ledger:callers:)``), when no answer exists, so a miss has already been recorded as a digest this context holds and would let a window of the file through. The answer is read here, from the payload's `tool_response` — an MCP call's content blocks or a Bash call's `stdout` — with the one definition of a miss (``DigestMiss``), and the same targets the note was made for are removed.
    @discardableResult
    static func forgetMissedDigest(payload: [String: Any], ledger: AdviceLedger = .standard()) -> Bool {
        guard let tool = payload["tool_name"] as? String, tool == "Bash" || IndexToolName.tool(named: tool) == "digest",
              let sessionID = payload["session_id"] as? String,
              let answer = responseText(payload["tool_response"]), DigestMiss.isMiss(inAnswer: answer)
        else {
            return false
        }
        let asked = PreToolUseCommand.digestsAsked(
            toolName: tool,
            input: payload["tool_input"] as? [String: Any] ?? [:],
            cwd: (payload["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
        guard !asked.isEmpty else { return false }
        let context = AdviceContext.resolve(
            sessionID: sessionID,
            transcriptPath: payload["transcript_path"] as? String,
            agentID: payload["agent_id"] as? String
        )
        ledger.forgetDigests(session: context.key, digests: asked)
        return true
    }

    /// The text a tool's `tool_response` carries, in whichever of the shapes the harness writes it: a string, a list of content blocks, or an object holding `stdout` (a Bash call) or `content`.
    private static func responseText(_ response: Any?) -> String? {
        switch response {
        case let text as String:
            return text
        case let blocks as [[String: Any]]:
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        case let object as [String: Any]:
            if let stdout = object["stdout"] as? String {
                return stdout
            }
            return responseText(object["content"]) ?? object["text"] as? String
        default:
            return nil
        }
    }

    /// The absolute path of the Swift file a write or an edit in `payload` touched, with the session it ran in, or `nil` where the payload names no such file.
    private static func editedSwiftFile(in payload: [String: Any]) -> (file: String, sessionID: String)? {
        guard let tool = payload["tool_name"] as? String, LookupTool.writes(tool),
              let path = (payload["tool_input"] as? [String: Any])?["file_path"] as? String, path.hasSuffix(".swift"),
              let file = SwiftTree.resolve(path, relativeTo: payload["cwd"] as? String),
              let sessionID = payload["session_id"] as? String
        else {
            return nil
        }
        return (file, sessionID)
    }

    /// What the edited file held before the edit, from the payload's `tool_response`: its `originalFile`, empty for a file a Write created, else the `structuredPatch` to undo; unknown where none of these is there.
    ///
    /// The patch's hunks come back with it, whichever it was, for they say where the edit touched the file. An empty patch on anything but a create is read as unknown, not as no change, so a tool that sends one regardless never silences a file the edit broke. A patch with a hunk that cannot be read is not used at all.
    private static func editPrior(in payload: [String: Any]) -> (prior: EditPrior, hunks: [EditPrior.Hunk]) {
        guard let response = payload["tool_response"] as? [String: Any] else { return (.unknown, []) }
        let raw = response["structuredPatch"] as? [[String: Any]] ?? []
        let parsed = raw.compactMap { hunk -> EditPrior.Hunk? in
            guard let oldStart = hunk["oldStart"] as? Int, let start = hunk["newStart"] as? Int, let lines = hunk["lines"] as? [String] else { return nil }
            return EditPrior.Hunk(oldStart: oldStart, newStart: start, lines: lines)
        }
        let hunks = parsed.count < raw.count ? [] : parsed
        if let original = response["originalFile"] as? String {
            return (.content(original), hunks)
        }
        if response["type"] as? String == "create" {
            return (.content(""), hunks)
        }
        return (hunks.isEmpty ? .unknown : .patch(hunks), hunks)
    }

    /// The hook JSON carrying the one nudge the edits in `payloads` earn, or `nil` where they earn none or `deadline` passes first.
    ///
    /// The files are grouped by the repository holding them, in the order each repository first appears, and a file no repository holds is left out. Each group is judged together, in one refresh of its index, and the first file in patch order within it with a nudge this context has not been given already is the one named, so a second declaration in the same edit can still be named once the first has been.
    static func nudge(
        forEach payloads: [[String: Any]],
        roots: inout [String: String?],
        lookUp: (_ directory: String) -> String?,
        marks: ReuseNudgeMarks,
        deadline: Date
    ) -> String? {
        var groups: [(root: String, edits: [PatchEdit])] = []
        for payload in payloads {
            guard deadline.timeIntervalSinceNow > 0 else { return nil }
            guard let (file, sessionID) = editedSwiftFile(in: payload), let root = root(of: file, in: &roots, lookUp: lookUp) else { continue }
            let edit = PatchEdit(payload: payload, file: file, sessionID: sessionID)
            if let index = groups.firstIndex(where: { $0.root == root }) {
                groups[index].edits.append(edit)
            } else {
                groups.append((root, [edit]))
            }
        }
        for group in groups {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            guard ReadOnlyIndex.hasUsableIndex(atRoot: group.root) else { continue }
            let found = ReuseNudge.findings(forFiles: group.edits.map(\.file), atRoot: group.root, budget: left)
            for edit in group.edits {
                let context = AdviceContext.resolve(
                    sessionID: edit.sessionID,
                    transcriptPath: edit.payload["transcript_path"] as? String,
                    agentID: edit.payload["agent_id"] as? String
                )
                for nudge in found[edit.file] ?? [] where marks.claim(context: context.key, file: edit.file, declaration: nudge.added.declaration.qualifiedName) {
                    return HookOutput.postToolUseContext(nudge.line)
                }
            }
        }
        return nil
    }

    /// The `PostToolUse` payload Claude Code writes to the hook's stdin.
    ///
    /// Guarded by `isatty` so running this by hand returns immediately instead of blocking on a read that will never be satisfied.
    private static func hookPayload() -> [String: Any] {
        guard isatty(FileHandle.standardInput.fileDescriptor) == 0,
              let data = try? FileHandle.standardInput.readToEnd(), !data.isEmpty,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return payload
    }
}

private extension PostToolUseCommand {
    /// One Swift file a patch edited, with the payload that names it and the session it ran in.
    struct PatchEdit {
        let payload: [String: Any]
        let file: String
        let sessionID: String
    }
}
