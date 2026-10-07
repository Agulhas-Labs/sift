//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The `sift run` wrapping that would have spared a verify loop its own build log.
///
/// The sibling of ``ShellAdvice``, and deliberately a separate advisor: that one is about the *input* side of a session's context — code being read — and decides between a text match and a resolved answer. This is about the other sink entirely, where a single `xcodebuild test` costs hundreds of lines nobody reads. The two never contend for the same command, because `ShellInspection` classifies every `swift build`/`swift test` as a write before it can be a lookup.
///
/// Recognition is `RunCommandKind`'s, not a second reading of it (Docs/Design.md §3 rule 2: by argv, never by output). What this adds is the step from shell text to argv, and three refusals that only exist at the shell:
///
/// - **Already wrapped.** Advising `sift run` to someone running `sift run` is the same false positive `ShellAdvice` guards against, and it is checked across the whole command line for the same reason.
/// - **Piped or redirected.** `swift test 2>&1 | tail -40`, `xcodebuild … | xcbeautify`, `> build.log` — the caller is already managing the output, and interrupting a deliberate pipeline is friction rather than help. A bare `2>&1` is not that: it names no destination and is the stream merge `run` performs itself.
/// - **Carrying inline text.** `cat > verify.sh <<'EOF' … swift build && swift test … EOF` writes a file; it does not run a build. The splitter breaks on newlines, so a heredoc body arrives as statements and the suggestion would rewrite *the script being written* — the one thing this advice promises never to do, since it is supposed to run the identical commands and differ only in what comes back. `ShellQuery.suppliesInlineText` already recognises the shape for `ShellAdvice`; here it silences the whole line, on the same reasoning as a pipe.
/// - **A gate leg.** `xcodebuild build-for-testing` and `xcodebuild test-without-building` are run for a verdict their caller reads out of the log, and a project that splits its gate this way generally has a standing rule against filtering either half. See ``servesTheVerdictWholesale(_:)``. A build redirected to a log of its own is silenced above and recorded as a leg too (``silencedAsAGateLeg(_:)``).
/// - **A quiet linter.** A linter run carrying `--quiet` has no log for the wrapping to spare: the flag already drops the progress lines, and what is left is the violations — nothing, on a clean tree. So the refusal would cost a turn and spare nothing, and the statement is read like one with no build in it: another toolchain statement on the same line keeps its wrapping. See ``silencedAsAQuietLinter(_:)``.
/// - **Written in a form the advice would break.** The suggested call keeps every statement *as written*, so quoting survives (`--filter "A B"` is one argument, and re-joining tokens would silently make it two). A segment that does not begin with its own verb — an environment prefix, a group opening on the build itself as `(swift test)` does — cannot be prefixed at all, and no advice beats advice that would not run. A build later in a group begins a statement of its own and is wrapped there, the group kept as written: `(cd Kit && sift run -- swift test)`.
///
/// **The suggestion is a replacement for the whole line, not for the part of it that was recognised.** Offering `sift run -- swift test` against `cd Tools/Linter && swift test` looks like the same command and is a different one: it runs the *root* package's tests, so an agent that took the advice would verify the wrong thing and be told nothing had gone wrong. Every recognised statement is wrapped where it stands and the rest of the line is untouched, which also means `swift build && swift test` keeps both halves — `run` passes the exit code through exactly, so `&&` still short-circuits on the first failure.
public struct RunAdvice {
    /// The wrapping for `command`, or `nil` when there is nothing here worth interrupting.
    public static func suggestion(for command: String) -> IndexSuggestion? {
        let segments = ShellSyntax.segments(of: command).map(ShellQuery.init)
        guard !segments.contains(where: { $0.invokesSift || $0.suppliesInlineText }) else {
            return nil
        }
        var insertions: [String.Index] = []
        var statements = 0
        for (statement, range) in ShellSyntax.statementRanges(of: command) {
            statements += 1
            switch reading(of: statement) {
            case .noBuild, .quietLinter:
                continue
            case .silenced:
                return nil
            case let .wrap(offset):
                insertions.append(command.index(range.lowerBound, offsetBy: offset))
            }
        }
        guard !insertions.isEmpty else {
            return nil
        }
        var call = ""
        var cursor = command.startIndex
        for insertion in insertions {
            call += command[cursor ..< insertion] + IndexSuggestion.toolchainRunPrefix
            cursor = insertion
        }
        call += command[cursor...]
        return .forToolchainRun(call, besideOtherStatements: insertions.count < statements)
    }

