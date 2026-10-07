//
// Copyright © Agulhas Labs
//

import Foundation

/// The one true spelling of a path, for the comparisons that decide which repository a query belongs to.
///
/// Standardizing a path resolves `..`, `.` and a trailing slash but leaves its *case* alone, and macOS volumes are case-insensitive by default. So `~/Developer/sift` and `~/Developer/Sift` are one directory that compares as two — which is not hypothetical: a shell whose `cwd` arrives in a different case from the one in the roots registry has the session primer announce an indexed repository as "not indexed yet". The same mismatch would register one repository twice and split its answers between the entries.
///
/// Asked of the filesystem rather than lowercased, because case-insensitivity is a property of the volume and not of the platform: on a case-sensitive volume `/Foo` and `/foo` really are two directories, and folding them together would be the same bug pointing the other way.
public struct CanonicalPath {
    /// `path` as the filesystem spells it, or its standardized form when nothing is there to ask.
    ///
    /// The fallback matters more than the resolution: paths that do not exist are ordinary here — a pruned root, a fixture in a test, a repository on a volume that is not mounted — and they have to keep comparing equal to themselves rather than becoming unresolvable.
    public static func of(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
        let trimmed = standardized.path.count > 1 && standardized.path.hasSuffix("/")
            ? String(standardized.path.dropLast())
            : standardized.path
        guard let canonical = try? standardized.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath,
              !canonical.isEmpty
        else {
            return trimmed
        }
        return canonical.count > 1 && canonical.hasSuffix("/") ? String(canonical.dropLast()) : canonical
    }
}
