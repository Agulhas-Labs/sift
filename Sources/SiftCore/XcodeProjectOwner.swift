//
// Copyright © Agulhas Labs
//

import Foundation

/// Finds the Xcode project that builds a source file, for the `where` line that says how to give that file an index store inside the tree.
///
/// A project owns a file when its `.xcodeproj` or `.xcworkspace` sits in the file's own directory or in any ancestor up to the repository root — the layout where a sibling project (`Runner/Runner.xcodeproj` beside `Runner/Sources/`) or a root project builds it. The nearest directory holding one wins, and within it a workspace before a project, since a workspace is what gets built when both exist.
struct XcodeProjectOwner {
    let repoRoot: URL

    /// The hint line for the repo-relative `path`, or `nil` when no project in the tree owns it.
    func hint(forFileAt path: String) -> String? {
        let directory = (path as NSString).deletingLastPathComponent
        var components = directory.split(separator: "/").map(String.init)
        while true {
            let relative = components.joined(separator: "/")
            if let project = project(in: relative) {
                let project = relative.isEmpty ? project : relative + "/" + project
                return "\(directory.isEmpty ? "." : directory) is built by \(project); build it with -derivedDataPath inside the tree for semantic answers"
            }
            guard !components.isEmpty else { return nil }
            components.removeLast()
        }
    }

    /// The workspace or project directly inside the repo-relative `directory`, workspaces first, then by name.
    private func project(in directory: String) -> String? {
        let url = directory.isEmpty ? repoRoot : repoRoot.appendingPathComponent(directory)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return nil }
        let sorted = entries.sorted()
        return sorted.first { $0.hasSuffix(".xcworkspace") } ?? sorted.first { $0.hasSuffix(".xcodeproj") }
    }
}
