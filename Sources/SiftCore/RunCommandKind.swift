//
// Copyright © Agulhas Labs
//

import Foundation

/// Which Swift toolchain command `sift run` was asked to wrap, decided from argv alone.
///
/// Recognition reads the command line, never the output: a filter chosen from what the output happens to look like would change its mind halfway through a build, and an unrecognised command must fail open rather than be guessed at.
public enum RunCommandKind: Sendable {
    case swiftBuild
    case swiftTest
    case xcodebuild
    /// A linter that emits one diagnostic per line in the compiler's own `file:line:col: severity: message` shape — `swiftlint`, and whatever else the repository's config names.
    ///
    /// Such a tool declares no closing verdict line of its own, so this kind's verdict is read from the exit code alone (``RunVerdict/Contract/diagnostics``).
    case linter
    case unrecognized
}

public extension RunCommandKind {
    /// The kind of run `arguments` describes, where `arguments[0]` is the executable.
    ///
    /// `linters` are executable names to recognise as linters beside the built-in `swiftlint`, which is how a repository's own linter is filtered without its name being written here. It is defaulted because most callers ask this of argv alone, in places no repository root is in hand; the entry points that launch the command pass what ``configuredLinters(inRepositoryAt:)`` read.
    static func recognize(_ arguments: [String], linters: Set<String> = []) -> RunCommandKind {
        guard let executable = arguments.first.map({ ($0 as NSString).lastPathComponent }) else {
            return .unrecognized
        }
        guard !arguments.dropFirst().contains(where: questionFlags.contains) else {
            return .unrecognized
        }
        if executable == "xcodebuild" {
            return .xcodebuild
        }
        if executable == "swiftlint" || linters.contains(executable) {
            return .linter
        }
        guard executable == "swift" else {
            return .unrecognized
        }
        // `swift`'s subcommand is its first non-flag argument; anything else (`swift run`, `swift package`)
        // has output this filter makes no claim about.
        for (index, argument) in arguments.enumerated().dropFirst() where !argument.hasPrefix("-") {
            switch argument {
            case "build": return .swiftBuild
            // `swift test list` is the subcommand form of `--list-tests`: its output is the answer, as for a question flag.
            case "test": return testSubcommand(of: arguments.dropFirst(index + 1)) == "list" ? .unrecognized : .swiftTest
            default: return .unrecognized
            }
        }
        return .unrecognized
    }

    /// The linter executable names the repository at `repositoryRoot` adds to the built-in one.
    ///
    /// Outside a repository, or where the config cannot be read at all, no name is added: recognition then falls back to the built-in one, which fails open on everything else exactly as an unrecognised command does. A run is not the place a malformed config is reported — the commands that index say so, and a run that refused over it would have nothing to do with what was asked.
    static func configuredLinters(inRepositoryAt repositoryRoot: URL?) -> Set<String> {
        guard let repositoryRoot, let config = try? SiftConfig.load(repoRoot: repositoryRoot) else {
            return []
        }
        return Set(config.linters)
    }

    /// The first positional argument after `swift test`, which is its subcommand when there is one.
    ///
    /// SwiftPM accepts options before the subcommand (`swift test --skip-build list`), so it is not simply the next argument; and the value of an option that takes one (`--filter list`) is not positional, so it is stepped over.
    static func testSubcommand(of arguments: ArraySlice<String>) -> String? {
        var takesValue = false
        for argument in arguments {
            if takesValue {
                takesValue = false
            } else if argument.hasPrefix("-") {
                takesValue = testOptionsWithValues.contains(argument)
            } else {
                return argument
            }
        }
        return nil
    }

    /// The `swift test` options that take their value as the next argument, from `swift test --help-hidden` (SwiftPM 6.4).
    ///
    /// An option missing here would have its value read as the subcommand, so a run whose value is `list` would be let through unfiltered; `--opt=value` forms are one argument and need no entry.
    private static let testOptionsWithValues: Set<String> = [
        "--package-path", "--cache-path", "--config-path", "--security-path", "--scratch-path", "--build-path",
        "--multiroot-data-file", "--destination", "--experimental-swift-sdks-path", "--swift-sdks-path", "--toolset",
        "--pkg-config-path", "--package-manager-resources-directory", "--manifest-cache",
        "--experimental-prebuilts-download-url", "--experimental-prebuilts-root-cert", "--netrc-file",
        "--resolver-fingerprint-checking", "--resolver-signing-entity-checking", "--default-registry-url",
        "-c", "--configuration", "-Xcc", "-Xswiftc", "-Xlinker", "-Xcxx", "-Xxcbuild", "-Xbuild-tools-swiftc",
        "-Xmanifest", "--triple", "--sdk", "--toolchain", "--arch", "--experimental-swift-sdk", "--swift-sdk",
        "--sanitize", "-j", "--jobs", "--explicit-target-dependency-import-check", "--build-system",
        "-debug-info-format", "--experimental-test-entry-point-path", "--experimental-lto-mode",
        "--experimental-trace-events-file", "--experimental-codesize-profile-output-dir", "--traits",
        "--test-product", "--configuration-path", "--event-stream-output-path", "--event-stream-version",
        "--attachments-path", "--num-workers", "--experimental-maximum-parallelization-width",
        "--maximum-repetitions", "--repeat-until", "-s", "--specifier", "--filter", "--skip", "--xunit-output",
        "--test-output",
    ]

