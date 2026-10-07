//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The worktrees and directories a session's own transcripts made, read off their Bash calls for ``WorktreeOrigins``.
///
/// Each statement is read in the directory the command has moved to by then, through a `cd` or a `git -C`, which is where a relative path in it lands. A path spelled through a shell variable is skipped, since nothing here can say what it held.
struct WorktreeOriginScan {
    /// What `transcripts` — a session and its subagents — name, each read as `snapshot` holds it: each worktree a `git worktree add` made, with the repository it ran in, and each directory `mkdir`, `git init` or `git clone` made.
    static func origins(of transcripts: [URL], in snapshot: TranscriptSnapshot, enclosing: @escaping (String) -> String?) -> WorktreeOrigins {
        var named: [String: String] = [:]
        var ambiguous: Set<String> = []
        var made: [String] = []
        for (command, cwd) in transcripts.flatMap({ commands(in: $0, snapshot: snapshot) }) {
            let known = WorktreeOrigins(named: named, made: made, enclosing: enclosing)
            var directory = cwd
            for statement in ShellSyntax.statements(of: command) {
                let words = ShellQuery(statement).invocation
                if words.count == 2, words[0] == "cd" {
                    directory = resolve(words[1], against: directory) ?? directory
                    continue
                }
                if words.first == "mkdir" {
                    made += operands(of: Array(words.dropFirst()), takingValues: ["-m"]).compactMap { resolve($0, against: directory) }
                }
                guard words.first == "git" else { continue }
                let (gitDirectory, verb) = gitInvocation(Array(words.dropFirst()), in: directory)
                if let path = madeByGit(verb), let resolved = resolve(path, against: gitDirectory) {
                    made.append(resolved)
                }
                guard verb.count > 1, verb[0] == "worktree", verb[1] == "add",
                      let path = operands(of: Array(verb.dropFirst(2)), takingValues: ["-b", "-B", "--reason"]).first,
                      let resolved = resolve(path, against: gitDirectory)
                else { continue }
                let ranIn = known.mapping(directory: gitDirectory)
                guard WorktreeOrigins.isDirectory(ranIn), let repository = GitContext.discoverRoot(from: URL(fileURLWithPath: ranIn, isDirectory: true))?.path else { continue }
                // The same path added from two repositories names neither.
                if let earlier = named[resolved], earlier != repository {
                    ambiguous.insert(resolved)
                }
                named[resolved] = repository
            }
        }
        return WorktreeOrigins(named: named.filter { !ambiguous.contains($0.key) }, made: made, enclosing: enclosing)
    }

    /// Every Bash command in `url` that could name a directory made, with the working directory it ran in.
    ///
    /// Only a line naming the Bash tool is parsed, and only a command spelling `git` or `mkdir`, or holding a quote or a backslash, is kept: the scan reads every line of every transcript in the window, and in a worktree's context the marker `worktree` is in every line's working directory, so without the first test every line of it is parsed. A command spelling neither runs no statement the scan reads, since a `cd` alone moves only the statements after it in the same command — unless a quote or a backslash inside a word spells one of them, which the shell runs as the plain word, so a command holding either is left to the parser.
    private static func commands(in url: URL, snapshot: TranscriptSnapshot) -> [(command: String, cwd: String)] {
        guard let data = snapshot.contents(of: url) else { return [] }
        let markers = ["worktree", "mkdir", "git init", "clone"].map { Data($0.utf8) }
        let bash = Data(#""Bash""#.utf8)
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).flatMap { slice -> [(command: String, cwd: String)] in
            guard slice.range(of: bash) != nil,
                  markers.contains(where: { slice.range(of: $0) != nil }),
                  let object = try? JSONSerialization.jsonObject(with: Data(slice)) as? [String: Any],
                  let cwd = object["cwd"] as? String
            else { return [] }
            let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { block in
                guard block["type"] as? String == "tool_use", block["name"] as? String == "Bash",
                      let command = (block["input"] as? [String: Any])?["command"] as? String,
                      command.contains("git") || command.contains("mkdir") || command.contains(where: { "\"'\\".contains($0) })
                else { return nil }
                return (command, cwd)
            }
        }
    }

    /// The directory a `git` invocation runs in after its `-C` options, and the words from its subcommand on.
    private static func gitInvocation(_ words: [String], in directory: String) -> (directory: String, verb: [String]) {
        var directory = directory
        var rest = words[...]
        while rest.count > 1, rest.first == "-C" {
            directory = resolve(rest[rest.startIndex + 1], against: directory) ?? directory
            rest = rest.dropFirst(2)
        }
        return (directory, Array(rest))
    }

    /// The directory a `git init` or `git clone` makes, as written, or `nil` for any other subcommand.
    private static func madeByGit(_ verb: [String]) -> String? {
        switch verb.first {
        case "init":
            return operands(of: Array(verb.dropFirst()), takingValues: ["-b", "--initial-branch", "--template", "--separate-git-dir", "--object-format"]).last ?? "."
        case "clone":
            let values: Set = ["-b", "--branch", "-o", "--origin", "-c", "--config", "--depth", "--reference", "-u", "--upload-pack", "-j", "--jobs", "--filter", "--separate-git-dir", "--template"]
            let given = operands(of: Array(verb.dropFirst()), takingValues: values)
            guard let source = given.first else { return nil }
            return given.count > 1 ? given[1] : ((source as NSString).lastPathComponent as NSString).deletingPathExtension
        default:
            return nil
        }
    }

    /// The words of `arguments` that are neither an option nor the value that follows an option taking one.
    private static func operands(of arguments: [String], takingValues: Set<String>) -> [String] {
        var operands: [String] = []
        var skipsNext = false
        for word in arguments {
            if skipsNext {
                skipsNext = false
            } else if takingValues.contains(word) {
                skipsNext = true
            } else if !word.hasPrefix("-"), !word.contains(">"), !word.contains("<") {
                operands.append(word)
            }
        }
        return operands
    }

    /// `path` spelled out against `directory`, or `nil` where it goes through a shell variable.
    private static func resolve(_ path: String, against directory: String) -> String? {
        guard !path.contains("$"), !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded).standardizedFileURL.path
            : URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: directory, isDirectory: true)).standardizedFileURL.path
        return TranscriptReplay.mappingWorktrees(in: absolute)
    }
}
