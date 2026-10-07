//
// Copyright © Agulhas Labs
//

import Foundation
import RegexBuilder

/// Whether a `Bash` command is someone looking at Swift source.
///
/// This exists because without it the metric has a blind spot larger than everything it measures. Counting `Read`, `Grep` and `Glob` describes the *tools*, and the actual habit is at least as often the shell — so a share taken over the tools alone can overstate the real one several times over, measured against the wrong denominator.
///
/// It is also the honest target for the tool descriptions: an "instead of" that names only the file tools names tools that are barely the habit. `grep -n` is faster to type than an MCP call, composes with `-A`/`-B`, and works the same on Swift and everything else. That is the competitor.
///
/// Detection is a heuristic over shell text and is deliberately **conservative** — a command must both point at Swift and read rather than write. Missing one under-counts a miss, which is the direction that flatters, so the patterns below stay broad; but classifying an *edit* as a lookup would invent misses out of ordinary work, which is worse, so the write forms are excluded first and win ties.
public struct ShellInspection {
    /// Whether this command reads Swift source rather than editing, building, or merely mentioning it.
    ///
    /// Judged per pipeline segment, because co-occurrence is not application. `git add A.swift && git commit … | tail -1` mentions a Swift file and runs `tail`, and reads nothing: the segment naming the file does not inspect, and the segment inspecting is reading command output. Requiring one segment to hold *both* the verb and the target is what keeps commit commands like that one from counting as lookups.
    ///
    /// `holdsSource` resolves a path the command was pointed at, and is what lets `grep -rn Symbol Sources/` be seen at all — it names no `.swift` anywhere, so no reading of the text alone can classify it. Passing `nil` means text only, which is the honest default for a caller with no working directory to resolve against.
    ///
    /// The segments judged include those inside command substitutions (`ShellSyntax.executedSegments`), because a lookup run inside `$(…)` is a lookup the index lost like any other.
    public static func isSwiftLookup(_ command: String, holdsSource: ((String) -> Bool)? = nil) -> Bool {
        guard !writes(command) else { return false }
        return ShellSyntax.executedSegments(of: command).contains { ShellQuery($0).readsSwift(holdsSource: holdsSource) }
            || ShellSyntax.executedStatements(of: command).contains { NumberedRead.intoWindows(ShellSyntax.segments(of: $0).map(ShellQuery.init)) }
    }

    /// The same judgement, resolving relative paths against `directory` — a session's working directory, or the `cwd` a transcript line recorded.
    public static func isSwiftLookup(_ command: String, in directory: String?) -> Bool {
        isSwiftLookup(command, holdsSource: SwiftTree.probe(relativeTo: directory))
    }

    /// Whether this command runs the tool itself anywhere the shell runs something — a statement or pipeline stage of its own, or the body of a command substitution.
    ///
    /// One reading for the three that ask it: the hook takes such a call as the advice being taken, the scan counts it as the context reaching the index, and the advisor has nothing to teach it. `echo "$(sift where Foo)"` runs the tool as surely as `sift where Foo` does, and a reading that looked only at the command word of each statement would refuse a context for using the tool and leave it looking, to the diagnosis, like one that cannot. A substitution spelled in single quotes runs nothing, and `grep -rn sift Sources/` is a search for the word (`ShellQuery.invokesSift`).
    public static func invokesSift(_ command: String) -> Bool {
        ShellSyntax.executedSegments(of: command).contains { ShellQuery($0).invokesSift }
    }

    /// The single file the command reads through an explicit line window, or `nil` when it is not that shape.
    ///
    /// The scan asks this so a windowed shell read is scored by the same state machine as a ranged Read — guided when an index call located the file, cold when nothing did — instead of always-cold.
    public static func windowedReadPath(_ command: String, in directory: String?) -> String? {
        windowedReadPath(command, holdsSource: SwiftTree.probe(relativeTo: directory))
    }