    /// Flags that turn a toolchain invocation into a question about the project rather than a build of it.
    ///
    /// Recognition is otherwise decided by the subcommand, and these are the forms where the subcommand says build and the output *is* the answer: `swift build --show-bin-path` prints one path, `xcodebuild -list` a scheme list. A filter that keeps errors, failures and a summary keeps nothing at all from those, so the caller would be handed a receipt naming a log they then have to read — the whole saving spent backwards. Fail open here for the same reason Docs/Design.md §3 rule 3 fails open on an unrecognised command.
    ///
    /// It is one list rather than one per tool because a flag here means the same thing whichever tool carries it, and a `swift` flag can never appear on an `xcodebuild` line anyway.
    private static let questionFlags: Set<String> = [
        "--show-bin-path", "--show-codecov-path", "--show-dependencies", "--list-tests",
        "-list", "-showBuildSettings", "-showsdks", "-showdestinations", "-showTestPlans",
        "-h", "--help", "-help", "-usage", "--version", "-version",
    ]

    /// How the command is named back to the caller in the filtered answer.
    var label: String {
        switch self {
        case .swiftBuild: "swift build"
        case .swiftTest: "swift test"
        case .xcodebuild: "xcodebuild"
        case .linter: "linter"
        case .unrecognized: "command"
        }
    }

    /// Whether a filter exists for this kind; `false` means the wrapped command's output passes through untouched.
    var isFiltered: Bool {
        self != .unrecognized
    }

    /// How a run of `arguments` files itself in `~/.sift/run.jsonl` — the tool, and the action where argv named one.
    ///
    /// **The action is here because a key that names only the tool is not a population.** `xcodebuild` performs ten different actions, and a key that is the single word `xcodebuild` for all of them makes a build, a test, a clean and an archive one number: a test that failed in every `xcodebuild test` run it was ever part of would read as 4 of 75 beside 55 builds, which is a hard regression served as a flake. On a machine that mostly drives `xcodebuild`, that is most of what `flakes` would otherwise have to say nothing about.
    ///
    /// **The action is read once, by ``RunVerdict/Contract/xcodebuildAction(of:)``, and never guessed.** That reader already exists to decide which `** … **` line the run owes, and it refuses — `nil` — whenever argv leaves the action in doubt. A refusal files the run under the bare tool name, which is exactly the key a line written by an older binary carries, so those runs land in the one bucket that already knows what to do with them rather than being guessed into a population. See ``population(of:)``.
    ///
    /// Only `xcodebuild` earns the second word: `swift build` and `swift test` name one action each already, and a passthrough is `unfiltered` rather than the display label's "command" — it is a distinct outcome, nothing was filtered and no line counts exist for it, and a breakdown naming it after the generic word would read as a fourth toolchain rather than as the absence of one.
    static func logKey(of arguments: [String]) -> String {
        let kind = recognize(arguments)
        guard case .xcodebuild = kind, let action = RunVerdict.Contract.xcodebuildAction(of: arguments) else {
            return kind.toolKey
        }
        return "\(kind.toolKey) \(action)"
    }

    /// The population a run filed under `logKey` counts in, or `nil` when the key does not say which action ran.
    ///
    /// **Two questions in one, because they have one answer.** A run is disqualified from every count when its key names no action, and grouped with the runs it shares a denominator with when it does — and both are decided by the same reading of the key.
    ///
    /// The bare word `xcodebuild` is the disqualifying case, and it is not a legacy shape that will age out: it is what ``logKey(of:)`` still writes whenever argv leaves the action unread, and it is what every `xcodebuild` line an older binary wrote carries. A count over them would not be a population — 55 builds beside 20 test runs are 75, and a test named by 4 of those 75 is a regression printed as a flake. So they are counted out loud into ``RunFailureHistory/conflated`` instead, and this returning `nil` is how.
    ///
    /// **`test` and `test-without-building` are one population; every other action is its own.** Those two are the actions that execute a test bundle — `test-without-building` is the second half of the `build-for-testing` split every CI script writes, running the same suite the same way — so splitting them would cut one repository's test history in two and let a test that failed in all of one half be excluded as broken. `build`, `build-for-testing`, `clean`, `analyze`, `archive`, `install` and `docbuild` execute no test at all: each keeps its own key, forms a population of its own, and will never list a test, which is what `swift build` has always done and is why it needs no rule of its own. Widening the fold to any of them would put runs behind a test's fraction that could not have run it, which is the defect this whole path exists to prevent.
    ///
    /// **Asked of the string rather than of a kind, because the only caller reads a log rather than a run.** `~/.sift/run.jsonl` holds keys, and a line written by an older binary has to answer this question on the same terms as a line written today — a kind that no longer exists, or a key some future version stops writing, is still on disk and still has to be judged.
    static func population(of logKey: String) -> String? {
        let tool = xcodebuild.toolKey
        guard logKey.hasPrefix("\(tool) ") else {
            return logKey == tool ? nil : logKey
        }
        let action = String(logKey.dropFirst(tool.count + 1))
        guard !action.isEmpty else {
            return nil
        }
        // The folded population is identified by one of its own members. Nothing prints this identifier:
        // the report names a population by the keys actually found in it, so a fold of two spellings says
        // both rather than standing 25 runs under the name of whichever one was picked here.
        return testExecutingActions.contains(action) ? "\(tool) test" : logKey
    }

