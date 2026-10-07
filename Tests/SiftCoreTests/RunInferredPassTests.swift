//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the one pass this tool reads off an exit code rather than a line the tool printed — `xcodebuild -quiet`'s silence over exit 0 — and every condition that keeps that reading from standing over a failure, a banner, or a run without `-quiet` that simply stopped.
///
/// Synthetic lines rather than captures for the failure cases: a `-quiet` run that logged a failure and still exited 0 is the anomaly each test guards against, and no toolchain was measured producing one. What is under test is the reading, so each case holds every other condition clear and the one it names is the only thing standing between the log and an inferred `✔`.
@Suite(.temporaryDirectories)
struct RunInferredPassTests {
    /// An error in the log is a failure the exit code does not get to overrule, whatever `-quiet` suppressed.
    @Test
    func aQuietRunThatLoggedAnErrorIsNotReadAsPassed() {
        let report = Self.report(of: ["/Users/dev/Pallet/Sources/Pallet/Pallet.swift:4:16: error: cannot find 'Forklift' in scope"], invokedAs: Self.quietBuild)

        #expect(report.errors.count == 1)
        #expect(report.testFailures.isEmpty)
        Self.expectNoInferredPass(report)
    }

    /// A failing Swift Testing issue is the same, with no error beside it to lean on.
    @Test
    func aQuietRunThatLoggedAFailingTestIsNotReadAsPassed() {
        let report = Self.report(of: ["✘ Test countIsOne() recorded an issue at PalletTests.swift:5:5: Expectation failed: Pallet().count() == 2"], invokedAs: Self.quietTest)

        #expect(report.errors.isEmpty)
        #expect(report.testFailures.count == 1)
        Self.expectNoInferredPass(report)
    }

    /// An XCTest counter naming a failure is XCTest's half of the run declaring it went badly, even where no assertion line reached the log to name the test.
    @Test
    func aQuietRunWhoseXCTestCounterNamesAFailureIsNotReadAsPassed() {
        let report = Self.report(of: ["Executed 1 test, with 1 failure (0 unexpected) in 0.312 (0.314) seconds"], invokedAs: Self.quietTest)

        #expect(report.errors.isEmpty)
        #expect(report.testFailures.isEmpty)
        Self.expectNoInferredPass(report)
    }

    /// A banner the log actually carries is the verdict, and the exit code never outranks it: `FAILED` stays failed and `INTERRUPTED` stays interrupted, with the line quoted, however clean everything around it looks.
    @Test
    func aBannerTheQuietLogCarriesOutranksItsExitCode() throws {
        let failed = try #require(Self.report(of: ["** BUILD FAILED **"], invokedAs: Self.quietBuild).verdict)
        let interrupted = try #require(Self.report(of: ["** BUILD INTERRUPTED **"], invokedAs: Self.quietBuild).verdict)

        #expect(failed.state == .failed)
        #expect(failed.line == "** BUILD FAILED **")
        #expect(!failed.inferredFromExitCode)
        #expect(interrupted.state == .interrupted)
        #expect(interrupted.line == "** BUILD INTERRUPTED **")
        #expect(!interrupted.inferredFromExitCode)
    }

    /// Without `-quiet`, `xcodebuild` prints its banner whenever it finishes, so a clean-looking log with none is one that stopped — and exit 0 says nothing about which.
    @Test
    func withoutQuietASilentXcodebuildHasNoVerdict() throws {
        let report = try TestSources.runReport("xcodebuild-quiet-build-success", invokedAs: ["xcodebuild", "-scheme", "Pallet-Package", "build"], exitCode: 0)

        #expect(report.verdict == nil)
        #expect(Self.answer(report).hasPrefix("⚠ xcodebuild — exit 0, and no verdict in the log; see the raw output"))
    }

    /// `swift build` prints `Build complete!` on every success, so its silence is never a pass either — and SwiftPM's own `-q` is not `xcodebuild`'s `-quiet`.
    @Test
    func aSilentSwiftBuildHasNoVerdict() {
        #expect(Self.report(of: ["[1/3] Compiling Pallet Pallet.swift"], invokedAs: ["swift", "build"]).verdict == nil)
        #expect(Self.report(of: ["[1/3] Compiling Pallet Pallet.swift"], invokedAs: ["swift", "build", "-q"]).verdict == nil)
    }

