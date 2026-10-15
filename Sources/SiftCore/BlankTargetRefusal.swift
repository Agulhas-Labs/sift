//
// Copyright © Agulhas Labs
//

import Foundation

/// The refusal a lookup gives a target that is empty or only whitespace, worded once for the shell and the server.
///
/// A blank target names nothing, so it is refused before any lookup runs and before any usage-log row is written: answering it with "no declarations found" would read as a symbol that does not exist.
public struct BlankTargetRefusal {
    /// The message for `tool` (`digest`, `where` or `strings`) when any of `targets` is empty or only whitespace, otherwise `nil`.
    public static func message(tool: String, targets: [String]) -> String? {
        guard targets.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        let (noun, example) = switch tool {
        case "where": ("symbol", "a type or a Type.member")
        case "strings": ("query", "the display text or key to trace")
        default: ("target", "a type, a Type.member, a module or a file path, or . for the repo")
        }
        return "\(tool) needs a \(noun), and was given an empty one (or only whitespace): name \(example)."
    }
}
