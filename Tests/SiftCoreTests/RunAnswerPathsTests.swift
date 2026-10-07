//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the one thing about a run's answer that belongs to the reader rather than to the run — how it spells its paths — and the rule that it is allowed to decide nothing else.
///
/// The hazard is a `cd` deciding the size of the answer. Read from inside a package, a build of many distinct compile errors names every one of them; read from a directory that is not its parent, where the compiler's own absolute paths survive untouched, the same build can collapse to a line and a `×N`. Identical run, identical exit code, a different answer. With the shortening applied on the way *into* the measurement that picks the form, ``RunFailureCensus/listingBudget`` — a rule about the answer — is charged a width that belongs to the caller's shell.
struct RunAnswerPathsTests {
    /// One build report read from two directories is one answer, differing only in that one states its paths relative.
    ///
    /// Asserted at both forms, because the defect could turn either into the other. At ``builds`` the listing fits the budget once its paths are shortened and does not as the compiler printed them — the straddle a rule charged the shortened width falls into, where the reader inside the package gets all 96 errors and everyone else gets five. The answer is the measured one from both, since what the budget is charged is what the run printed. At ``fewBuilds`` the listing fits in either spelling and is served whole to both.
    @Test
    func aBuildIsTheSameAnswerWhicheverDirectoryItIsReadFrom() {
        let straddling = Self.report(errors: Self.errors(Self.builds))
        let fitting = Self.report(errors: Self.errors(Self.fewBuilds))

        // The straddle *is* the defect, so it is asserted rather than assumed. Charged the reader's own
        // spelling — which is what a shortening applied before the census would hand it — this listing fits
        // the budget from inside the package and does not from anywhere else, and that is the whole of the
        // difference between being given every error and being given five.
        #expect(RunErrorShape.of(Self.shown(straddling.errors), changedFiles: Self.unasked).rendered().count == Self.builds + 1)
        #expect(RunErrorShape.of(straddling.errors, changedFiles: Self.unasked).rendered().count == 1 + RunFailureCensus.signatureCap + 1)

        let inside = Self.answer(straddling, readIn: Self.package)
        let outside = Self.answer(straddling, readIn: Self.elsewhere)

        // The same answer, and the only difference between them is the prefix the reader is standing in.
        #expect(outside.replacingOccurrences(of: Self.package + "/", with: "") == inside)
        // Stated rather than left to the equality, so what this pins is the form and not merely the sameness.
        #expect(Self.lines(inside) == Self.overhead + RunFailureCensus.signatureCap + 1)
        #expect(inside.contains("\(Self.builds) errors · \(Self.builds) signatures · \(Self.builds) files · "))

        // And the listing survives the same move, at a size that fits however its paths are spelled.
        let near = Self.answer(fitting, readIn: Self.package)
        let far = Self.answer(fitting, readIn: Self.elsewhere)

        #expect(far.replacingOccurrences(of: Self.package + "/", with: "") == near)
        #expect(Self.lines(near) == Self.fewBuilds + Self.overhead)
        #expect(near.contains("\(Self.fewBuilds) errors · \(Self.fewBuilds) signatures · \(Self.fewBuilds) files · "))
        #expect(!near.contains("  ×"))
    }

    /// And the same of the test-failure section, where XCTest prints the absolute path of the machine that compiled the file.
    ///
    /// Swift Testing prints a bare filename and has nothing to shorten, which is why this could sit under a corpus that is mostly Swift Testing captures without ever showing itself there.
    @Test
    func aTestRunIsTheSameAnswerWhicheverDirectoryItIsReadFrom() {
        let straddling = Self.report(failures: Self.failures(Self.runs))
        let fitting = Self.report(failures: Self.failures(Self.fewRuns))

        #expect(RunFailureShape.of(Self.shown(straddling.testFailures), changedFiles: Self.unasked).rendered().count == Self.runs * 2 + 1)
        #expect(RunFailureShape.of(Self.asPrinted(straddling.testFailures), changedFiles: Self.unasked).rendered().count
            == 1 + RunFailureCensus.signatureCap * 2 + 1)

        let inside = Self.answer(straddling, readIn: Self.package)
        let outside = Self.answer(straddling, readIn: Self.elsewhere)

        #expect(outside.replacingOccurrences(of: Self.package + "/", with: "") == inside)
        // The sample, then the failing tests by file: its heading, a line for each of the named tests (one to a
        // file here) and the line counting the rest.
        #expect(Self.lines(inside) == Self.runOverhead + RunFailureCensus.signatureCap * 2 + 1 + 1 + RunFailingByFile.nameCap + 1)
        #expect(inside.contains("\(Self.runs) failures · \(Self.runs) signatures · \(Self.runs) files · "))

        let near = Self.answer(fitting, readIn: Self.package)
        let far = Self.answer(fitting, readIn: Self.elsewhere)

