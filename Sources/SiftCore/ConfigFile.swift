//
// Copyright © Agulhas Labs
//

import Foundation

/// The one reader/writer for `.sift.json`.
///
/// Round-trips through a raw dictionary rather than `SiftConfig`, deliberately: a `Codable` write would silently drop any key this version does not model, so an older binary editing a newer config would delete fields it merely didn't understand. `init` merges onto what is already there. A key this version has retired is the case running in the other direction — a *newer* binary editing a config written by an older one — and it survives an edit for the same reason.
struct ConfigFile {
    /// Where this repository's config is read from and written to.
    static func url(repoRoot: URL) -> URL {
        SiftPaths.config(in: repoRoot)
    }

    static func exists(repoRoot: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(repoRoot: repoRoot).path)
    }

    /// The file's contents as raw JSON, or empty when absent or unreadable.
    static func rawJSON(repoRoot: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url(repoRoot: repoRoot)),
              let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return existing
    }

    /// Writes `json` deterministically — sorted keys, pretty printed, so a config under review diffs cleanly.
    ///
    /// Atomically, because this file is committed in the user's repository and is the only copy of what they wrote by hand. A plain write truncates in place, so an `init --write` interrupted partway leaves JSON that no longer parses — and `SiftConfig.load` treats a malformed config as an error rather than a default, so every subsequent query fails to open the engine at all. Destroying a hand-maintained module map is the worse half of that; failing to write a proposal is recoverable.
    static func write(_ json: [String: Any], repoRoot: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url(repoRoot: repoRoot), options: .atomic)
    }
}
