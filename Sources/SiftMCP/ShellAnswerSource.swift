//
// Copyright © Agulhas Labs
//

import Foundation

/// The repository a Bash line's `sift where`/`sift search` output was answered from, read only off a line whose output is nothing but those answers.
///
/// The transcript keeps a Bash call's output whole, and nothing in it says which statement printed which line, so the audit and the replay credit the files it lists only where every statement is such a lookup, each at most narrowed by a filter that drops lines and never adds one (`head`, `tail`, `grep`, `sort`, `uniq` reading only the pipe). Anything that could move the lookup to another repository or put other text beside its answer — a `cd`, a subshell or brace group, a substitution or variable, an input redirection, another command, a `--root` outside every repository, an answer as of another revision — and the line credits nothing: an unlocated window is counted cold, which is the direction the share may err in, where crediting the wrong repository's file would score a lookup the hook calls for as guided.
public struct ShellAnswerSource: Sendable, Equatable, Codable {
    /// The repository the lookups answered from, as ``CallerRoot`` names it.
    public let root: String
    /// The subcommands whose answers make up the output, `where`, `search` or both.
    public let tools: Set<String>

    /// Where `command`'s output was answered from, run in `directory`, or `nil` unless the line is nothing but `sift where`/`sift search` lookups of one repository resolved exactly as the CLI resolves it (``RootResolver``'s enclosing repository).
    public static func of(command: String, cwd directory: String?) -> ShellAnswerSource? {
        // A substitution, subshell, brace group, variable or input redirection: what runs is not what is written.
        let runnable = ShellSyntax.runnableText(command)
        guard !ShellSyntax.executableText(of: runnable).contains(where: { "$`(){}<".contains($0) }) else { return nil }
        var roots: Set<String> = []
        var tools: Set<String> = []
        for statement in ShellSyntax.statements(of: runnable) {
            let stages = ShellSyntax.segments(of: statement)
            guard let first = stages.first,
                  let words = IndexCallTarget.cliLookups(inCommand: first).first,
                  let subcommand = words.first(where: { !$0.hasPrefix("-") }),
                  subcommand == "where" || subcommand == "search",
                  !words.contains(where: { $0 == "--at" || $0.hasPrefix("--at=") }),
                  words.filter({ $0 == "--root" || $0.hasPrefix("--root=") }).count <= 1,
                  !wordsFollowARedirect(Array(ShellQuery(first).rawInvocation.dropFirst())),
                  stages.dropFirst().allSatisfy({ onlyNarrows(ShellQuery($0).invocation) })
            else { return nil }
            let named = zip(words, words.dropFirst()).first { $0.0 == "--root" }?.1
                ?? words.first { $0.hasPrefix("--root=") }.map { String($0.dropFirst("--root=".count)) }
            // The CLI opens the repository enclosing `--root`, read against the directory it runs in, or else
            // enclosing that directory; one outside every repository may adopt another, which is not guessed at.
            let asked: String? = if let named {
                SwiftTree.resolve(named, relativeTo: directory)
            } else {
                directory
            }
            guard let root = CallerRoot.root(forCallerIn: asked) else { return nil }
            roots.insert(root)
            tools.insert(subcommand)
        }
        guard roots.count == 1, let root = roots.first else { return nil }
        return ShellAnswerSource(root: root, tools: tools)
    }

    /// The files `output` lists, read by the parsers each subcommand's own answer is read back by (`DigestedFiles.locatedFiles`).
    public func locatedFiles(inOutput output: String) -> [String] {
        Set(tools.flatMap { DigestedFiles.locatedFiles(inAnswer: output, tool: $0) }).sorted()
    }

    /// Whether a pipeline stage only drops lines of what it is handed: `head`/`tail` with at most a count, `sort`/`uniq` with flags alone, or a non-recursive `grep` given one pattern and no file.
    private static func onlyNarrows(_ argv: [String]) -> Bool {
        guard let verb = argv.first else { return false }
        let arguments = argv.dropFirst()
        switch verb {
        case "head", "tail":
            return bareWords(in: arguments, takingValues: ["-n", "-c"]) == 0
        case "sort", "uniq":
            return arguments.allSatisfy { $0.hasPrefix("-") }
        case "grep", "egrep", "fgrep":
            // A recursive grep handed no file searches the directory it runs in, not the pipe.
            let recursive = arguments.contains { $0 == "--recursive" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains { "rR".contains($0) }) }
            guard !recursive else { return false }
            let patternFlagged = arguments.contains { ["-e", "-f", "--regexp", "--file"].contains($0) || $0.hasPrefix("--regexp=") || $0.hasPrefix("--file=") }
            let values: Set = ["-e", "-f", "-A", "-B", "-C", "-m", "--regexp", "--file", "--max-count", "--after-context", "--before-context", "--context"]
            return bareWords(in: arguments, takingValues: values) <= (patternFlagged ? 0 : 1)
        default:
            return false
        }
    }

    /// The bare redirection operators — digits then `<`/`>`, doubled, or `&` then `<`/`>` — whose destination is always the next word, never joined to the operator itself; anything else matching `cliLookups(inCommand:)`'s own redirect marker (`2>&1`, `2>/dev/null`, `>&2`) already carries its destination in the one token.
    nonisolated(unsafe) private static let bareRedirectOperator = /^&?\d*(?:>>|<<|>|<)$/

    /// Whether `raw` — a segment's un-quote-stripped invocation, its command word already dropped — carries a word past the first redirection's own destination: a `--root` or other argument riding after `2>&1`, `2>/dev/null`, or a bare `>`/`>>` whose target is the next token.
    ///
    /// `cliLookups` cuts argv at the same redirection operator and stops there, so a `--root` written after one is lost from the words it hands back and the root falls back to the caller's own repository — crediting it even though the CLI, reading the full line, answered from another. Reading past the cut here, on the untruncated line, is what tells a redirect that ends the statement (nothing follows its own destination) from one with more argument riding behind it.
    private static func wordsFollowARedirect(_ raw: [String]) -> Bool {
        guard let operatorIndex = raw.firstIndex(where: { $0.firstMatch(of: /^(\d*|&)[<>]/) != nil }) else { return false }
        let bare = raw[operatorIndex].wholeMatch(of: bareRedirectOperator) != nil
        let targetEnd = operatorIndex + (bare ? 2 : 1)
        return raw.count > targetEnd
    }

    /// How many of `arguments` are neither a flag nor the value a flag that takes one was handed.
    private static func bareWords(in arguments: ArraySlice<String>, takingValues: Set<String>) -> Int {
        var count = 0
        var skipsNext = false
        for word in arguments {
            if skipsNext {
                skipsNext = false
            } else if takingValues.contains(word) {
                skipsNext = true
            } else if !word.hasPrefix("-") {
                count += 1
            }
        }
        return count
    }
}
