//
// Copyright © Agulhas Labs
//

import Foundation

/// A git directory holding nothing, made in the temporary directory for one read and removed after it.
///
/// It has no `info/exclude` and no configuration of its own, so a read pointed at it applies no ignore rule but the `.gitignore` files in the working tree it is given. It is the least git accepts as a repository — a `HEAD`, an `objects` and a `refs` directory — written directly rather than by `git init`, which would cost a process and copy the templates.
struct EmptyRepository {
    /// The git directory.
    let url: URL

    /// Makes the directory, removing what it made where a step fails.
    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sift-empty-git-\(UUID().uuidString)", isDirectory: true)
        do {
            for name in ["objects", "refs"] {
                try FileManager.default.createDirectory(at: url.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            try Data("ref: refs/heads/main\n".utf8).write(to: url.appendingPathComponent("HEAD"))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        self.url = url
    }

    /// Removes the directory and everything in it.
    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
