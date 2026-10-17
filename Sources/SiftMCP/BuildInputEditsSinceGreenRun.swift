//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The build inputs one context's transcript shows it editing since its last green `sift run` build or test.
///
/// A successful `Write`, `Edit` or `MultiEdit` of a path ``TreeKey/isBuildInput(_:)`` accepts counts, in the order its result arrived; a `Bash` call running `sift run` over a build or a test whose result is not an error clears the edits in the repository that run built, since everything before it there was validated by it, and none in any other. A call whose result is an error, or never arrived, counts for nothing, and so does a run whose success the call's result cannot vouch for (``validatedDirectories(of:cwd:)``).
///
/// Read line by line off raw bytes, and a line is parsed only when it could hold such a call or the result of one already pending, so a long session costs a byte search rather than a JSON parse per line.
public struct BuildInputEditsSinceGreenRun {
    /// The absolute paths edited since the last green run, oldest first and each once, or `nil` where the transcript cannot be read.
    ///
    /// Skipping sidechains leaves out lines a subagent wrote into its parent's file, which is how a session transcript answers for the session alone.
    public static func files(inTranscript url: URL, skippingSidechains: Bool) -> [String]? {
        scan(transcript: url, skippingSidechains: skippingSidechains)?.files
    }

    /// What one read of a transcript found, or `nil` where it cannot be read.
    public static func scan(transcript url: URL, skippingSidechains: Bool) -> Scan? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var pendingEdits: [String: String] = [:]
        var pendingRuns: [String: [String]] = [:]
        var roots: [String: String?] = [:]
        /// Asked of the repository once per directory, since a session's edits and runs keep returning to the same few.
        func root(of directory: String) -> String? {
            if let known = roots[directory] {
                return known
            }
            let found = CallerRoot.root(forCallerIn: directory).map(CanonicalPath.of)
            roots[directory] = found
            return found
        }
        var edited: [String] = []
        var xcodebuild: (command: String, directory: String?)?
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let callsSomething = line.range(of: toolUseMarker) != nil
                && (line.range(of: filePathMarker) != nil || line.range(of: siftMarker) != nil)
            let answersPending = line.range(of: toolResultMarker) != nil
                && (pendingEdits.keys.contains { line.range(of: Data($0.utf8)) != nil } || pendingRuns.keys.contains { line.range(of: Data($0.utf8)) != nil })
            guard callsSomething || answersPending,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else {
                continue
            }
            if skippingSidechains, object["isSidechain"] as? Bool == true {
                continue
            }
            if TranscriptRepeats.isRequestBlob(object) {
                continue
            }
            for block in (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "tool_use":
                    note(call: block, cwd: object["cwd"] as? String, edits: &pendingEdits, runs: &pendingRuns, xcodebuild: &xcodebuild)
                case "tool_result":
                    guard let id = block["tool_use_id"] as? String else { continue }
                    let failed = block["is_error"] as? Bool == true
                    if let path = pendingEdits.removeValue(forKey: id), !failed {
                        edited.removeAll { $0 == path }
                        edited.append(path)
                    } else if let directories = pendingRuns.removeValue(forKey: id), !failed {
                        let built = Set(directories.compactMap(root))
                        edited.removeAll { root(of: URL(fileURLWithPath: $0).deletingLastPathComponent().path).map(built.contains) ?? false }
                    }
                default:
                    continue
                }
            }
        }
        return Scan(files: edited, xcodebuild: xcodebuild, cwd: lastDirectory(in: data, skippingSidechains: skippingSidechains))
    }

    /// The directory each `sift run` build or test in a shell command built, for every such run a success of the whole command proves green, or nothing where it proves none.
    ///
    /// The command's result is its last pipeline's, so a run answers for itself only where nothing could have turned its failure into that success: it ends its pipeline (`sift run -- swift build | tail` exits with `tail`'s status), no `||` stands just before it (which can skip it), and only `&&` joins it to every statement after it. A command that is one subshell or one brace group and nothing else is read as its inside, which starts in the same directory and gives the command its result; any other command holding a subshell, a group or another compound statement proves nothing, since how its pieces join is not read here.
    ///
    /// The directory starts at `cwd`, the one the call ran in, and moves with each plain `cd` before the run that `&&` joins to it. Any other change of directory before the run — a `cd` after a `;` or a newline, which a failed `cd` still reaches, a `pushd`, a `cd` in a pipeline or a substitution — or a relative `cd` with no `cwd` to read it from leaves the directory unknown, and that run proves nothing.
    ///
    /// The command is read as the shell reads it: comments out first, so a backslash ending one continues nothing, then each backslash-newline joined away, and a statement of blanks alone is no statement.
    public static func validatedDirectories(of command: String, cwd: String?) -> [String] {
        guard let line = Statements(command), ["", ";"].contains(line.joints[line.last]) else { return [] }
        return line.located.indices.compactMap { index -> String? in
            guard let run = ShellSyntax.segments(of: line.located[index].statement).last.flatMap(siftRun(ofSegment:)),
                  RunCommandKind.compilesTree(run.wrapped), line.depends(line.last, on: index)
            else {
                return nil
            }
            var directory = line.directory(before: index, cwd: cwd)
            if let root = run.root {
                directory = InPlaceShape.resolve(root, against: directory)
            }
            return directory.flatMap { RunCommandKind.builtDirectory(of: run.wrapped, from: $0) }
        }
    }

    /// The last statement or pipeline stage of a shell command that is a `sift run` over an `xcodebuild … build`, as the shell ran it, with the directory the line's own `cd`s put it in.
    ///
    /// The command is read as ``validatedDirectories(of:cwd:)`` reads it, comments out, backslash-newlines joined and one enclosing subshell or brace group opened, and the segment found in that same text, so the one named is the joined line and never loses its directory to a continuation.
    ///
    /// The segment is named without a trailing `2>&1`.
    ///
    /// The directory is found without the segment's own `--root`, and is `nil` where it cannot be read: a compound statement, a `cd` that does not lead to the run, or a run inside a substitution.
    public static func siftXcodebuildBuild(in command: String, cwd: String?) -> (command: String, directory: String?)? {
        let text = Statements.read(command)
        guard let segment = ShellSyntax.executedSegments(of: text).last(where: { segment in
            guard let wrapped = siftRun(ofSegment: segment)?.wrapped, RunCommandKind.recognize(wrapped) == .xcodebuild else { return false }
            return RunCommandKind.logKey(of: wrapped).hasSuffix(" build")
        }) else {
            return nil
        }
        let found = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = Statements(text).flatMap { line in
            line.located.indices.last { index in
                ShellSyntax.segments(of: line.located[index].statement).contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == found }
            }.flatMap { line.directory(before: $0, cwd: cwd) }
        }
        let written = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        return (written.hasSuffix(" 2>&1") ? String(written.dropLast(5)).trimmingCharacters(in: .whitespaces) : written, directory)
    }
}