    /// Each statement of `command` its wrapping prefixes, as the wrapping leaves it — the commands Claude Code matches its permission rules against once the hook rewrites the line in place — or none where `command` draws no wrapping.
    public static func wrappedLegs(of command: String) -> [String] {
        guard suggestion(for: command) != nil else { return [] }
        return ShellSyntax.statementRanges(of: command).compactMap { statement, _ in
            guard case let .wrap(offset) = reading(of: statement) else { return nil }
            let leg = statement[statement.index(statement.startIndex, offsetBy: offset)...]
            let bare = withoutGroupClosers(String(leg))
            return IndexSuggestion.toolchainRunPrefix + bare.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// `leg` without the closing parentheses of a subshell it ends, so `(cd Kit && swift test)` matches as `swift test` and not `swift test)`.
    ///
    /// Only a `)` with no opener inside the leg is the group's own; one balanced within it (`$(…)`, `(…)`) or written in quotes or after a backslash belongs to the command and stays. Conservative: unless nothing but further closers and whitespace follows the first unmatched one, the leg is left exactly as written. A brace group needs nothing here, its `}` being a statement of its own after the `;`.
    private static func withoutGroupClosers(_ leg: String) -> String {
        var depth = 0
        var quote: Character?
        var escaped = false
        var index = leg.startIndex
        while index < leg.endIndex {
            let character = leg[index]
            defer { index = leg.index(after: index) }
            if escaped {
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
            } else if let open = quote {
                if character == open {
                    quote = nil
                }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                if depth > 0 {
                    depth -= 1
                } else {
                    let rest = leg[index...]
                    return rest.allSatisfy { $0 == ")" || $0.isWhitespace } ? String(leg[..<index]) : leg
                }
            }
        }
        return leg
    }

    /// Whether this invocation is a gate leg — a command run for a verdict its caller reads out of the whole log.
    ///
    /// The two halves of the `build-for-testing` / `test-without-building` split every CI script writes. They are named here rather than judged by shape because what distinguishes them is not a property of argv: a project that splits its gate in two is a project reading the run itself, and the lines it reads are easy to lose. Two of them matter most: `** TEST BUILD SUCCEEDED **`, which is what `build-for-testing` prints *instead of* `** BUILD SUCCEEDED **` and which a runner grepping the commoner literal misreports as a failure, and the suite's own `passed` line, which is the number the gate is read off. Both are why the caller ran the leg at all.
    ///
    /// **The suppression is the conservative side of an asymmetry, not a claim that the filter would drop those lines.** ``SiftCore/RunVerdict/Contract`` knows the wording each action owes, so `sift run` reports the verdict for these two as faithfully as for any other. What it cannot know is that this caller wants the log — and the two costs are not comparable: a nudge withheld costs one unfiltered build log, while a nudge that fires on a gate leg costs a *second* run of a command measured in minutes, plus the credibility of every later suggestion. Where the caller has already said so out loud by redirecting to a log file, the wrapping is withheld for the same reason a few lines up.
    ///
    /// **Read off argv directly, and deliberately not through `RunVerdict.Contract.xcodebuildAction`, whose preferences here are the opposite of this one's.** That reader answers `nil` whenever argv leaves the action in doubt, because a *verdict* read off the wrong action is a fabricated claim about a log and must fail closed. A nudge has to fail the other way: `xcodebuild build-for-testing -scheme Gizmo -derivedDataPath build` is an ordinary CI spelling in which `-derivedDataPath` takes a stem word as its value, the doubt latches and never clears, and the action reads as unknown — so borrowing that reader would put the wrapping straight back on the leg it was written to leave alone, at a cost of one blocked run of a minutes-long command.
    ///
    /// A bare `build-for-testing` or `test-without-building` token anywhere in the arguments is the whole test. It over-suppresses by exactly the cases where one of those two words is some option's value, which is a shape nobody writes and which costs an unfiltered build log when they do.
    static func servesTheVerdictWholesale(_ invocation: [String]) -> Bool {
        guard case .xcodebuild = RunCommandKind.recognize(invocation) else {
            return false
        }
        return invocation.dropFirst().contains(where: gateLegs.contains)
    }

    /// Whether the gate-leg rule is what silenced this command, as opposed to one of the other reasons nothing was offered.
    ///
    /// Asked only so the withholding can be recorded. This rule stops the hook speaking and no share counts a toolchain run — `ShellInspection` classifies every build as a *write*, so one is in no denominator to be argued about — which means the fire rate is the only evidence there will ever be that the rule is not over-firing. An unmeasured suppression is the blindness ``SuppressionLog`` exists to prevent, and being outside the share is not a reason to be outside the count.
    ///
    /// A leg is either of the two actions below, or any recognised build already sending its standard output to a log of its own — the caller has said out loud that the whole log is what they will read, which is the same reason arrived at by another route. Stderr alone (`2> err.txt`) and `/dev/null` are not a log kept to be read. A pipe is not one either: `| tail -40` is a caller trimming the output rather than keeping it. Nor is a line some other refusal silenced first, because then this rule is not what fired — so the statements are judged by ``reading(of:)``, in `suggestion`'s order, and the answer is whatever stopped it: a heredoc body is a script being *written*, and in `swift build 2>&1 | tail -5; swift test > t.log` the pipe silences the line before the redirect is ever judged.
    public static func silencedAsAGateLeg(_ command: String) -> Bool {
        let segments = ShellSyntax.segments(of: command).map(ShellQuery.init)
        guard !segments.contains(where: { $0.invokesSift || $0.suppliesInlineText }) else {
            return false
        }
        for (statement, _) in ShellSyntax.statementRanges(of: command) {
            switch reading(of: statement) {
            case .noBuild, .wrap, .quietLinter:
                continue
            case let .silenced(asGateLeg):
                return asGateLeg
            }
        }
        return false
    }

    /// Whether the quiet-linter rule is what left this command without a wrapping, so the withholding can be recorded as a gate leg's is.
    ///
    /// Only where the rule alone is the reason: a line another refusal silences would have drawn nothing anyway, and one where another statement draws a wrapping is not withheld at all.
    public static func silencedAsAQuietLinter(_ command: String) -> Bool {
        let segments = ShellSyntax.segments(of: command).map(ShellQuery.init)
        guard !segments.contains(where: { $0.invokesSift || $0.suppliesInlineText }) else {
            return false
        }
        var quietened = false
        for (statement, _) in ShellSyntax.statementRanges(of: command) {
            switch reading(of: statement) {
            case .noBuild:
                continue
            case .quietLinter:
                quietened = true
            case .wrap, .silenced:
                return false
            }
        }
        return quietened
    }

    /// What `suggestion` makes of one statement, shared with ``silencedAsAGateLeg(_:)`` so the two cannot judge a line in different orders.
    private static func reading(of statement: String) -> StatementReading {
        let stages = ShellSyntax.segments(of: statement).map(ShellQuery.init)
        guard let stage = stages.first(where: { RunCommandKind.recognize($0.invocation).isFiltered }) else {
            return .noBuild
        }
        guard !servesTheVerdictWholesale(stage.invocation) else {
            return .silenced(asGateLeg: true)
        }
        // One toolchain command written in a shape the wrapping cannot serve silences the whole line. A
        // compound whose first build is piped and whose second is not is a caller doing something
        // particular, and the safe reading of particular is silence — a partial rewrite of a line the
        // caller composed deliberately is worse than none.
        guard stages.count == 1, !stage.redirectsOutput else {
            return .silenced(asGateLeg: stages.count == 1 && stage.writesOutputToAFile)
        }
        guard let verb = stage.invocation.first,
              let start = statement.firstIndex(where: { !$0.isWhitespace }),
              statement[start...].hasPrefix(verb)
        else {
            return .silenced(asGateLeg: false)
        }
        // Judged last, so the rule only ever turns a wrapping into none: a quiet lint another refusal silences
        // is silenced by that refusal, and recorded under it.
        guard RunCommandKind.recognize(stage.invocation) != .linter || !stage.invocation.contains("--quiet") else {
            return .quietLinter
        }
        return .wrap(offset: statement.distance(from: statement.startIndex, to: start))
    }

    /// The `xcodebuild` actions run for a verdict rather than for a build, so nothing offers to filter them.
    private static let gateLegs: Set<String> = ["build-for-testing", "test-without-building"]
}

private extension RunAdvice {
    /// What ``RunAdvice/reading(of:)`` makes of one statement.
    enum StatementReading {
        /// No recognised toolchain command — nothing here for either question.
        case noBuild
        /// Wrappable, with the wrapping inserted this many characters into the statement.
        case wrap(offset: Int)
        /// A linter run with `--quiet`, which leaves no log to spare — read as no build, but told apart so the withholding can be recorded.
        case quietLinter
        /// The whole line is silenced here, and whether it was the gate-leg rule that silenced it.
        case silenced(asGateLeg: Bool)
    }
}