        // Two lines to an entry here — the name and its own words — so every failure is named to both readers.
        #expect(far.replacingOccurrences(of: Self.package + "/", with: "") == near)
        #expect(Self.lines(near) == Self.fewRuns * 2 + Self.runOverhead)
        #expect(near.contains("\(Self.fewRuns) failures · \(Self.fewRuns) signatures · \(Self.fewRuns) files · "))
        #expect(!near.contains("  ×"))
    }
}

private extension RunAnswerPathsTests {
    static var package: String {
        "/Users/dev/Widget"
    }

    /// A directory that is neither the package nor above it — a CI step that changed directory, a script building a subpackage, a monorepo root.
    static var elsewhere: String {
        "/tmp/elsewhere"
    }

    /// Errors enough that the listing straddles the budget: about 7.3 KB with the paths relative to the package, and about 9.0 KB as the compiler printed them.
    static let builds = 96

    /// Few enough that the listing fits in either spelling, which is the other side of the same property.
    static let fewBuilds = 40

    /// The same straddle over failures, whose entries are two lines rather than one.
    static let runs = 64

    /// And the same fitting size for them.
    static let fewRuns = 24

    /// Everything a build's answer prints that is not an entry: the headline, the missing-summary note, the blank line before the errors block, the measurement line, and the receipt that closes it.
    static let overhead = 5

    /// The same of a test run's answer, one fewer: the test-failure block opens with no blank line above it.
    static let runOverhead = 4

    static var unasked: RunChangedFiles {
        .unavailable("the working tree was not consulted")
    }

    static var reader: RunAnswerPaths {
        .read(in: URL(fileURLWithPath: package))
    }

    /// One error per file, each with a message nothing else shares — so a listing of them is refused for its size if it is refused at all, and never as repetition.
    static func errors(_ count: Int) -> [RunDiagnostic] {
        (0 ..< count).map { index in
            RunDiagnostic(
                severity: .error,
                path: "\(package)/Sources/Widget/File\(numbered(index)).swift",
                line: 1,
                column: 1,
                message: "cannot find 'symbol\(lettered(index))' in scope"
            )
        }
    }

    /// One failure per file, located the way XCTest locates one: the absolute path of the machine that compiled it.
    static func failures(_ count: Int) -> [RunTestFailure] {
        (0 ..< count).map { index in
            RunTestFailure(
                name: "aTestNamed\(lettered(index))()",
                location: "\(package)/Tests/WidgetTests/File\(numbered(index)).swift:1:1",
                message: "Expectation failed: symbol\(lettered(index)) is not what it should be"
            )
        }
    }

    /// Zero-padded, so every entry is exactly as wide as every other and the arithmetic above is one multiplication.
    static func numbered(_ index: Int) -> String {
        String(format: "%03d", index)
    }

    /// A two-letter token for the part of a message that has to differ, spelled out of letters alone.
    ///
    /// ``RunFailureSignature`` elides digits, so `symbol001` and `symbol002` are one signature: numbering these would have made ninety-six errors one kind, and a listing of them would then be refused as repetition rather than for the width this is measuring.
    static func lettered(_ index: Int) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        return String([letters[index / 26], letters[index % 26]])
    }

    /// The errors with their paths already shortened — what a renderer shortening first would hand the shape, and so what the budget would be charged.
    static func shown(_ errors: [RunDiagnostic]) -> [RunDiagnostic] {
        errors.map { reader.shown($0) }
    }

    /// The same for failures, whose location is shortened rather than whose path is.
    static func shown(_ failures: [RunTestFailure]) -> [RunFailureShape.Failure] {
        failures.map {
            RunFailureShape.Failure(name: $0.name, location: $0.location.map { reader.shown($0) }, message: $0.message)
        }
    }

    static func asPrinted(_ failures: [RunTestFailure]) -> [RunFailureShape.Failure] {
        failures.map { RunFailureShape.Failure(name: $0.name, location: $0.location, message: $0.message) }
    }

    /// A failing `swift build`: no verdict of its own, since the errors are the announcement, over a log the size of the capture this is modelled on.
    static func report(errors: [RunDiagnostic] = [], failures: [RunTestFailure] = []) -> RunReport {
        RunReport(
            errors: errors,
            warnings: [],
            testFailures: failures,
            summaryLines: [],
            contract: .declares(succeeded: "Build complete!", failed: nil),
            verdict: nil,
            tally: nil,
            totalLines: 4062
        )
    }

    static func answer(_ report: RunReport, readIn directory: String) -> String {
        RunReportRenderer(kind: .swiftBuild, workingDirectory: URL(fileURLWithPath: directory))
            .render(report, exitCode: 1, logURL: nil)
    }

    static func lines(_ answer: String) -> Int {
        answer.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}
