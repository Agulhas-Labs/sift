//
// Copyright © Agulhas Labs
//

import Foundation

/// One line naming a lookup that went around the index, for a reader who sees nothing else of the call.
///
/// It names the call and never reproduces it: a file's basename, a pattern, the first line of a command. A band above the prompt has one short row per call, so the text is cut to ``limit`` characters rather than wrapped.
struct MissSummary {
    /// The most characters a summary holds, its ellipsis included.
    static let limit = 80

    /// The summary of a call to `tool` with `input`, led by the tool's name as the transcript records it.
    static func of(tool: String, input: [String: Any]) -> String {
        let detail: String? = switch LookupTool.rule(for: tool) {
        case "Read": read(input)
        case "Grep", "Glob": search(input)
        case "Bash": (input["command"] as? String).flatMap(firstLine)
        default: nil
        }
        return clipped(detail.map { "\(tool) \($0)" } ?? tool)
    }

    /// The file's basename, then the lines a ranged read asked for or `(whole)`.
    ///
    /// A range with an `offset` and no `limit` runs to the end of the file, which the summary writes as an open end.
    private static func read(_ input: [String: Any]) -> String? {
        guard let path = LookupTool.readPath(in: input) else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let offset = (input["offset"] as? NSNumber)?.intValue
        let limit = (input["limit"] as? NSNumber)?.intValue
        guard offset != nil || limit != nil else { return "\(name) (whole)" }
        let start = offset ?? 1
        return "\(name):\(start)-\(limit.map { String(start + $0 - 1) } ?? "")"
    }

    /// The pattern quoted, then the last component of the path it searched where it named one.
    private static func search(_ input: [String: Any]) -> String? {
        guard let pattern = input["pattern"] as? String else { return nil }
        guard let path = input["path"] as? String, !path.isEmpty else { return "\"\(pattern)\"" }
        return "\"\(pattern)\" in \(URL(fileURLWithPath: path).lastPathComponent)"
    }

    private static func firstLine(_ command: String) -> String? {
        let line = command.split(separator: "\n", omittingEmptySubsequences: true).first.map { $0.trimmingCharacters(in: .whitespaces) }
        return line?.isEmpty == false ? line : nil
    }

    private static func clipped(_ text: String) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}
