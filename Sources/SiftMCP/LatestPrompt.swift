//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The latest message written into a context by whoever drives it — the user's prompt in a session, the handoff in a subagent — read off the transcript the harness keeps for that context.
///
/// **A document the prompt names is one the reader was told to read.** "Read .claude/handoffs/… and carry on" asks for the document's text, and an outline handed over in its place is spent on the way to the identical re-run that reads it anyway: an extra turn and the outline's bytes at the start of every session that resumes from a handoff. So the advice hook lets a whole `Read` of a Markdown document the latest prompt names run untouched (``PreToolUseCommand``).
///
/// A prompt is a line the transcript records as the user's, carrying text rather than a tool's result, and not one the harness marks as its own (`isMeta`: a skill's body, a peer session's message). Its `cwd` is where the prompt was written, which is what a relative path in it was written against.
public struct LatestPrompt: Equatable, Sendable {
    public let text: String
    public let cwd: String?

    public init(text: String, cwd: String?) {
        self.text = text
        self.cwd = cwd
    }

    /// The prompt one transcript line records, or `nil` where the line is not one.
    public init?(line object: [String: Any]) {
        guard object["type"] as? String == "user", object["isMeta"] as? Bool != true,
              let message = object["message"] as? [String: Any]
        else { return nil }
        let text: String
        if let written = message["content"] as? String {
            text = written
        } else if let blocks = message["content"] as? [[String: Any]], !blocks.isEmpty,
                  !blocks.contains(where: { $0["type"] as? String == "tool_result" })
        {
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        } else {
            return nil
        }
        guard !Self.isSynthetic(text) else { return nil }
        self.init(text: text, cwd: object["cwd"] as? String)
    }

    /// The prompt a replay hands the hook in the payload, or `nil` where it has seen none yet.
    public init?(payloadValue value: Any?) {
        guard let fields = value as? [String: String], let text = fields["text"] else { return nil }
        self.init(text: text, cwd: fields["cwd"])
    }

    /// This prompt as a payload carries it (``TranscriptReplay/promptKey``).
    public var payloadValue: [String: String] {
        var fields = ["text": text]
        if let cwd {
            fields["cwd"] = cwd
        }
        return fields
    }

    /// The latest prompt of the context making the call `payload` describes: the one a replay hands over under ``TranscriptReplay/promptKey``, or else the one the context's own transcript records last.
    public static func ofCall(_ payload: [String: Any]) -> LatestPrompt? {
        if let handed = payload[TranscriptReplay.promptKey] {
            return LatestPrompt(payloadValue: handed)
        }
        return latest(inTranscript: ServerPresence.transcript(ofSession: payload["transcript_path"] as? String, agent: payload["agent_id"] as? String))
    }

    /// The latest prompt in the transcript at `path`, or `nil` where it records none or cannot be read.
    ///
    /// Read backwards from the end, so the cost is the stretch since the prompt rather than the whole context, and only the lines that could be a prompt are parsed: the user's, which are not tool results.
    public static func latest(inTranscript path: String?) -> LatestPrompt? {
        guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else {
            return nil
        }
        let userLine = Data(#""type":"user""#.utf8)
        let toolResult = Data(#""type":"tool_result""#.utf8)
        var end = data.endIndex
        while end > data.startIndex {
            let start = data[data.startIndex ..< end].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            let line = data[start ..< end]
            if line.range(of: userLine) != nil, line.range(of: toolResult) == nil,
               let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               let prompt = LatestPrompt(line: object)
            {
                return prompt
            }
            end = start > data.startIndex ? start - 1 : data.startIndex
        }
        return nil
    }

    /// Whether this prompt names the file at `path`, written absolute, from home, or relative to where the prompt was written or to `cwd`, the directory of the call that reads it.
    ///
    /// A path is a run of characters that ends in the file's own extension, bounded by whitespace, quotes, brackets, a colon (so `Docs/Plan.md:40` names the document) or punctuation; a leading `@` (the harness's file mention) is dropped. Compared canonically, so a spelling through a symlink names the same file.
    public func names(_ path: String, cwd: String?) -> Bool {
        let fileExtension = (path as NSString).pathExtension
        guard !fileExtension.isEmpty, let target = SwiftTree.resolve(path, relativeTo: cwd).map(CanonicalPath.of) else { return false }
        let bases = [self.cwd, cwd].compactMap(\.self)
        for word in text.split(whereSeparator: { Self.bounds.contains($0) }) {
            var written = String(word.drop { $0 == "@" })
            while let last = written.last, Self.trailing.contains(last) {
                written.removeLast()
            }
            guard (written as NSString).pathExtension.caseInsensitiveCompare(fileExtension) == .orderedSame else { continue }
            if written.hasPrefix("~/") {
                written = NSHomeDirectory() + written.dropFirst()
            }
            let candidates = written.hasPrefix("/") ? [written] : bases.compactMap { SwiftTree.resolve(written, relativeTo: $0) }
            if candidates.contains(where: { CanonicalPath.of($0) == target }) {
                return true
            }
        }
        return false
    }

    /// Whether `text` is a line the harness wrote, not the user: a subagent hand-back, a slash command's name, a local command's stdout, or an interruption notice, each recorded as a `"user"` line the same as a real prompt.
    private static func isSynthetic(_ text: String) -> Bool {
        let trimmed = text.drop { $0.isWhitespace }
        return syntheticPrefixes.contains { trimmed.hasPrefix($0) }
    }

    /// The prefixes that mark a `"user"` line as the harness's own rather than the user's.
    private static let syntheticPrefixes = ["<task-notification>", "<command-name>", "<local-command-", "[Request interrupted by user"]

    /// The characters that end a path written in prose.
    private static let bounds = Set(" \t\n\r\"'`()<>[]{},;:|*")

    /// The punctuation a sentence can close a path with, stripped from its end.
    private static let trailing = Set(".!?")
}
