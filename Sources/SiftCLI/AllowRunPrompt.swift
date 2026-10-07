//
// Copyright © Agulhas Labs
//

import Foundation

/// How `install-hook` and `sift install` ask whether to add the lookup allow rules and the `sift run` allow rules, each its own question: on the terminal where both stdin and stdout are terminals, and not at all where either is not.
///
/// Injected so a test can stand in for the person at the terminal, or for their absence.
struct AllowRunPrompt: Sendable {
    /// Whether anyone is there to see the question and answer it — stdin and stdout are both terminals.
    ///
    /// The question goes to stdout, so with stdout redirected (`sift install-hook > log`) it would be invisible while Enter still granted the lookups: nobody is there.
    let isInteractive: Bool

    /// Writes the question and reads one line of answer, `nil` at the end of input.
    let ask: @Sendable (String) -> String?

    /// The process's own terminal: the question to stdout without a newline, the answer from stdin.
    static let standard = AllowRunPrompt(
        isInteractive: canAsk(stdinIsTerminal: isatty(FileHandle.standardInput.fileDescriptor) != 0, stdoutIsTerminal: isatty(FileHandle.standardOutput.fileDescriptor) != 0),
        ask: { question in
            StandardStreams.emitRaw(Data(question.utf8))
            return readLine()
        }
    )

    /// Whether a question can be asked: the answer is read from stdin and the question written to stdout, so both must be a terminal.
    static func canAsk(stdinIsTerminal: Bool, stdoutIsTerminal: Bool) -> Bool {
        stdinIsTerminal && stdoutIsTerminal
    }

    /// The lookups question: what the four lookup rules allow and what those commands touch, with the default yes.
    static var lookupsQuestion: String {
        """
        Let sift's lookups run without a permission prompt? This adds Bash allow rules for `sift digest`, `where`, `search` and `strings`: they write only \
        sift's own index and caches (the repository's `.sift/`, with its `.git/info/exclude` entry, and `~/.sift`) and run git with the repository's fsmonitor and git hooks switched off. A context whose sift tools are deferred can then use the CLI at no prompt. `--no-allow-run` declines without asking.
        [Y/n]\u{20}
        """
    }

    /// The lookups question with the default no it takes after an earlier decline, `lookupsQuestion` otherwise.
    static func lookupsQuestion(defaultingToNo: Bool) -> String {
        guard defaultingToNo else { return lookupsQuestion }
        return lookupsQuestion.replacingOccurrences(of: "[Y/n]", with: "[y/N]")
    }

    /// The runs question: what the four run rules allow and why that is the larger grant, with the default no.
    static var runsQuestion: String {
        """
        Let wrapped builds and tests run without a permission prompt? This adds Bash allow rules for `sift run -- swift build`, `swift test`, `xcodebuild` and `swiftlint`; \
        `sift run` runs the command after it, so they allow those commands through it, and a build or test runs the repository's package manifests and build plugins. A build the hook wraps then runs filtered in the same turn instead of costing an extra one. `--no-allow-run` declines without asking.
        [y/N]\u{20}
        """
    }

    /// Whether `answer` is a yes: `y` or `yes` in any case is, an empty line is `fallback`, and anything else, the end of input included, is no.
    static func accepts(_ answer: String?, defaultsTo fallback: Bool) -> Bool {
        guard let answer else { return false }
        let word = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return word.isEmpty ? fallback : ["y", "yes"].contains(word)
    }
}
