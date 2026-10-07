//
// Copyright © Agulhas Labs
//

import Foundation

extension SetAside {
    /// One path a set-aside will take out of the tree: what the commit it is set aside to holds for it, what the index holds for it now, and why it could not be put back exactly, when it could not.
    ///
    /// A set-aside reads one of two sources — what is uncommitted under the pathspecs, or what the commits since a revision changed under them — and both become this, so everything after it is written once and the two can never behave differently.
    struct Change {
        /// The modes a set-aside can write back: a file, an executable file, a symbolic link.
        static let reproducibleModes = ["100644", "100755", "120000"]

        /// Repository-relative, exactly as git printed it.
        let path: String
        /// git's `status --porcelain=v2` fields for the path, less the path itself; empty for a committed change, which is neither staged, unstaged nor untracked.
        let status: String
        /// The entry of the commit the path is set aside to, or `nil` where that commit has no such path.
        let head: SetAsideRecord.IndexEntry?
        /// What the index holds for the path now.
        let index: SetAsideRecord.IndexState
        /// Why the path cannot be set aside and put back exactly, or `nil` when it can.
        let unsupported: String?

        /// An uncommitted change, as git's status reported it.
        init(_ line: SetAsideStatusLine) {
            path = line.path
            status = line.fields
            head = line.headEntry
            index = line.indexState
            unsupported = line.unsupported
        }

        init(path: String, status: String, head: SetAsideRecord.IndexEntry?, index: SetAsideRecord.IndexState, unsupported: String?) {
            self.path = path
            self.status = status
            self.head = head
            self.index = index
            self.unsupported = unsupported
        }
    }
}

extension SetAside.Change {
    /// Every path the commits since `since` changed under `pathspecs`, from one `git diff` between that commit and HEAD — and apart from them the ones under this tool's own directory, which a set-aside never moves.
    ///
    /// Read between the two commits rather than against the working tree because the caller has already been refused if anything under the pathspecs is uncommitted: with the tree clean under them HEAD is what the tree holds, and a diff between two commits names a real object on each side where one against the tree leaves the second side unnamed.
    static func committed(since: String, pathspecs: [String], git: SetAsideGit) throws -> (changes: [SetAside.Change], own: [String]) {
        // `--no-abbrev` because git shortens an object name in raw output to whatever is unique in the
        // repository, and an abbreviated name is not the one the index entry has to be written with;
        // `--no-relative` because a caller in a subdirectory would otherwise be handed paths relative to it
        // where a repository sets `diff.relative`, and every path here is spelled from the root.
        let output = try git.run(["diff", "--no-relative", "--no-abbrev", "--raw", "--no-renames", "-z", since, "HEAD", "--"] + pathspecs)
        let records = output.split(separator: 0, omittingEmptySubsequences: false)
        var changes: [SetAside.Change] = []
        var own: [String] = []
        var position = 0
        while position + 1 < records.count {
            let described = records[position]
            let name = records[position + 1]
            position += 2
            guard let text = String(data: described, encoding: .utf8) else {
                throw SetAsideError.git("git diff printed an entry whose bytes are not UTF-8")
            }
            guard text.hasPrefix(":") else {
                throw SetAsideError.git("git diff printed an entry this could not read: \(text)")
            }
            let fields = text.dropFirst().split(separator: " ").map(String.init)
            guard fields.count == 5 else {
                throw SetAsideError.git("git diff printed an entry this could not read: \(text)")
            }
            guard let path = String(data: name, encoding: .utf8) else {
                throw SetAsideError.unsupported(path: "a path git printed", reason: "its name is not UTF-8", flag: "--without")
            }
            guard !path.split(separator: "/").contains(Substring(SiftPaths.directoryName)) else {
                own.append(path)
                continue
            }
            let now = fields[1]
            changes.append(SetAside.Change(
                path: path,
                status: "",
                head: fields[0] == "000000" ? nil : SetAsideRecord.IndexEntry(mode: fields[0], object: fields[2]),
                index: now == "000000" ? .absent : .entry(SetAsideRecord.IndexEntry(mode: now, object: fields[3])),
                unsupported: now == "000000" || reproducibleModes.contains(now) ? nil : "the index records it with mode \(now)"
            ))
        }
        return (changes, own)
    }
}