public extension BuildInputEditsSinceGreenRun {
    /// What one read of a transcript found.
    struct Scan {
        /// The files edited since its last green run, oldest first and each once.
        public let files: [String]
        /// The last `sift run -- xcodebuild … build` it issued, whether or not that one succeeded: the segment of the Bash command as the shell ran it, with the directory it ran in, so a block can name it as it was.
        public let xcodebuild: (command: String, directory: String?)?
        /// The directory the context stands in now: the `cwd` of the last line that carries one, or `nil` where none does.
        public let cwd: String?
    }
}

private extension BuildInputEditsSinceGreenRun {
    static let toolUseMarker = Data("\"tool_use\"".utf8)
    static let toolResultMarker = Data("\"tool_result\"".utf8)
    static let filePathMarker = Data("\"file_path\"".utf8)
    static let siftMarker = Data("sift".utf8)
    static let cwdMarker = Data("\"cwd\"".utf8)

    /// A shell command read as its statements and the operators between them, for finding the directory each statement runs in.
    struct Statements {
        let command: String
        let located: [(statement: String, range: Range<String.Index>)]
        /// `joints[k]` is what follows statement `k`: the operator before the next one, or whatever ends the command.
        let joints: [String]

        var last: Int {
            located.count - 1
        }

        /// The command read as the shell reads it, or `nil` where it holds no statement or any compound statement, whose joins are not read here.
        init?(_ text: String) {
            let command = Self.read(text)
            let located = ShellSyntax.statementRanges(of: command).filter { !$0.statement.allSatisfy(\.isWhitespace) }
            guard let last = located.indices.last, !located.contains(where: { InPlaceShape.isCompoundMarker($0.statement) }) else { return nil }
            self.command = command
            self.located = located
            joints = located.indices.map { index in
                let end = index < last ? located[index + 1].range.lowerBound : command.endIndex
                return command[located[index].range.upperBound ..< end].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        /// `text` as the shell reads it: comments out, then each backslash-newline joined away, then, while the whole of it is one subshell or one brace group, its inside.
        ///
        /// Opening the group is exact: a subshell or a brace group starts in the line's own directory and exits with its inside's last pipeline.
        static func read(_ text: String) -> String {
            var command = ShellSyntax.withoutComments(text).replacingOccurrences(of: "\\\n", with: "")
            while let inside = groupInside(command) {
                command = inside
            }
            return command
        }

        /// The inside of `command` where it is exactly one `( … )` or one `{ …; }`, balanced and outside quotes, with nothing but blanks around it, or `nil` where it is anything else.
        ///
        /// Read on ``ShellSyntax/executableText(of:)``, which blanks quoted and escaped text without moving a character, so a parenthesis or brace inside quotes is never counted. A `((` opens arithmetic, not a subshell.
        static func groupInside(_ command: String) -> String? {
            let characters = Array(command)
            let visible = Array(ShellSyntax.executableText(of: command))
            guard visible.count == characters.count,
                  let first = visible.firstIndex(where: { !$0.isWhitespace }),
                  let last = visible.lastIndex(where: { !$0.isWhitespace }),
                  first + 1 < last
            else {
                return nil
            }
            switch visible[first] {
            case "(" where visible[first + 1] != "(":
                guard closingParenthesis(in: visible, from: first) == last else { return nil }
            case "{" where visible[first + 1].isWhitespace:
                let before = visible[first + 1 ..< last].lastIndex { $0 != " " && $0 != "\t" }
                guard closingBrace(in: visible, from: first) == last, let before, ";&\n".contains(visible[before]) else { return nil }
            default:
                return nil
            }
            return String(characters[first + 1 ..< last])
        }

        /// The index of the `)` that closes the `(` at `start`, counting every parenthesis on the way, or `nil` where none does.
        static func closingParenthesis(in visible: [Character], from start: Int) -> Int? {
            var depth = 0
            for index in start ..< visible.count {
                if visible[index] == "(" {
                    depth += 1
                } else if visible[index] == ")" {
                    depth -= 1
                    if depth == 0 {
                        return index
                    }
                }
            }
            return nil
        }

        /// The index of the `}` that closes the `{` at `start`, counting only braces that stand as words where the shell reads one, or `nil` where none does.
        static func closingBrace(in visible: [Character], from start: Int) -> Int? {
            var depth = 0
            for index in start ..< visible.count {
                if opensBrace(at: index, in: visible) {
                    depth += 1
                } else if closesBrace(at: index, in: visible) {
                    depth -= 1
                    if depth == 0 {
                        return index
                    }
                }
            }
            return nil
        }

        /// Whether the character at `index` is a `{` opening a group: a word of its own at the start of a command.
        static func opensBrace(at index: Int, in visible: [Character]) -> Bool {
            guard visible[index] == "{" else { return false }
            let afterIsBlank = index + 1 == visible.count || visible[index + 1].isWhitespace
            return afterIsBlank && (index == 0 || " \t\n;&|({".contains(visible[index - 1]))
        }

        /// Whether the character at `index` is a `}` closing a group: a word of its own after a `;`, a `&`, a newline or another group's close.
        static func closesBrace(at index: Int, in visible: [Character]) -> Bool {
            guard visible[index] == "}" else { return false }
            let afterEnds = index + 1 == visible.count || " \t\n;&|)<>".contains(visible[index + 1])
            let before = visible[..<index].lastIndex { $0 != " " && $0 != "\t" }
            return afterEnds && before.map { ";&\n}".contains(visible[$0]) } ?? false
        }

        /// Whether statement `later` runs only where `earlier` ran and succeeded.
        func depends(_ later: Int, on earlier: Int) -> Bool {
            (earlier == 0 || joints[earlier - 1] != "||") && joints[earlier ..< later].allSatisfy { $0 == "&&" }
        }

        /// The directory statement `index` runs in: `cwd` moved by each plain `cd` before it that `&&` joins to it, or `nil` where another change of directory, or a relative `cd` with no `cwd`, leaves it unknown.
        func directory(before index: Int, cwd: String?) -> String? {
            var directory = cwd.flatMap { $0.hasPrefix("/") ? $0 : nil }
            for earlier in 0 ..< index where TranscriptScan.changesDirectory(located[earlier].statement) {
                let statement = located[earlier].statement
                guard ShellSyntax.segments(of: statement).count == 1, let moved = InPlaceShape.changeOfDirectory(statement), depends(index, on: earlier) else {
                    directory = nil
                    continue
                }
                directory = InPlaceShape.resolve(moved, against: directory)
            }
            return directory
        }
    }

    /// Whether the character at `index` is a `}` standing as a word of its own, the only way a segment split off a brace group can hold its close.
    static func isBraceWord(at index: Int, in visible: [Character]) -> Bool {
        visible[index] == "}" && (index == 0 || visible[index - 1].isWhitespace) && (index + 1 == visible.count || visible[index + 1].isWhitespace)
    }

    /// The `cwd` of the last line of `data` that carries one, read under the same skips the scan makes, or `nil` where no line does.
    ///
    /// Read from the end, and only a line holding a `cwd` key is parsed, so this costs one parse in a transcript that has any.
    static func lastDirectory(in data: Data, skippingSidechains: Bool) -> String? {
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() where line.range(of: cwdMarker) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  !(skippingSidechains && object["isSidechain"] as? Bool == true),
                  !TranscriptRepeats.isRequestBlob(object),
                  let cwd = object["cwd"] as? String, !cwd.isEmpty
            else {
                continue
            }
            return cwd
        }
        return nil
    }

