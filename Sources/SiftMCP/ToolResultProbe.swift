//
// Copyright © Agulhas Labs
//

import Foundation

/// Whether a context's transcript has written the result of one tool call yet, read from the file's tail.
///
/// The harness writes a call's `tool_use` block late and its `tool_result` later still, so a hook running for a call sent beside another sees the earlier call's use perhaps not yet written, and its result not yet. That gap is the whole signal: a call whose result is not in the transcript is not yet answered, whether or not its use line has landed.
public struct ToolResultProbe {
    /// How much of the transcript's end is read.
    ///
    /// 64 MiB, which nothing writes in a minute, so a result written within the window is inside it and "not in the tail" means "not written". The read happens only where an offered call was noted within the last minute, and a transcript is never read whole for this.
    public static let tailBytes = 64 * 1024 * 1024

    /// Where the call `id` stands in the transcript at `path`, read from its last ``tailBytes`` bytes.
    ///
    /// **Anything but a result in the tail is not answered.** A call whose `tool_use` line is in the tail with no result is `unanswered`; one with neither line is `unwritten`, the harness not having flushed its use yet. A file that is missing or cannot be read is `unreadable`, which says nothing either way.
    ///
    /// The id is matched as the value of a `tool_use_id` key for a result and of an `id` key for a use, and then confirmed on the parsed line, so the id appearing elsewhere — a result's text can quote it escaped — is never mistaken for either. A first line cut by the tail's start is dropped, since half a line parses as nothing.
    public static func standing(ofToolUse id: String, inTranscript path: String, tailBytes: Int = tailBytes) -> Standing {
        guard !id.isEmpty, let handle = FileHandle(forReadingAtPath: path) else { return .unreadable }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return .unreadable }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return .unreadable }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        let resultNeedle = Data(#""tool_use_id":"\#(id)""#.utf8)
        let useNeedle = Data(#""id":"\#(id)""#.utf8)
        if lines.contains(where: { $0.range(of: resultNeedle) != nil && hasBlock("tool_result", key: "tool_use_id", id: id, in: Data($0)) }) {
            return .answered
        }
        return lines.contains { $0.range(of: useNeedle) != nil && hasBlock("tool_use", key: "id", id: id, in: Data($0)) } ? .unanswered : .unwritten
    }

    /// Whether the transcript line holds a content block of `type` whose `key` is `id`.
    private static func hasBlock(_ type: String, key: String, id: String, in line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]]
        else { return false }
        return blocks.contains { $0["type"] as? String == type && $0[key] as? String == id }
    }
}

public extension ToolResultProbe {
    /// Where a call stands in the transcript's tail.
    enum Standing: Equatable, Sendable {
        /// The call's `tool_result` is in the tail.
        case answered
        /// The call's `tool_use` block is in the tail and its `tool_result` is not.
        case unanswered
        /// Neither is in the tail: the use line is not yet written, and the result is not either.
        case unwritten
        /// The transcript is missing or cannot be read: the probe cannot tell.
        case unreadable
    }
}
