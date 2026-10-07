//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The Swift files one context's transcript shows it editing since its last green `sift run` build or test.
///
/// A successful `Write`, `Edit` or `MultiEdit` of a `.swift` path counts, in the order its result arrived; a `Bash` call running `sift run` over a build or a test whose result is not an error clears the edits in the repository that run built, since everything before it there was validated by it, and none in any other. A call whose result is an error, or never arrived, counts for nothing, and so does a run whose success the call's result cannot vouch for (``validatedDirectories(of:cwd:)``).
///
/// Read line by line off raw bytes, and a line is parsed only when it could hold such a call or the result of one already pending, so a long session costs a byte search rather than a JSON parse per line.
public struct SwiftEditsSinceGreenRun {
    /// The absolute paths edited since the last green run, oldest first and each once, or `nil` where the transcript cannot be read.
    ///
    /// Skipping sidechains leaves out lines a subagent wrote into its parent's file, which is how a session transcript answers for the session alone.
    public static func files(inTranscript url: URL, skippingSidechains: Bool) -> [String]? {
        scan(transcript: url, skippingSidechains: skippingSidechains)?.files
    }

    /// What one read of a transcript found: the files edited since its last green run, and the last `sift run -- xcodebuild … build` it issued, whether or not that one succeeded.
    ///
    /// The build is the segment of the Bash command as the agent wrote it, with the directory the call ran in, so a block can name it as it was.
    public static func scan(transcript url: URL, skippingSidechains: Bool) -> (files: [String], xcodebuild: (command: String, directory: String?)?)? {
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
                && (line.range(of: swiftMarker) != nil || line.range(of: siftMarker) != nil)
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
        return (edited, xcodebuild)
    }

    /// The directory each `sift run` build or test in a shell command built, for every such run a success of the whole command proves green, or nothing where it proves none.
    ///
    /// The command's result is its last pipeline's, so a run answers for itself only where nothing could have turned its failure into that success: it ends its pipeline (`sift run -- swift build | tail` exits with `tail`'s status), no `||` stands just before it (which can skip it), and only `&&` joins it to every statement after it. A command holding a subshell, a group or any other compound statement proves nothing, since how its pieces join is not read here.
    ///
    /// The directory starts at `cwd`, the one the call ran in, and moves with each plain `cd` before the run that `&&` joins to it. Any other change of directory before the run — a `cd` after a `;`, which a failed `cd` still reaches, a `pushd`, a `cd` in a pipeline or a substitution — or a relative `cd` with no `cwd` to read it from leaves the directory unknown, and that run proves nothing.
    public static func validatedDirectories(of command: String, cwd: String?) -> [String] {
        let located = ShellSyntax.statementRanges(of: command)
        guard let last = located.indices.last, !located.contains(where: { InPlaceShape.isCompoundMarker($0.statement) }) else { return [] }
        // `joints[k]` is what follows statement `k`: the operator before the next one, or whatever ends the command.
        let joints = located.indices.map { index in
            let end = index < last ? located[index + 1].range.lowerBound : command.endIndex
            return command[located[index].range.upperBound ..< end].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        /// Whether statement `later` runs only where `earlier` ran and succeeded.
        func depends(_ later: Int, on earlier: Int) -> Bool {
            (earlier == 0 || joints[earlier - 1] != "||") && joints[earlier ..< later].allSatisfy { $0 == "&&" }
        }
        guard ["", ";"].contains(joints[last]) else { return [] }
        return located.indices.compactMap { index -> String? in
            guard let wrapped = ShellSyntax.segments(of: located[index].statement).last.flatMap(wrappedCommand(ofSegment:)),
                  RunCommandKind.compilesTree(wrapped), depends(last, on: index)
            else {
                return nil
            }
            var directory = cwd.flatMap { $0.hasPrefix("/") ? $0 : nil }
            for earlier in 0 ..< index where TranscriptScan.changesDirectory(located[earlier].statement) {
                let statement = located[earlier].statement
                guard ShellSyntax.segments(of: statement).count == 1, let moved = InPlaceShape.changeOfDirectory(statement), depends(index, on: earlier) else {
                    directory = nil
                    continue
                }
                directory = InPlaceShape.resolve(moved, against: directory)
            }
            return directory.flatMap { RunCommandKind.builtDirectory(of: wrapped, from: $0) }
        }
    }

    /// The last statement or pipeline stage of a shell command that is a `sift run` over an `xcodebuild … build`, as it was written.
    public static func siftXcodebuildBuild(in command: String) -> String? {
        ShellSyntax.executedSegments(of: command).last { segment in
            guard let wrapped = wrappedCommand(ofSegment: segment), RunCommandKind.recognize(wrapped) == .xcodebuild else { return false }
            return RunCommandKind.logKey(of: wrapped).hasSuffix(" build")
        }.map { segment in
            let written = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            return written.hasSuffix(" 2>&1") ? String(written.dropLast(5)) : written
        }
    }
}

private extension SwiftEditsSinceGreenRun {
    static let toolUseMarker = Data("\"tool_use\"".utf8)
    static let toolResultMarker = Data("\"tool_result\"".utf8)
    static let swiftMarker = Data(".swift".utf8)
    static let siftMarker = Data("sift".utf8)

    /// The command a `sift run` segment wraps, or `nil` where the segment is not a `sift run`.
    static func wrappedCommand(ofSegment segment: String) -> [String]? {
        let query = ShellQuery(segment)
        let invocation = query.invocation
        guard query.invokesSift, invocation.count > 1, invocation[1] == "run" else { return nil }
        let rest = invocation.dropFirst(2)
        return rest.firstIndex(of: "--").map { Array(rest[($0 + 1)...]) } ?? Array(rest.drop { $0.hasPrefix("-") })
    }

    /// Holds a call's id where it is an edit of a Swift file or a validating `sift run` until its result says whether it succeeded, and keeps the newest `xcodebuild` build the context ran.
    static func note(
        call block: [String: Any],
        cwd: String?,
        edits: inout [String: String],
        runs: inout [String: [String]],
        xcodebuild: inout (command: String, directory: String?)?
    ) {
        guard let id = block["id"] as? String, let name = block["name"] as? String else { return }
        let input = block["input"] as? [String: Any] ?? [:]
        if LookupTool.writes(name), let path = input["file_path"] as? String, path.hasSuffix(".swift"),
           let file = SwiftTree.resolve(path, relativeTo: cwd)
        {
            edits[id] = file
        } else if name == "Bash", let command = input["command"] as? String {
            let directories = validatedDirectories(of: command, cwd: cwd)
            if !directories.isEmpty {
                runs[id] = directories
            }
            if let build = siftXcodebuildBuild(in: command) {
                xcodebuild = (build, cwd)
            }
        }
    }
}
