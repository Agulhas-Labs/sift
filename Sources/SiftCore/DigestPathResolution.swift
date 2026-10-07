//
// Copyright © Agulhas Labs
//

import Foundation

/// How a file target the caller spelled is read as the repo-relative path the index stores.
struct DigestPathResolution {
    let renderer: DigestRenderer

    /// `path` in the repo-relative form the index stores, or `nil` when it leaves this repository.
    ///
    /// A relative path is read from the repository root and an absolute one as written. A relative path whose root reading names no indexed file is tried again from ``currentDirectory``, and that reading is taken only where it names an indexed file, so a path spelled from where the caller stands still reaches a root named elsewhere while a Markdown or excluded file keeps its root reading.
    ///
    /// The root is compared in both its canonical and its standardized spelling, because ``CanonicalPath/of(_:)`` can resolve only a path that exists: a root reached through a symlink must still contain its own files, and a relative path naming nothing must still come back relative.
    func relativeToRepository(_ path: String) -> String? {
        let fromRoot = repoRelative(path.hasPrefix("/") ? path : renderer.repoRoot.appendingPathComponent(path).path)
        guard !path.hasPrefix("/"), CanonicalPath.of(renderer.currentDirectory.path) != CanonicalPath.of(renderer.repoRoot.path) else {
            return fromRoot
        }
        guard let fromRoot else {
            return repoRelative(renderer.currentDirectory.appendingPathComponent(path).path)
        }
        guard case .missing? = try? renderer.resolveFile(path: fromRoot),
              let fromHere = repoRelative(renderer.currentDirectory.appendingPathComponent(path).path),
              case .file? = try? renderer.resolveFile(path: fromHere)
        else {
            return fromRoot
        }
        return fromHere
    }

    private func repoRelative(_ absolute: String) -> String? {
        let candidate = CanonicalPath.of(absolute)
        for root in [CanonicalPath.of(renderer.repoRoot.path), renderer.repoRoot.standardizedFileURL.path] where candidate.hasPrefix(root + "/") {
            return String(candidate.dropFirst(root.count + 1))
        }
        return nil
    }
}
