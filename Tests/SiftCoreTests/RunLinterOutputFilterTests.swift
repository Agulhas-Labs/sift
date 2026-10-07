//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A linter's one-line-per-violation output is grouped by rule rather than passed through whole.
///
/// A linter used to be `.unrecognized`, so every violation reached the caller as its own line; recognising it groups them the same way an errors listing already groups a build's.
@Suite(.temporaryDirectories)
struct RunLinterOutputFilterTests {
    @Test
    func swiftlintIsRecognisedAsALinterByWhateverPathItIsSpelledWith() {
        #expect(RunCommandKind.recognize(["swiftlint", "lint"]) == .linter)
        #expect(RunCommandKind.recognize(["/opt/homebrew/bin/swiftlint", "lint", "--strict"]) == .linter)
        #expect(RunCommandKind.recognize(["swiftlint", "lint"]).isFiltered)
    }

    /// 34 lines of `swiftlint lint` output reduce to a grouped answer under 15.
    ///
    /// 29 warnings of one signature (the character count each names is elided) collapse to one line with a multiplier, not 29 individual `path:line:col:` listings.
    @Test
    func aLintersRepeatedRuleViolationsGroupByRuleRatherThanListingEach() throws {
        let arguments = ["swiftlint", "lint", "--no-cache", "--reporter", "xcode", "Sources"]

        let report = try TestSources.runReport("swiftlint-lint-violations", invokedAs: arguments, exitCode: 2)
        #expect(report.contract == .diagnostics)
        #expect(report.errors.count == 1)
        #expect(report.warnings.count == 29)
        #expect(report.verdict?.state == .failed)
        // A nonzero exit explained only by warning-severity violations must still be usable, since
        // `swiftlint lint --strict` fails the exit code on a warning without ever spelling it `error:`.
        #expect(report.isUsable(exitCode: 2))

        let answer = RunReportRenderer(kind: .linter, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"))
            .render(report, exitCode: 2, logURL: nil)
        #expect(answer.hasPrefix("✘ linter — exit 2"))
        #expect(answer.contains("Force Cast Violation"))
        #expect(answer.contains("29 warnings · 1 signature"))
        #expect(answer.contains("×29"))
        #expect(!answer.contains(":5:1: warning:"))
        // No closing line is owed by this contract, so none is reported missing.
        #expect(!answer.contains("summary not found"))

        let rawLines = try TestSources.runOutput("swiftlint-lint-violations").split(separator: "\n", omittingEmptySubsequences: false).count
        let answerLines = answer.split(separator: "\n", omittingEmptySubsequences: false).count
        #expect(rawLines == 34)
        #expect(answerLines < 15)
    }

    /// A clean linter run — the common case, and the one `isUsable` must never dump raw over.
    @Test
    func aCleanLinterRunAnswersWithoutTouchingTheRawLog() {
        var filter = RunOutputFilter(invokedAs: ["swiftlint", "lint"])
        filter.consume(line: "Linting Swift files at paths Sources")
        filter.consume(line: "Linting 'Widget.swift' (1/1)")
        filter.consume(line: "Done linting! Found 0 violations, 0 serious in 1 file.")
        let report = filter.finish(exitCode: 0)

        #expect(report.contract == .diagnostics)
        #expect(report.verdict?.state == .succeeded)
        #expect(report.isUsable(exitCode: 0))

        let answer = RunReportRenderer(kind: .linter, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"))
            .render(report, exitCode: 0, logURL: nil)
        #expect(answer.hasPrefix("✔ linter"))
    }

    /// A linter this tool has never heard of is filtered when the repository's config names it, and passes through untouched when it does not.
    ///
    /// Driven through a real run rather than through ``RunCommandKind/recognize(_:linters:)``, because the property is the wiring: the launcher is the one place that holds both the repository root and the command line, and a name read anywhere else reaches no caller.
    @Test
    func anExecutableTheConfigNamesIsFilteredAndAnUnnamedOneIsNot() throws {
        let root = try TestSources.makeTempDirectory()
        let linter = try Self.fakeLinter(in: root)

        let unconfigured = try RunLauncher(workingDirectory: root, repositoryRoot: root).run([linter.path])
        #expect(unconfigured.kind == .unrecognized)
        #expect(unconfigured.report == nil)

        try #"{"linters": ["\#(Self.linterName)"]}"#.write(to: ConfigFile.url(repoRoot: root), atomically: true, encoding: .utf8)

        let configured = try RunLauncher(workingDirectory: root, repositoryRoot: root).run([linter.path])
        #expect(configured.kind == .linter)
        let report = try #require(configured.report)
        #expect(report.contract == .diagnostics)
        #expect(report.errors.count == 1)
        #expect(report.warnings.count == 29)
    }

    /// The config carries the extra names, and still reads past a key it does not model.
    ///
    /// The second half is what lets a config written for this version load in an older binary: an unknown key is ignored rather than rejected, so the new one costs nothing to whoever has not got it yet.
    @Test
    func theConfigCarriesExtraLinterNamesAndReadsPastAKeyItDoesNotModel() throws {
        let root = try TestSources.makeTempDirectory()
        try #"{"linters": ["\#(Self.linterName)"], "exemplars": ["Gizmo"], "exclude": ["Generated"]}"#
            .write(to: ConfigFile.url(repoRoot: root), atomically: true, encoding: .utf8)

        let config = try SiftConfig.load(repoRoot: root)

        #expect(config.linters == [Self.linterName])
        #expect(config.exclude == ["Generated"])
    }

    /// The executable name a repository would configure, standing in for a linter this tool knows nothing about.
    private static var linterName: String {
        "depot-lint"
    }

    /// A stand-in linter that replays the captured transcript and exits as a strict run does.
    ///
    /// Named, because recognition reads the last component of argv's first word: a script under this name is that tool's invocation to everything under test here.
    private static func fakeLinter(in directory: URL) throws -> URL {
        let payload = directory.appendingPathComponent("transcript.txt")
        try TestSources.runOutput("swiftlint-lint-violations").write(to: payload, atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent(linterName)
        try "#!/bin/sh\ncat '\(payload.path)'\nexit 2\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}
