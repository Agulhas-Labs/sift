//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A whole read of a Markdown document runs untouched where its outline would only precede the identical re-run: the latest prompt names the document, or the outline is past a third of it.
@Suite(.temporaryDirectories)
struct MarkdownWholeReadTests {
    /// A whole `Read` of the document, as the harness hands it to the hook, with `extra` merged into the payload.
    private static func read(_ path: String, in root: URL, extra: [String: Any] = [:]) -> [String: Any] {
        ["tool_name": "Read", "tool_input": ["file_path": path], "cwd": root.path].merging(extra) { _, new in new }
    }

    /// The hook's lookup for `payload`, and the suppression log it wrote.
    private static func lookup(_ payload: [String: Any], in root: URL) throws -> (lookup: PreToolUseCommand.Lookup?, logged: String) {
        let log = try TemporaryDirectory.make("suppressions").appendingPathComponent("suppressions.jsonl")
        let lookup = PreToolUseCommand.lookup(command: nil, payload: payload, in: root.path, noting: SuppressionLog(fileURL: log))
        return (lookup, (try? String(contentsOf: log, encoding: .utf8)) ?? "")
    }

    /// A document the latest prompt names — relative to where it was written, or absolute — is let through as `namedInPrompt`; the same read under a prompt naming another document is still a lookup.
    @Test(arguments: ["read Docs/Plan.md and carry on", "carry on from `@Docs/Plan.md`.", "see ABSOLUTE:40"])
    func aDocumentThePromptNamesIsLetThrough(prompt: String) async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let document = try InPlaceAnswerTests.document(in: root)
        let written = LatestPrompt(text: prompt.replacingOccurrences(of: "ABSOLUTE", with: document.path), cwd: root.path)

        let named = try Self.lookup(Self.read(document.path, in: root, extra: [TranscriptReplay.promptKey: written.payloadValue]), in: root)
        #expect(named.lookup == nil)
        #expect(named.logged.contains("namedInPrompt"))

        let other = LatestPrompt(text: "read Docs/Other.md and carry on", cwd: root.path)
        let unnamed = try Self.lookup(Self.read(document.path, in: root, extra: [TranscriptReplay.promptKey: other.payloadValue]), in: root)
        #expect(unnamed.lookup != nil)
        #expect(!unnamed.logged.contains("namedInPrompt"))
    }

    /// The live hook reads the prompt off the context's transcript: the latest line the user wrote, past the tool results and the harness's own messages after it.
    @Test func thePromptIsReadOffTheTranscript() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let document = try InPlaceAnswerTests.document(in: root)
        let lines: [[String: Any]] = [
            ["type": "user", "cwd": root.path, "message": ["role": "user", "content": "read Docs/Old.md"]],
            ["type": "user", "cwd": root.path, "message": ["role": "user", "content": "read Docs/Plan.md and carry on"]],
            ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "Reading Docs/Other.md"]]]],
            ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "Docs/Other.md"]]]],
            ["type": "user", "isMeta": true, "message": ["role": "user", "content": "Another session names Docs/Other.md"]],
        ]
        let transcript = try TemporaryDirectory.make("transcript").appendingPathComponent("session.jsonl")
        let text = try lines.map { try #require(String(bytes: JSONSerialization.data(withJSONObject: $0), encoding: .utf8)) }.joined(separator: "\n") + "\n"
        try text.write(to: transcript, atomically: true, encoding: .utf8)

        #expect(LatestPrompt.latest(inTranscript: transcript.path) == LatestPrompt(text: "read Docs/Plan.md and carry on", cwd: root.path))
        let named = try Self.lookup(Self.read(document.path, in: root, extra: ["transcript_path": transcript.path]), in: root)
        #expect(named.lookup == nil)
        #expect(named.logged.contains("namedInPrompt"))
    }

    /// An outline past a third of its document is withheld as `outlineTooLarge`, so the read runs; an ordinary document's outline is still the answer.
    @Test func anOutlinePastAThirdOfTheDocumentIsWithheld() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let steps = (1 ... 40).map { "## Step \($0)\n\nDo step \($0) now, check what it printed, and only then go on to the next one.\n" }
        let dense = root.appendingPathComponent("Docs/Steps.md")
        try FileManager.default.createDirectory(at: dense.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("# Steps\n\n" + steps.joined(separator: "\n")).write(to: dense, atomically: true, encoding: .utf8)
        let plan = try InPlaceAnswerTests.document(in: root)

        let backoff = try InPlaceAnswerTests.backoff()
        let answer = { (path: String) async throws -> InPlaceAnswerer.Outcome in
            let match = try #require(InPlaceShape.match(forRead: path, in: root.path, window: nil))
            return await InPlaceAnswerTests.onItsOwnThread {
                InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
            }
        }
        let withheld = try await answer(dense.path)
        #expect(withheld == .withheld(.outlineTooLarge))
        guard case .answered = try await answer(plan.path) else {
            Issue.record("an ordinary document's outline should still be the answer")
            return
        }
    }

    /// A line the harness wrote rather than the user — a subagent's hand-back, a slash command's name, a local command's stdout, or an interruption notice — never counts as the prompt, whatever it says, so the scan reads on past it to the line the user actually wrote.
    @Test(arguments: [
        "<task-notification>a subagent finished, see README.md</task-notification>",
        "<command-name>/model</command-name>",
        "<local-command-stdout>README.md</local-command-stdout>",
        "[Request interrupted by user for tool use]",
    ])
    func aSyntheticLineIsNotThePrompt(notice: String) throws {
        let lines: [[String: Any]] = [
            ["type": "user", "cwd": "/repo", "message": ["role": "user", "content": "read Docs/Design.md and carry on"]],
            ["type": "user", "message": ["role": "user", "content": notice]],
        ]
        let transcript = try TemporaryDirectory.make("transcript").appendingPathComponent("session.jsonl")
        let text = try lines.map { try #require(String(bytes: JSONSerialization.data(withJSONObject: $0), encoding: .utf8)) }.joined(separator: "\n") + "\n"
        try text.write(to: transcript, atomically: true, encoding: .utf8)

        #expect(LatestPrompt.latest(inTranscript: transcript.path) == LatestPrompt(text: "read Docs/Design.md and carry on", cwd: "/repo"))
    }

    /// The reverse of the same bug: a synthetic line naming a document is not the prompt naming it either, so a read of that document is still a lookup.
    @Test(arguments: [
        "<task-notification>see Docs/Design.md</task-notification>",
        "<command-name>Docs/Design.md</command-name>",
        "<local-command-stdout>Docs/Design.md</local-command-stdout>",
    ])
    func aSyntheticLineDoesNotNameADocumentForThePrompt(notice: String) throws {
        let lines: [[String: Any]] = [
            ["type": "user", "cwd": "/repo", "message": ["role": "user", "content": "carry on"]],
            ["type": "user", "message": ["role": "user", "content": notice]],
        ]
        let transcript = try TemporaryDirectory.make("transcript").appendingPathComponent("session.jsonl")
        let text = try lines.map { try #require(String(bytes: JSONSerialization.data(withJSONObject: $0), encoding: .utf8)) }.joined(separator: "\n") + "\n"
        try text.write(to: transcript, atomically: true, encoding: .utf8)

        #expect(LatestPrompt.latest(inTranscript: transcript.path) == LatestPrompt(text: "carry on", cwd: "/repo"))
    }
}
