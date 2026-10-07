//
// Copyright © Agulhas Labs
//

import Foundation

/// How many tokens a context holds at a call, read off the usage of the last assistant message its own transcript records.
///
/// **The context's own transcript, never the parent's.** A subagent's payload carries its `agent_id` and the session's `transcript_path`; its context is the transcript beside the session's, under `subagents/`, and where that file is not there the size is unknown, so the default stands rather than the session's usage, which is another and usually larger context (``ServerPresence/subagentTranscript(ofSession:agent:)``).
///
/// **Only the tail is read**, since the hook runs on every call and a transcript runs to tens of megabytes: the last assistant message is within a window of the end, widened once where one message is larger than the first.
public struct ContextSize {
    /// The size taken where the context's cannot be read: the median of the contexts the rule was measured on.
    public static let defaultTokens = 45000

    /// The key a replayed call's payload carries the context's size under as of that call, a number the harness never writes, so a binary that does not read it takes the payload as it always has.
    public static var replayKey: String {
        "sift_context_tokens"
    }

    /// The window of the transcript's end read first, in bytes, and the wider one read where it holds no assistant message.
    private static let windows = [64 * 1024, 1024 * 1024]

    /// The size of the context making the call `payload` describes: the one a replay hands over, or else the one its own transcript records last, or ``defaultTokens``.
    public static func ofCall(_ payload: [String: Any]) -> Int {
        if payload.keys.contains(replayKey) {
            return (payload[replayKey] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? defaultTokens
        }
        let path = ServerPresence.subagentTranscript(ofSession: payload["transcript_path"] as? String, agent: payload["agent_id"] as? String)
        return path.flatMap(latest(inTranscript:)) ?? defaultTokens
    }

    /// The size the assistant message one transcript line records ran in, or `nil` where the line is not one or records none.
    public static func tokens(inLine object: [String: Any]) -> Int? {
        guard object["type"] as? String == "assistant",
              let usage = (object["message"] as? [String: Any])?["usage"] as? [String: Any]
        else { return nil }
        let total = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
        return total > 0 ? total : nil
    }

    /// The size recorded by the last assistant message in the transcript at `path`, or `nil` where it records none within the windows read or cannot be read.
    public static func latest(inTranscript path: String) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let marker = Data(#""type":"assistant""#.utf8)
        for window in windows {
            let start = size > UInt64(window) ? size - UInt64(window) : 0
            guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            // A window that starts mid-file starts mid-line: its first line is a fragment.
            if start > 0, !lines.isEmpty {
                lines.removeFirst()
            }
            for line in lines.reversed() where line.range(of: marker) != nil {
                if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let tokens = tokens(inLine: object) {
                    return tokens
                }
            }
            if start == 0 {
                return nil
            }
        }
        return nil
    }
}