    /// Whether a run of `arguments` executes tests: `swift test`, or `xcodebuild` with an action in the test population.
    static func executesTests(_ arguments: [String]) -> Bool {
        let key = logKey(of: arguments)
        return key == swiftTest.toolKey || population(of: key) == "\(xcodebuild.toolKey) test"
    }

    /// Whether a run of `arguments` builds or tests what it reads: `swift build`, `swift test`, or an `xcodebuild` build or test action — what the stop gate takes a green run of as validating the tree.
    static func buildsOrTests(_ arguments: [String]) -> Bool {
        switch recognize(arguments) {
        case .swiftBuild, .swiftTest:
            return true
        case .xcodebuild:
            let key = logKey(of: arguments)
            return executesTests(arguments) || key.hasSuffix(" build") || key.hasSuffix(" build-for-testing")
        case .linter, .unrecognized:
            return false
        }
    }

    /// Whether a run of `arguments` compiles the tree it reads: a build or test that does not skip the build — what a green-build record and the stop gate's transcript reader take as this tree having been built.
    ///
    /// `swift test --skip-build` and `xcodebuild test-without-building` run whatever binaries an earlier build left, so a green result says nothing about the sources as they stand now.
    static func compilesTree(_ arguments: [String]) -> Bool {
        guard buildsOrTests(arguments) else { return false }
        return switch recognize(arguments) {
        case .xcodebuild:
            !logKey(of: arguments).hasSuffix(" test-without-building")
        default:
            !arguments.contains("--skip-build")
        }
    }

    /// Where a run of `arguments` from `directory` reads its project: `directory` itself, or the one a `swift` `--package-path`, `-C` or `--chdir`, or an `xcodebuild` `-project` or `-workspace`, names instead (the directory holding it) — `nil` where that is spelled through a variable.
    ///
    /// **One reading for the run and for the stop gate.** `sift run` files a green build under the checkout this names, and the gate's transcript reader clears edits in the checkout this names, so the two never disagree about which repository a run built. `directory` is absolute; a relative flag is read against it.
    static func builtDirectory(of arguments: [String], from directory: String) -> String? {
        let xcodebuild = recognize(arguments) == .xcodebuild
        let flags: Set<String> = xcodebuild ? ["-project", "-workspace"] : ["--package-path", "-C", "--chdir"]
        var named: String?
        for (offset, argument) in arguments.enumerated() {
            if flags.contains(argument), offset + 1 < arguments.count {
                named = arguments[offset + 1]
            } else if let equals = argument.firstIndex(of: "="), flags.contains(String(argument[..<equals])) {
                named = String(argument[argument.index(after: equals)...])
            }
        }
        guard let named else { return directory }
        guard !named.contains("$") else { return nil }
        let base = URL(fileURLWithPath: directory, isDirectory: true)
        let resolved = URL(fileURLWithPath: (named as NSString).expandingTildeInPath, relativeTo: base).standardizedFileURL.path
        return xcodebuild ? (resolved as NSString).deletingLastPathComponent : resolved
    }

    /// The `xcodebuild` actions that execute a test bundle, and so the only ones whose runs a test failure can be counted against.
    ///
    /// Read from `xcodebuild -help`'s own action list, and short by design: an action absent from here is one this tool is saying cannot fail a test, and being wrong in that direction costs a test's history rather than a wrong fraction.
    private static let testExecutingActions: Set<String> = ["test", "test-without-building"]
}

extension RunCommandKind {
    /// The part of a run's log key that names the tool, which for every kind but `xcodebuild` is the whole of it.
    ///
    /// Not the display ``label``, though the two agree for three of the four kinds: a label is what the filtered answer calls the command and a key is what a log files it under, and one of them is free to be reworded.
    var toolKey: String {
        switch self {
        case .unrecognized: "unfiltered"
        default: label
        }
    }
}