    /// The record half of the same silence: a run with no verdict files its failures as unknown, never as `"failed": [], "failed_total": 0` — which is what an inferred pass over the truncated capture would have filed, counted into every denominator `flakes` divides by.
    @Test
    func aSilentRunWithoutQuietIsFiledWithItsFailuresUnknown() throws {
        let outcome = try Self.outcome("xcodebuild-test-execute-truncated", invokedAs: ["xcodebuild", "-scheme", "Depot-Package", "test-without-building"])

        #expect(outcome.reportedTestFailures == nil)
        let entry = try Self.filed(outcome)
        #expect(entry["failed"] == nil)
        #expect(entry["failed_total"] == nil)
    }

    /// And the admission that goes with the reading: under `-quiet` the same truncated capture is the silence of a clean run, so it is filed as one — the case the answer's own note names.
    @Test
    func aSilentQuietRunIsFiledAsTheCleanRunItCannotBeToldApartFrom() throws {
        let outcome = try Self.outcome("xcodebuild-test-execute-truncated", invokedAs: ["xcodebuild", "-scheme", "Depot-Package", "-quiet", "test-without-building"])

        #expect(outcome.reportedTestFailures == [])
        #expect(try Self.filed(outcome)["failed_total"] as? Int == 0)
    }

    /// `-quiet` is read where it stands as a flag of `xcodebuild`'s and nowhere else.
    @Test
    func quietIsReadAsAFlagAndOnlyForXcodebuild() {
        #expect(RunVerdict.Contract.isQuietXcodebuild(["xcodebuild", "-scheme", "S", "build", "-quiet"]))
        #expect(RunVerdict.Contract.isQuietXcodebuild(["xcodebuild", "-quiet", "-scheme", "S", "test"]))
        #expect(RunVerdict.Contract.isQuietXcodebuild(["/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild", "-skipMacroValidation", "-quiet", "test"]))
        #expect(!RunVerdict.Contract.isQuietXcodebuild(["xcodebuild", "-scheme", "S", "build"]))
        // An option's value is not a flag, and neither is a word behind a flag this table does not know to be
        // valueless: both cost a `⚠` over a clean run rather than a `✔` over one that stopped.
        #expect(!RunVerdict.Contract.isQuietXcodebuild(["xcodebuild", "-scheme", "-quiet", "build"]))
        #expect(!RunVerdict.Contract.isQuietXcodebuild(["xcodebuild", "-someNewFlag", "-quiet", "build"]))
        #expect(!RunVerdict.Contract.isQuietXcodebuild(["swift", "build", "-q"]))
        #expect(!RunVerdict.Contract.isQuietXcodebuild(["swift", "test", "-quiet"]))
    }
}

private extension RunInferredPassTests {
    static var quietBuild: [String] {
        ["xcodebuild", "-scheme", "Pallet-Package", "build", "-quiet"]
    }

    static var quietTest: [String] {
        ["xcodebuild", "-scheme", "Pallet-Package", "test", "-quiet"]
    }

    /// `lines` read as the log of `arguments`, which exited 0 — the one exit code the inference reads, stated as the launcher states it.
    static func report(of lines: [String], invokedAs arguments: [String]) -> RunReport {
        var filter = RunOutputFilter(invokedAs: arguments)
        for line in lines {
            filter.consume(line: line)
        }
        return filter.finish(exitCode: 0)
    }

    static func answer(_ report: RunReport) -> String {
        RunReportRenderer(kind: .xcodebuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Pallet"))
            .render(report, exitCode: 0, logURL: nil)
    }

    static func expectNoInferredPass(_ report: RunReport, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(report.verdict?.inferredFromExitCode != true, sourceLocation: sourceLocation)
        #expect(!answer(report).hasPrefix("✔"), sourceLocation: sourceLocation)
    }

    /// A capture run to exit 0 under `arguments`, as `RunLauncher` would hand it on.
    static func outcome(_ capture: String, invokedAs arguments: [String]) throws -> RunOutcome {
        try RunOutcome(
            kind: .xcodebuild,
            logKey: RunCommandKind.logKey(of: arguments),
            exitCode: 0,
            report: TestSources.runReport(capture, invokedAs: arguments, exitCode: 0),
            log: nil,
            repositoryRoot: nil
        )
    }

    /// The line `outcome` files in the run log, with the failures `RunCommand` hands it.
    static func filed(_ outcome: RunOutcome, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any] {
        let file = try TemporaryDirectory.make("run-log").appendingPathComponent("run.jsonl")
        RunUsageLog(fileURL: file).record(
            logKey: outcome.logKey,
            exitCode: outcome.exitCode,
            answer: RunUsageLog.Answer(report: outcome.report, lines: 12, failedTests: outcome.reportedTestFailures),
            repositoryRoot: nil,
            milliseconds: 10
        )
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1, sourceLocation: sourceLocation)
        return try #require(
            try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any],
            sourceLocation: sourceLocation
        )
    }
}
