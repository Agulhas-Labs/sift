//
// Copyright © Agulhas Labs
//

import Foundation

/// One entry of `git status --porcelain=v2 -z`, for a path that is changed or untracked.
///
/// Porcelain paths are relative to the repository root wherever the query is run from, which is what lets a pathspec be read from the caller's own directory while every path the record keeps is the root's.
struct SetAsideStatusLine {
    let path: String
    /// Everything git printed for the path but the path — what a restore has to read as again.
    let fields: String
    private let parts: [String]

    private init?(_ text: String, flag: String) throws {
        switch text.first {
        case "1":
            let parts = text.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 9 else {
                throw SetAsideError.git("git status printed a line this could not read: \(text)")
            }
            path = parts[8]
            fields = parts[0 ..< 8].joined(separator: " ")
            self.parts = parts
        case "?":
            path = String(text.dropFirst(2))
            fields = "?"
            parts = []
        case "u":
            let parts = text.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
            throw SetAsideError.unsupported(path: parts.last.map(String.init) ?? text, reason: "it has unresolved merge conflicts", flag: flag)
        case "2":
            throw SetAsideError.unsupported(path: text, reason: "git reported a rename although rename detection was turned off", flag: flag)
        default:
            return nil
        }
    }
}

extension SetAsideStatusLine {
    /// The status query for `pathspecs`: every change, every untracked file, renames as the deletion and addition they are, and submodules reported rather than hidden.
    static func arguments(_ pathspecs: [String]) -> [String] {
        ["status", "--porcelain=v2", "-z", "--untracked-files=all", "--no-renames", "--ignore-submodules=none", "--"] + pathspecs
    }

    /// Every changed or untracked path in `output`, and apart from them the ones under this tool's own directory, which a set-aside never moves: its store and its lock live there, and the answer says so rather than skipping them silently.
    ///
    /// `flag` names the run this reads for, so a refusal reads as the caller's own command.
    static func parse(_ output: Data, flag: String) throws -> (lines: [SetAsideStatusLine], own: [String]) {
        var lines: [SetAsideStatusLine] = []
        var own: [String] = []
        for record in output.split(separator: 0) {
            guard let text = String(data: record, encoding: .utf8) else {
                throw SetAsideError.unsupported(path: "a path git printed", reason: "its name is not UTF-8", flag: flag)
            }
            guard let line = try SetAsideStatusLine(text, flag: flag) else {
                continue
            }
            if line.path.split(separator: "/").contains(Substring(SiftPaths.directoryName)) {
                own.append(line.path)
            } else {
                lines.append(line)
            }
        }
        return (lines, own)
    }

    private var isUntracked: Bool {
        parts.isEmpty
    }

    private var staged: Character {
        Array(parts[1])[0]
    }

    private var unstaged: Character {
        Array(parts[1])[1]
    }

    /// Why the path cannot be set aside and put back exactly, or `nil` when it can.
    var unsupported: String? {
        guard !isUntracked else {
            return nil
        }
        if parts[2] != "N..." {
            return "it is a submodule, whose own working tree this does not set aside"
        }
        if parts[3 ... 5].contains("160000") {
            return "it is a submodule entry"
        }
        return nil
    }

    /// HEAD's entry for the path, or `nil` where HEAD has none.
    var headEntry: SetAsideRecord.IndexEntry? {
        guard !isUntracked, parts[3] != "000000" else {
            return nil
        }
        return SetAsideRecord.IndexEntry(mode: parts[3], object: parts[6])
    }

    /// What the index holds for the path: `mI` and `hI`, which porcelain reports whether or not they differ from HEAD's — and an intent-to-add entry, which it reports as an addition with no index mode.
    var indexState: SetAsideRecord.IndexState {
        guard !isUntracked else {
            return .absent
        }
        guard parts[4] != "000000" else {
            return staged == "." && unstaged == "A" ? .intentToAdd : .absent
        }
        return .entry(SetAsideRecord.IndexEntry(mode: parts[4], object: parts[7]))
    }
}