    /// The same, against a probe the caller already holds — so a reader asking several questions about one command walks the tree once rather than once per question.
    ///
    /// The stage asked is the one ``ShellAdvice`` takes its advice from, in the pipeline it takes it from, outside every substitution first (`ShellSyntax.hostStatementsFirst`), so a window in a substitution's body names the command only where nothing around it reads Swift. The pipeline is read whole because a window can be cut downstream of the read (`cat View.swift | head -80`), by the one reading of a pipeline's window the advisor asks too (`ShellQuery.windowedReadPath`).
    public static func windowedReadPath(_ command: String, holdsSource: ((String) -> Bool)?) -> String? {
        guard !writes(command) else { return nil }
        for statement in ShellSyntax.hostStatementsFirst(of: command) {
            let stages = ShellSyntax.segments(of: statement).map(ShellQuery.init)
            guard let reader = NumberedRead.reader(of: stages, holdsSource: holdsSource) else { continue }
            return ShellQuery.windowedReadPath(of: stages, readBy: reader)
        }
        return nil
    }

    /// The line window that read prints, or `nil` where the command is no windowed read of one file (``windowedReadPath(_:holdsSource:)``) or its lines cannot be worked out without the file's bytes.
    ///
    /// Asked by the scan to hold a window to the width the hook holds it to (``ListedWindow``).
    public static func window(ofWindowedRead command: String, holdsSource: ((String) -> Bool)?) -> LineWindow? {
        guard !writes(command) else { return nil }
        for statement in ShellSyntax.hostStatementsFirst(of: command) {
            let stages = ShellSyntax.segments(of: statement).map(ShellQuery.init)
            guard let reader = NumberedRead.reader(of: stages, holdsSource: holdsSource) else { continue }
            guard ShellQuery.windowedReadPath(of: stages, readBy: reader) != nil else { return nil }
            let window = LineWindow(stages: stages.map(\.invocation))
            return window.isReadable ? window : nil
        }
        return nil
    }

    /// Whether this command searches another revision's tree for Swift — `git grep … origin/<branch> -- <paths>`, or a tree a variable holds — which is no lookup at either end, since the index holds the working tree only (`ShellQuery.searchesOtherRevision`).
    ///
    /// Asked by the hook of a call it has already found to be no lookup, only to log the rule that let it through: being outside every share is not a reason to be outside the count, and the fire rate is the only evidence there will be that the reading of a revision is not over-firing.
    public static func searchesAnotherRevision(_ command: String, in directory: String?) -> Bool {
        let probe = SwiftTree.probe(relativeTo: directory)
        return ShellSyntax.executedSegments(of: command).contains { ShellQuery($0).searchesAnotherRevisionOfSwift(holdsSource: probe) }
    }

    /// Forms that change a file or run a build.
    ///
    /// Checked first: a script that rewrites a source file often greps it on the way, and calling that a lookup would count the tool's own maintenance as a miss.
    private static func writes(_ command: String) -> Bool {
        if phrases.contains(where: command.contains) {
            return true
        }
        // Matched as words, not as substrings. `rm ` is inside `perform `, `confirm ` and `transform `, so
        // every grep for one of those would read as a write and go uncounted — a whole class of lookup lost to
        // a three-character marker.
        if fileVerbs.contains(where: { ShellQuery.isCommandWord($0, in: command) }) {
            return true
        }
        // An editor rewriting its files in place, however its flags are clustered — the phrases above see only
        // the unclustered `sed -i` and `perl -i`.
        if ShellSyntax.executedSegments(of: command).contains(where: { ShellQuery($0).editsInPlace }) {
            return true
        }
        // A redirect into a Swift file: `… > Foo.swift`, `… >> Foo.swift`.
        return command.contains(redirectExpression)
    }

    /// A redirect into a Swift file: `… > Foo.swift`, `… >> Foo.swift`.
    ///
    /// Built once, and built *from* ``SwiftSourcePath/extensionExpression`` rather than from a copy of its source, so what counts as a Swift file stays one definition.
    ///
    /// `nonisolated(unsafe)` for the reason given on ``SwiftSourcePath/extensionExpression``: `Regex` is not `Sendable`, and every caller of this is serial.
    nonisolated(unsafe) private static let redirectExpression = Regex {
        ">"
        Optionally(">")
        ZeroOrMore(.whitespace)
        ZeroOrMore(.whitespace.inverted)
        SwiftSourcePath.extensionExpression
    }

    /// Write forms whose trailing character is not whitespace, so they cannot be matched as words.
    private static let phrases = [
        "sed -i", "perl -i", "swift build", "swift test", "swift run", "swiftformat", "swiftlint",
        "python3 - <<", "python - <<",
    ]

    /// Commands that move or destroy a file, short enough that a substring match hits ordinary English.
    private static let fileVerbs = ["mv", "cp", "rm", "tee"]
}
