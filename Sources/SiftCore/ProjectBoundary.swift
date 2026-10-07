//
// Copyright © Agulhas Labs
//

import Foundation

/// Which project in the tree a repo-relative file belongs to: the deepest directory holding a build file of its own that encloses it, the root as the empty string.
///
/// Read from ``ModuleResolver/projectDirectories``, so a nested `Package.swift`, XcodeGen spec or `.xcodeproj` each start a project, and a build of one never compiles a file of another.
struct ProjectBoundary {
    /// The non-root project directories, deepest first, so the first that encloses a path is its nearest.
    private let directories: [String]

    init(directories: [String]) {
        self.directories = directories.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    /// The project directory `path` belongs to, the empty string for the root's.
    func project(of path: String) -> String {
        directories.first { path.hasPrefix($0 + "/") } ?? ""
    }
}