    /// The command a `sift run` segment wraps and the directory its own `--root` names, or `nil` where the segment is not a `sift run`.
    ///
    /// The run's own options come first, and those taking a value are skipped with it; the command follows `--` or, with no terminator, is the first word that is neither an option nor an option's value.
    static func siftRun(ofSegment segment: String) -> (wrapped: [String], root: String?)? {
        let query = ShellQuery(segment)
        let invocation = query.invocation
        guard query.invokesSift, invocation.count > 1, invocation[1] == "run" else { return nil }
        let valued: Set = ["--root", "--without", "--without-line", "--since", "--guard", "--from"]
        let words = Array(invocation.dropFirst(2))
        var root: String?
        var index = 0
        while index < words.count {
            let word = words[index]
            if word == "--" {
                index += 1
                break
            }
            guard word.hasPrefix("-") else { break }
            if valued.contains(word) {
                if word == "--root", index + 1 < words.count {
                    root = words[index + 1]
                }
                index += 2
            } else {
                if word.hasPrefix("--root=") {
                    root = String(word.dropFirst("--root=".count))
                }
                index += 1
            }
        }
        return (Array(words.dropFirst(min(index, words.count))), root)
    }

    /// Holds a call's id where it is an edit of a build input or a validating `sift run` until its result says whether it succeeded, and keeps the newest `xcodebuild` build the context ran.
    static func note(
        call block: [String: Any],
        cwd: String?,
        edits: inout [String: String],
        runs: inout [String: [String]],
        xcodebuild: inout (command: String, directory: String?)?
    ) {
        guard let id = block["id"] as? String, let name = block["name"] as? String else { return }
        let input = block["input"] as? [String: Any] ?? [:]
        if LookupTool.writes(name), let path = input["file_path"] as? String, TreeKey.isBuildInput(path),
           let file = SwiftTree.resolve(path, relativeTo: cwd)
        {
            edits[id] = file
        } else if name == "Bash", let command = input["command"] as? String {
            let directories = validatedDirectories(of: command, cwd: cwd)
            if !directories.isEmpty {
                runs[id] = directories
            }
            if let build = siftXcodebuildBuild(in: command, cwd: cwd) {
                xcodebuild = build
            }
        }
    }
}
