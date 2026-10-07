//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Which of this tool's Codex hooks `config.toml` records a trust for.
///
/// Codex keys each trust by the handler's position, `[hooks.state."<hooks.json path>:<snake_case event>:<group index>:<handler index>"]`, holding a `trusted_hash` only Codex computes, so a record is counted and its hash never compared. Codex runs an untrusted hook without a word of output, which is why the count is worth a line.
struct DoctorCodexTrust {
    /// The check's line, for the handlers at `positions` in the hooks file `hooks`: unknown, never a failure, when `config` cannot be read or records fewer than all of them, since neither the key's spelling nor the hash is confirmed.
    static func check(config: URL, hooks: URL, positions: [Position]) -> DoctorCheck {
        guard FileManager.default.fileExists(atPath: config.path) else {
            return .unknown(.codex, "trust", "no \(config.path) to read the trust of \(positions.count) hooks from; Codex asks to trust them when it next opens")
        }
        guard let text = try? String(contentsOf: config, encoding: .utf8) else {
            return .unknown(.codex, "trust", "\(config.path) could not be read")
        }
        let count = recorded(in: text, hooks: hooks.path, positions: positions).count
        let detail = "trust recorded for \(count) of \(positions.count) in \(config.path) (hash not compared)"
        guard count == positions.count else {
            return .unknown(.codex, "trust", "\(detail); Codex skips an untrusted hook without a word — open Codex and approve the sift hooks (/hooks to review them)")
        }
        return .pass(.codex, "trust", detail)
    }

    /// The positions whose trust `config` records a hash for, the hooks file's path compared canonically on both sides.
    static func recorded(in config: String, hooks: String, positions: [Position]) -> [Position] {
        let file = CanonicalPath.of(hooks)
        let trusted = trustedKeys(in: config).compactMap(position(of:)).filter { $0.file == file }.map(\.position)
        return positions.filter { trusted.contains($0) }
    }

    /// `event` as the trust key spells it: `PreToolUse` is `pre_tool_use`.
    static func snakeCase(_ event: String) -> String {
        var spelled = ""
        for character in event {
            if character.isUppercase, !spelled.isEmpty {
                spelled += "_"
            }
            spelled += character.lowercased()
        }
        return spelled
    }

    /// Every `[hooks.state."<key>"]` table that holds a non-empty `trusted_hash`.
    private static func trustedKeys(in config: String) -> [String] {
        let prefix = "[hooks.state.\""
        let suffix = "\"]"
        var table: String?
        var keys: [String] = []
        for line in config.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("[") {
                table = line.hasPrefix(prefix) && line.hasSuffix(suffix) ? String(line.dropFirst(prefix.count).dropLast(suffix.count)) : nil
                continue
            }
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let key = table, pair.count == 2, pair[0] == "trusted_hash", pair[1].count > 2, pair[1].hasPrefix("\"") else { continue }
            keys.append(key)
        }
        return keys
    }

    /// A key split from the right, since the path may hold a colon: the canonical file and the position it names.
    private static func position(of key: String) -> (file: String, position: Position)? {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4, let group = Int(parts[parts.count - 2]), let handler = Int(parts[parts.count - 1]) else { return nil }
        let file = parts.dropLast(3).joined(separator: ":")
        return (CanonicalPath.of(file), Position(event: parts[parts.count - 3], group: group, handler: handler))
    }
}

extension DoctorCodexTrust {
    /// Where one handler sits in `hooks.json`: its event as the trust key spells it, its group's index under the event and its own index in the group, every foreign entry counted.
    struct Position: Equatable {
        let event: String
        let group: Int
        let handler: Int
    }
}
