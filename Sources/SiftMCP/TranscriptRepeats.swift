//
// Copyright © Agulhas Labs
//

import Foundation

/// The transcript lines that are not events: Claude Code's request records.
///
/// Claude Code writes request-record lines whose message repeats tool calls and results already written elsewhere in the same transcript, so every reader that counts or judges calls skips them.
struct TranscriptRepeats {
    /// The top-level `type` of a request-record line, which is not an event.
    static var requestBlobType: String {
        "api-request-blob"
    }

    /// Whether a parsed transcript line is a request record.
    static func isRequestBlob(_ object: [String: Any]) -> Bool {
        object["type"] as? String == requestBlobType
    }

    /// Whether a raw transcript line is a request record, parsing it only when its bytes name the type.
    static func isRequestBlob(line: Data) -> Bool {
        guard line.range(of: Data(requestBlobType.utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else {
            return false
        }
        return isRequestBlob(object)
    }
}
