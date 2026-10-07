//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers which shell shapes are offered `sift run --` and, more importantly, which are left alone.
///
/// The refusals carry the weight here. A wrong nudge at the shell costs the hook's credibility rather than one call: every one ignored teaches the caller to ignore the next.
@Suite(.temporaryDirectories)
struct RunAdviceTests {
    private static func call(_ command: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        try #require(RunAdvice.suggestion(for: command), sourceLocation: sourceLocation).call
    }

    /// The whole feature: a bare verify-loop command gains a prefix and nothing else.
    @Test
    func aBareToolchainCommandIsOfferedTheWrapper() throws {
        #expect(try Self.call("swift test") == "sift run -- swift test")
        #expect(try Self.call("swift build") == "sift run -- swift build")
        #expect(try Self.call("swift build -c release") == "sift run -- swift build -c release")
        #expect(
            try Self.call("xcodebuild -scheme Gizmo -destination 'platform=iOS Simulator,name=iPhone 17' test")
                == "sift run -- xcodebuild -scheme Gizmo -destination 'platform=iOS Simulator,name=iPhone 17' test"
        )
    }

    /// The suggestion is the segment *as written*, because re-joining tokens would silently split a quoted argument in two.
    @Test
    func quotingSurvivesIntoTheSuggestedCall() throws {
        #expect(try Self.call(#"swift test --filter "RunAdvice Tests""#) == #"sift run -- swift test --filter "RunAdvice Tests""#)
    }

    /// A directory change in front of the command is not a pipeline — and it is not disposable either: the suggestion carries it, because the same words run in two directories are two different commands.
    ///
    /// Dropping it is wrong: answering `cd Tools/Linter && swift test` with `sift run -- swift test` runs the *root* package's tests, and an agent that took the advice would verify something else entirely and be told it had passed.
    @Test
    func aSequencedCommandKeepsEverythingInFrontOfIt() throws {
        #expect(try Self.call("cd Packages/Kit && swift test") == "cd Packages/Kit && sift run -- swift test")
        #expect(
            try Self.call("cd Tools/Linter && swift test")
                == "cd Tools/Linter && sift run -- swift test"
        )
        #expect(try Self.call("cd /repo; xcodebuild -scheme Gizmo test") == "cd /repo; sift run -- xcodebuild -scheme Gizmo test")
    }

    /// A run inside a group — a subshell or a brace group — is wrapped where it stands, and the grouping is kept exactly as written: the `(` or `{` in front and the `)`, `;` and `}` after, so the suggested line runs the same commands in the same directory and differs only in what comes back.
    ///
    /// A group whose output is piped is a caller managing it, as a bare pipeline is.
    @Test
    func aRunInsideAGroupIsWrappedWithItsGroupingKept() throws {
        #expect(try Self.call("(cd Kit && swift test)") == "(cd Kit && sift run -- swift test)")
        #expect(try Self.call("{ cd Kit && swift test; }") == "{ cd Kit && sift run -- swift test; }")
        #expect(try Self.call("{ cd Kit; swift build; swift test; }") == "{ cd Kit; sift run -- swift build; sift run -- swift test; }")
        #expect(
            try Self.call("(cd Kit && swift build) && (cd App && swift test)")
                == "(cd Kit && sift run -- swift build) && (cd App && sift run -- swift test)"
        )
        #expect(try Self.call(#"(cd Kit && swift test --filter "A B")"#) == #"(cd Kit && sift run -- swift test --filter "A B")"#)
        #expect(RunAdvice.suggestion(for: "(cd Kit && swift test) | tail -5") == nil)
    }

    /// Both halves of a compound verify loop are toolchain statements, and the answer must never drop one.
    ///
    /// Each is wrapped where it stands rather than only the first: `run` passes the exit code through exactly, so `&&` short-circuits on a failing build exactly as it did.
    @Test
    func everyToolchainStatementInACompoundIsWrapped() throws {
        #expect(try Self.call("swift build && swift test") == "sift run -- swift build && sift run -- swift test")
        #expect(
            try Self.call("cd Kit && swift build -c release && swift test")
                == "cd Kit && sift run -- swift build -c release && sift run -- swift test"
        )
    }

    /// A `||` joint is just another statement boundary: each statement is judged on its own, so a build in front of a fallback still draws its own wrapping and the fallback rides along untouched.
    @Test
    func aToolchainStatementInFrontOfAFallbackIsWrapped() throws {
        #expect(try Self.call("swift test || true") == "sift run -- swift test || true")
        #expect(try Self.call("swift test 2>&1 || true") == "sift run -- swift test 2>&1 || true")
        #expect(try Self.call("swift build || swift build -v") == "sift run -- swift build || sift run -- swift build -v")
    }

    /// One statement the wrapping cannot serve silences the whole line, because a half-rewritten line is worse advice than none.
    @Test
    func aCompoundWithOneUnservableHalfDrawsNothing() {
        // The second build is piped, so the caller is managing that output deliberately.
        #expect(RunAdvice.suggestion(for: "swift build && swift test | tail -40") == nil)
        // The second carries an environment prefix the wrapper would try to exec.
        #expect(RunAdvice.suggestion(for: "swift build && SWIFT_DETERMINISTIC_HASHING=1 swift test") == nil)
    }

    /// The payoff and the receipt in one line, so the trade can be judged without running it.
    @Test
    func theAdviceNamesBothTheFailuresAndTheLog() throws {
        let suggestion = try #require(RunAdvice.suggestion(for: "swift test"))

        #expect(suggestion.yields.contains("failures"))
        #expect(suggestion.yields.contains(".sift/runs/"))
        // It stands on no symbol, so the index-resolvability check that guards a `where` suggestion has
        // nothing to say about it — this advice is true whether or not the repo is indexed.
        #expect(suggestion.symbol == nil)
    }

    /// Advising the wrapper to someone already using it is the same false positive `ShellAdvice` closed, and it is checked across the whole line for the same reason.
    @Test
    func anAlreadyWrappedCommandDrawsNoNudge() {
        #expect(RunAdvice.suggestion(for: "sift run -- swift test") == nil)
        #expect(RunAdvice.suggestion(for: "sift run -- xcodebuild -scheme Gizmo test") == nil)
        #expect(RunAdvice.suggestion(for: "/Users/dev/.local/bin/sift run -- swift build") == nil)
        #expect(RunAdvice.suggestion(for: "sift status; swift test") == nil)
    }

    /// A caller who has already pointed the output somewhere is managing it, and interrupting a deliberate pipeline is friction with nothing to offer.
    @Test
    func aPipedOrRedirectedCommandDrawsNoNudge() {
        #expect(RunAdvice.suggestion(for: "swift test 2>&1 | tail -40") == nil)
        #expect(RunAdvice.suggestion(for: "swift build 2>&1 | grep error") == nil)
        #expect(RunAdvice.suggestion(for: "xcodebuild -scheme Gizmo test | xcbeautify") == nil)
        #expect(RunAdvice.suggestion(for: "swift test > /tmp/test.log") == nil)
        #expect(RunAdvice.suggestion(for: "swift build >> build.log 2>&1") == nil)
        #expect(RunAdvice.suggestion(for: "xcodebuild -scheme Gizmo test &> build.log") == nil)
        #expect(RunAdvice.suggestion(for: "swift build >| build.log") == nil)
        #expect(RunAdvice.suggestion(for: "swift build >&build.log") == nil)
    }

    /// A bare `2>&1` names no destination — it is the stream merge `run` performs itself — so it is not a redirect by this reading.
    @Test
    func mergingTheStreamsIsNotRedirectingThem() throws {
        #expect(try Self.call("swift test 2>&1") == "sift run -- swift test 2>&1")
        // `>&log` names a file, but `>&2` still names a stream.
        #expect(try Self.call("swift test >&2") == "sift run -- swift test >&2")
    }

    /// The shared shell grammar underneath both of the two tests above, pinned directly because they rest on it.
    ///
    /// `&` sequences commands, so a splitter that knows only that cuts `2>&1` in half: the first piece ends in a bare `>` that names no destination and the `1` begins a command of its own. Both readings are wrong at once — a stream merge looks like a redirect somewhere, and `&> log` looks like a plain command with the destination in the next piece. `|` pipes, and a splitter that knows only that reads `>| log`, the noclobber override, as a pipeline into a command named `log`.
    @Test
    func aRedirectionIsOneTokenRatherThanTwoCommands() {
        #expect(ShellSyntax.segments(of: "swift test 2>&1").count == 1)
        #expect(ShellSyntax.segments(of: "xcodebuild test &> build.log").count == 1)
        #expect(ShellSyntax.segments(of: "swift build >| build.log").count == 1)
        // And the operators that really do separate commands keep separating them.
        #expect(ShellSyntax.segments(of: "cd Kit && swift test").count == 2)
        #expect(ShellSyntax.segments(of: "swift test | tail -5").count == 2)
        #expect(ShellSyntax.segments(of: "swift test &").count == 1)
    }

    /// Recognition is `RunCommandKind`'s, so a subcommand it makes no claim about draws nothing here either.
    @Test
    func aNonBuildSubcommandDrawsNoNudge() {
        #expect(RunAdvice.suggestion(for: "swift package resolve") == nil)
        #expect(RunAdvice.suggestion(for: "swift package describe") == nil)
        #expect(RunAdvice.suggestion(for: "swift run sift digest .") == nil)
        #expect(RunAdvice.suggestion(for: "swiftformat Sources") == nil)
        #expect(RunAdvice.suggestion(for: "make test") == nil)
    }

    /// A question about the project answers itself, and wrapping it would filter away the answer.
    @Test
    func aProjectQueryDrawsNoNudge() {
        #expect(RunAdvice.suggestion(for: "swift build --show-bin-path") == nil)
        #expect(RunAdvice.suggestion(for: "xcodebuild -list") == nil)
        #expect(RunAdvice.suggestion(for: "xcodebuild -showBuildSettings -scheme Gizmo") == nil)
        #expect(RunAdvice.suggestion(for: "swift test --list-tests") == nil)
    }

    /// Prose *about* a build is not a build: a verb that is not the segment's first token is not a verb.
    ///
    /// The shape of a `claude -p` prompt describing a grep, which a verb read from anywhere in the segment would deny with `where claude`.
    @Test
    func aCommandInsideAQuotedArgumentIsNotAnInvocation() {
        #expect(RunAdvice.suggestion(for: #"echo "swift test""#) == nil)
        #expect(RunAdvice.suggestion(for: #"claude -p "run swift test yourself and report back""#) == nil)
        #expect(RunAdvice.suggestion(for: #"git commit -m "fix: swift test was failing""#) == nil)
    }

    /// A heredoc body is a file being written, not a build being run.
    ///
    /// The splitter breaks on newlines, so every line of the body arrives as a statement of its own, and a suggestion built from them rewrites *the script being written* — the one thing this advice promises never to do, since it is supposed to run the identical commands and differ only in what comes back. `ShellQuery.suppliesInlineText` recognises the shape, and consulting it is the whole fix.
    @Test
    func aScriptBeingWrittenIsNotABuildBeingRun() {
        let heredoc = """
        cat > verify.sh <<'EOF'
        set -e
        swift build && swift test
        EOF
        """

        #expect(RunAdvice.suggestion(for: heredoc) == nil)
        // The single-line spellings of the same thing, which the newline split never even reached.
        #expect(RunAdvice.suggestion(for: "cat <<'EOF' > verify.sh\nswift test\nEOF") == nil)
        #expect(RunAdvice.suggestion(for: "sh -c \"$(cat <<'EOF'\nswift test\nEOF\n)\"") == nil)
    }

    /// No advice beats advice that would not run: `sift run -- FOO=1 swift test` would try to exec the assignment.
    @Test
    func aFormTheWrappingWouldBreakDrawsNoNudge() {
        #expect(RunAdvice.suggestion(for: "SWIFT_DETERMINISTIC_HASHING=1 swift test") == nil)
        #expect(RunAdvice.suggestion(for: "(swift test)") == nil)
    }

    /// One ledger, not two: a build is denied once and allowed on the retry, exactly as a lookup is, and a run of wrappings that draws no index call does not quiet the next one.
    @Test
    func toolchainAdviceDrawsOnTheSameLedger() throws {
        let root = try TemporaryDirectory.make("runadvice")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = AdviceLedger(directory: root.appendingPathComponent("advice", isDirectory: true))

        #expect(ledger.refuse(session: "s", command: "swift test") == .advise)
        #expect(ledger.refuse(session: "s", command: "swift test") == .allow)
        for index in 0 ..< 20 {
            #expect(ledger.refuse(session: "s", command: "swift test --filter F\(index)") == .advise)
        }
        #expect(ledger.refuse(session: "s", command: "xcodebuild -scheme Gizmo test") == .advise)
    }

    /// The two legs of a split gate are run for a verdict read out of the whole log, and nothing offers to filter one.
    ///
    /// Offering the wrapping on every invocation of either leg of `build-for-testing` / `test-without-building` runs against a consuming project's own standing rule that a test run is never piped through a filter that discards anything — and the escape hatch, which works, costs a second run of a command measured in minutes each time.
    @Test
    func aSplitGatesLegsDrawNoWrapping() {
        #expect(RunAdvice.suggestion(
            for: "xcodebuild build-for-testing -scheme GizmoKit-Package -destination 'platform=iOS Simulator,name=iPhone 17'"
        ) == nil)
        #expect(RunAdvice.suggestion(
            for: "xcodebuild test-without-building -scheme GizmoKit-Package -destination 'platform=iOS Simulator,name=iPhone 17'"
        ) == nil)
        // One leg written in a shape the wrapping cannot serve silences the whole line, as a pipe already does.
        #expect(RunAdvice.suggestion(for: "xcodebuild build-for-testing -scheme Gizmo && xcodebuild test-without-building -scheme Gizmo") == nil)
        // A valueless flag in front of the action must not hide it.
        #expect(RunAdvice.suggestion(for: "xcodebuild -quiet -skipMacroValidation test-without-building -scheme Gizmo") == nil)
        // Nor must an option whose *value* is a stem word. `-derivedDataPath build` is an ordinary CI
        // spelling, and the verdict reader answers `nil` on it — deliberately, because a verdict read off
        // the wrong action is a fabricated claim about a log and must fail closed. A nudge has to fail
        // open, and borrowing that reader would put the wrapping straight back on the leg it exists to leave
        // alone: one blocked run of a minutes-long command, which is the cost this whole rule measures.
        #expect(RunAdvice.suggestion(for: "xcodebuild build-for-testing -scheme Gizmo -derivedDataPath build") == nil)
        #expect(RunAdvice.suggestion(
            for: "xcodebuild test-without-building -scheme Gizmo -derivedDataPath build -resultBundlePath test"
        ) == nil)
    }

    /// Every other action keeps its wrapping: what the rule withholds is advice about a gate, not advice about `xcodebuild`.
    @Test
    func theOtherActionsKeepTheirWrapping() {
        #expect(RunAdvice.suggestion(for: "xcodebuild test -scheme Gizmo")?.call == "sift run -- xcodebuild test -scheme Gizmo")
        #expect(RunAdvice.suggestion(for: "xcodebuild build -scheme Gizmo")?.call == "sift run -- xcodebuild build -scheme Gizmo")
        #expect(RunAdvice.suggestion(for: "xcodebuild -scheme Gizmo")?.call == "sift run -- xcodebuild -scheme Gizmo")
    }

    /// A caller already sending the output to a log of their own has said what they want done with it.
    ///
    /// Pinned because it is the other half of the same rule: the suggestion must not interrupt a line whose whole point is that the log is kept.
    @Test
    func aRunAlreadyKeepingItsOwnLogDrawsNoWrapping() {
        #expect(RunAdvice.suggestion(for: "xcodebuild test -scheme Gizmo > /tmp/gate.log 2>&1") == nil)
        #expect(RunAdvice.suggestion(for: "xcodebuild test -scheme Gizmo 2>&1 | tee /tmp/gate.log") == nil)
        #expect(RunAdvice.suggestion(for: "swift test >> /tmp/gate.log") == nil)
    }

    /// Every spelling that keeps standard output in a file, and the near misses that do not — the operator set the gate-leg rule stands on.
    ///
    /// Redirections apply left to right, so the table carries order-sensitive pairs in both directions: `2>&1 >out.log` keeps the output while `>/dev/null 2>&1` throws both streams away, `2>f 1>&2` follows stdout onto the file stderr was pointed at, and a later `>/dev/null` undoes an earlier log. A quoted `>` is an argument, a process substitution is a pipe, and a pipe is a caller trimming the output rather than keeping it.
    @Test(arguments: [
        ("swift build > build.log", true),
        ("swift build >> build.log", true),
        ("swift build 1> build.log", true),
        ("swift build &> build.log", true),
        ("swift build &>> build.log", true),
        ("swift build >| build.log", true),
        ("swift build >&build.log", true),
        ("swift build >& build.log", true),
        (#"swift build \\> build.log"#, true),
        ("swift build 2>&1 >out.log", true),
        ("swift build -j2>log", true),
        (#"swift build > "my log""#, true),
        ("swift build 2>f 1>&2", true),
        ("swift build 2>/dev/null", false),
        ("swift build >/dev/null 2>&1", false),
        ("swift build &>/dev/null", false),
        ("swift build > /dev/null", false),
        ("swift build 2> err.txt", false),
        ("swift build 2>&1", false),
        ("swift build >&2", false),
        ("swift build >& 2", false),
        ("swift build 1>& 2", false),
        ("swift build >& -", false),
        ("swift build 2>/dev/null >& 2", false),
        (#"swift build \> x"#, false),
        ("swift build >build.log >/dev/null", false),
        ("grep -n '>' build.log", false),
        ("swift test > >(tee log)", false),
        ("swift test | tee log", false),
    ])
    func standardOutputKeptInAFileIsReadOffTheOperators(command: String, kept: Bool) {
        #expect(ShellQuery(command).writesOutputToAFile == kept)
    }

    /// An escaped `>` is a literal argument, so the line redirects nothing: it is neither silenced as managing its own output nor recorded as a gate leg, and its wrapping is offered like any bare build's.
    @Test
    func anEscapedRedirectIsAnArgument() {
        #expect(!ShellQuery(#"swift build \> x"#).redirectsOutput)
        #expect(!RunAdvice.silencedAsAGateLeg(#"swift build \> x"#))
        #expect(RunAdvice.suggestion(for: #"swift build \> x"#)?.call == #"sift run -- swift build \> x"#)
        // The escape covers one character: after an escaped backslash the `>` is a redirect again.
        #expect(ShellQuery(#"swift build \\> build.log"#).redirectsOutput)
    }

    /// The two advisors must never contend for one command: a build is a *write* to `ShellInspection` long before it could be a lookup, so a toolchain command is nobody's lookup.
    @Test
    func aToolchainCommandIsNotAlsoALookup() {
        #expect(ShellAdvice.suggestion(for: "swift test") == nil)
        #expect(ShellAdvice.suggestion(for: "xcodebuild -scheme Gizmo test") == nil)
        // And the reverse: a lookup is nobody's toolchain run.
        #expect(RunAdvice.suggestion(for: "grep -n \"func body\" Sources/App/View.swift") == nil)
    }
}
