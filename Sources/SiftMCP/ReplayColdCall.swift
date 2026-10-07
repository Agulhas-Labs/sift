//
// Copyright © Agulhas Labs
//

import Foundation

/// One call the replayed hook still let through, as the replay section lists it: its text, and how big its answer came to where it was withheld over the size budget.
struct ReplayColdCall: Hashable, Sendable {
    /// A Bash call's command, or a tool call spelled from its fields (`Read <path> offset=<n> limit=<n>`, `Grep pattern=… path=…`).
    let text: String
    /// The bytes the withheld answer came to, where the size budget withheld one after building it.
    let answerBytes: Int?

    init(text: String, answerBytes: Int? = nil) {
        self.text = text
        self.answerBytes = answerBytes
    }

    /// The call `payload` makes, spelled as the section lists it, or `nil` for one with nothing to spell.
    init?(payload: [String: Any], answerBytes: Int?) {
        let tool = payload["tool_name"] as? String ?? ""
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        let text: String
        switch tool {
        case "Bash":
            guard let command = input["command"] as? String else { return nil }
            text = command
        case "Read":
            guard let path = input["file_path"] as? String else { return nil }
            text = (["Read \(path)"] + ["offset", "limit"].compactMap { key in
                (input[key] as? NSNumber).map { "\(key)=\($0.intValue)" }
            }).joined(separator: " ")
        case "Grep", "Glob":
            text = RefusedCallShapeClassifier.shape(searchTool: tool, input: input).text
        default:
            guard !tool.isEmpty else { return nil }
            text = tool
        }
        self.init(text: text, answerBytes: answerBytes)
    }
}
