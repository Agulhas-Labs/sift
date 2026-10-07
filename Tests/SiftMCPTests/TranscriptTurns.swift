//
// Copyright © Agulhas Labs
//

import Foundation

/// Transcript lines shaped exactly as the harness writes them, for the suites that follow a lookup through the turns around it.
///
/// An assistant turn's blocks are written one to a line, each carrying the turn's `message.id` and its `usage`. A tool's result carries its call's id, its content and — where the call failed — the error flag, and nothing naming the tool. Built to that shape so the scan's byte pre-filter meets the lines a real transcript holds, and a test cannot pass on a marker no real line would carry.
struct TranscriptTurns {
    /// One tool call of the assistant turn `turn`, on its own line.
    static func call(_ name: String, id: String, input: [String: Any], turn: String, usage: Usage = Usage(), cwd: String? = nil) -> Data {
        assistant(turn: turn, block: ["type": "tool_use", "id": id, "name": name, "input": input], usage: usage, cwd: cwd)
    }

    /// A text block of the assistant turn `turn` — the kind of line a turn often opens with, and one that carries none of the markers a call does.
    static func text(_ text: String, turn: String, usage: Usage) -> Data {
        assistant(turn: turn, block: ["type": "text", "text": text], usage: usage, cwd: nil)
    }

    /// A tool's result as the harness writes one: the call's id, its content as a bare string, and the error flag where the call failed — the shape a hook's refusal arrives in.
    static func result(id: String, text: String, isError: Bool = false) -> Data {
        var result: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": text]
        if isError {
            result["is_error"] = true
        }
        return encoded(["type": "user", "message": ["role": "user", "content": [result]]])
    }

    /// An index call's answer, as the harness relays one from the server: the text in typed content blocks.
    static func indexAnswer(id: String, text: String) -> Data {
        let result: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": [["type": "text", "text": text]]]
        return encoded(["type": "user", "message": ["role": "user", "content": [result]]])
    }

    private static func assistant(turn: String, block: [String: Any], usage: Usage, cwd: String?) -> Data {
        var recorded: [String: Any] = [
            "input_tokens": usage.input,
            "cache_read_input_tokens": usage.cacheRead,
            "cache_creation_input_tokens": usage.cacheCreation,
            "output_tokens": 10,
        ]
        if usage.cacheCreation5m != nil || usage.cacheCreation1h != nil {
            recorded["cache_creation"] = [
                "ephemeral_5m_input_tokens": usage.cacheCreation5m ?? 0,
                "ephemeral_1h_input_tokens": usage.cacheCreation1h ?? 0,
            ]
        }
        var object: [String: Any] = [
            "type": "assistant",
            "message": ["id": turn, "role": "assistant", "content": [block], "usage": recorded],
        ]
        object["cwd"] = cwd
        return encoded(object)
    }

    private static func encoded(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}

extension TranscriptTurns {
    /// What one turn's request cost, as the harness records it on every line of the turn.
    struct Usage {
        var input = 2
        var cacheRead = 0
        var cacheCreation = 0
        /// The five-minute and one-hour halves of `cacheCreation`, when a test wants the split `message.usage` carries on a harness new enough to write it.
        ///
        /// `nil` for both, the default, writes only the flat `cache_creation_input_tokens` — the shape an older transcript wrote, read back as entirely five-minute.
        var cacheCreation5m: Int?
        var cacheCreation1h: Int?

        var total: Int {
            input + cacheRead + cacheCreation
        }
    }
}
