//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Where a replay moves a path under a linked worktree that is gone: onto the repository the worktree was cut from.
///
/// A worktree under `.claude/worktrees/<name>` is moved onto the repository above it, as it always was. Any other gone worktree is moved on one of two kinds of evidence. A `git worktree add <path>` in the session's own transcripts names the repository outright: the one the command ran in, wherever the path lay. Without one, a gone directory inside an existing repository's tree (`<repo>/.build/<name>`) is taken as cut from the nearest repository holding it, where that repository ignores the path and no transcript of the session made it by other means: a tracked directory since deleted is the repository's own content, and one made by `mkdir`, `git init` or `git clone` was never a checkout of it. What neither reaches stays gone, and a call run in it stays unreplayable.
struct WorktreeOrigins {
    /// Each gone worktree a `git worktree add` names, by absolute path, with the repository the command ran in.
    let named: [String: String]
    /// Every directory the session's transcripts made by other means than `git worktree add`.
    let made: [String]
    /// The repository a gone directory lay in and ignores, or `nil` where there is none.
    let enclosing: (String) -> String?

    init(named: [String: String] = [:], made: [String] = [], enclosing: @escaping (String) -> String? = Self.memoisedEnclosing()) {
        self.named = named
        self.made = made
        self.enclosing = enclosing
    }

    /// `text` with every absolute path under a gone worktree moved onto the repository the worktree was cut from — a whole directory, a `file_path` or `path` argument, or a path inside a Bash command's own text.
    func mapping(in text: String) -> String {
        let stripped = TranscriptReplay.mappingWorktrees(in: text)
        guard stripped.contains("/") else { return stripped }
        let characters = Array(stripped)
        var output = ""
        var index = 0
        while index < characters.count {
            guard characters[index] == "/", index == 0 || Self.bounds.contains(characters[index - 1]) else {
                output.append(characters[index])
                index += 1
                continue
            }
            var end = index
            while end < characters.count, !Self.bounds.contains(characters[end]) {
                end += 1
            }
            output += moved(String(characters[index ..< end]), isDirectory: false)
            index = end
        }
        return output
    }

    /// `directory` — a working directory, or the one a `cd` moves to — moved the same way, and also where it is the gone worktree itself.
    func mapping(directory: String) -> String {
        moved(TranscriptReplay.mappingWorktrees(in: directory), isDirectory: true)
    }

    /// The gone worktree `path` lies in and the repository it was cut from, or `nil` where no evidence names one.
    ///
    /// Without a `git worktree add` naming it, a gone path is only taken as a worktree itself where it is known to be a directory: a path in a command's text could as well be a file since deleted from an ignored directory, and moving that onto the repository would hand the hook a directory where the call named a file.
    func origin(of path: String, isDirectory: Bool) -> (root: String, repository: String)? {
        let covering = named.keys.filter { path == $0 || path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
        if let covering, !Self.isDirectory(covering), let repository = named[covering] {
            return (covering, repository)
        }
        var root = path
        var ancestor = (path as NSString).deletingLastPathComponent
        while ancestor != "/", !ancestor.isEmpty, !Self.isDirectory(ancestor) {
            root = ancestor
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        guard ancestor != "/", !ancestor.isEmpty, path.hasPrefix(root), isDirectory || root != path,
              !made.contains(where: { $0 == root || $0.hasPrefix(root + "/") })
        else { return nil }
        return enclosing(root).map { (root, $0) }
    }

    /// An `enclosing` that asks git once per gone directory, and once per directory above one.
    static func memoisedEnclosing() -> (String) -> String? {
        let repositories = EnclosingRepositories()
        return { repositories.repository(holding: $0) }
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The characters that end a path written in a command, and that may stand right before one.
    private static let bounds = Set(" \t\n&|;\"'()<>`=")

    /// `path` moved onto its worktree's repository where it is gone and an origin is known, as written otherwise.
    private func moved(_ path: String, isDirectory: Bool) -> String {
        guard !FileManager.default.fileExists(atPath: path), let origin = origin(of: path, isDirectory: isDirectory) else { return path }
        return origin.repository + path.dropFirst(origin.root.count)
    }
}

private extension WorktreeOrigins {
    /// A reference box, so the closure above can memoise without static mutable state.
    final class EnclosingRepositories {
        private var known: [String: String?] = [:]
        private var roots: [String: URL?] = [:]

        func repository(holding gone: String) -> String? {
            if let known = known[gone] {
                return known
            }
            let parent = (gone as NSString).deletingLastPathComponent
            let root: URL?
            if let cached = roots[parent] {
                root = cached
            } else {
                root = GitContext.discoverRoot(from: URL(fileURLWithPath: parent, isDirectory: true))
                roots[parent] = root
            }
            let answer = root.flatMap { root -> String? in
                let base = root.resolvingSymlinksInPath().path
                let holder = URL(fileURLWithPath: parent).resolvingSymlinksInPath().path
                guard holder == base || holder.hasPrefix(base + "/") else { return nil }
                let relative = String((holder + "/" + (gone as NSString).lastPathComponent).dropFirst(base.count + 1))
                return GitContext(repoRoot: root).ignores(relativePath: relative) ? root.path : nil
            }
            known[gone] = answer
            return answer
        }
    }
}
