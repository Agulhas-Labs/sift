//
// Copyright © Agulhas Labs
//

import Foundation

/// Whether a repository root is scratch: a probe or fixture, not a repository anyone works in.
///
/// One predicate for `usage` and `report`, so the two faces cannot disagree about which calls were real. Scratch is anywhere under the system temporary directory (`/tmp`, `/private/tmp`, `/var/folders` and `$TMPDIR`, in both spellings, the same list the roots registry keeps out of its own), anywhere under `~/Library/Caches`, and anything with a `.build` directory in its path. Matched on component boundaries: a repository called `build` or `tmpfoo` is an ordinary one.
public struct ScratchRoot {
    /// Whether `path` is a scratch root.
    public static func contains(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let prefixes = RootsRegistry.systemEphemeralPrefixes + [SiftPaths.accountHome.appendingPathComponent("Library/Caches").path]
        if prefixes.contains(where: { standardized == $0 || standardized.hasPrefix($0 + "/") }) {
            return true
        }
        return standardized.split(separator: "/").contains(".build")
    }
}
