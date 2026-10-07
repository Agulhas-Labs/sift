//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// An unfiltered `swift test` that executed no test, in a package whose manifest declares test targets, answers `✘ nothing ran` and never stands for its tree, as a filter that matched nothing does.
struct RunUnfilteredZeroTestTests {
    private static let arguments = ["swift", "test"]

    private static func render(_ report: RunReport, bundles: RunTestBundles) -> String {
        RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Gadget"), testBundles: bundles)
            .render(report, exitCode: 0, logURL: nil)
    }

    /// The real capture of a package whose one test target holds no test: both closing counts read 0, and the answer says nothing ran, on its headline and its `totals:` line, and is no proof.
    @Test
    func aRunThatExecutedNoTestOfADeclaredTargetIsNotGreen() throws {
        let report = try TestSources.runReport("swift-test-zero-tests", invokedAs: Self.arguments, exitCode: 0)
        let answer = Self.render(report, bundles: .declaredByManifest(1))
        let lines = answer.split(separator: "\n").map(String.init)

        #expect(lines.first == "✘ swift test — nothing ran: no test executed, though the package declares 1 test target (the command exited 0; sift run exits 4)")
        #expect(lines.contains { $0.hasPrefix("totals: ✘ nothing ran — no test executed in the 1 test target the package declares · ") }, "\(answer)")
        #expect(RunTestSelector.executedNothing(report, exitCode: 0, testBundles: .declaredByManifest(1)))
        let outcome = RunOutcome(kind: .swiftTest, logKey: "swift test", exitCode: 0, report: report, log: nil, repositoryRoot: nil)
        #expect(!outcome.provedGreen(testBundles: .declaredByManifest(1)))
    }

    /// Where nothing outside the log says the package declares a test target, the zero is not judged: the answer keeps the verdict it had.
    @Test
    func aZeroWithNoDeclaredTargetKeepsItsVerdict() throws {
        let report = try TestSources.runReport("swift-test-zero-tests", invokedAs: Self.arguments, exitCode: 0)

        #expect(Self.render(report, bundles: .undetermined).hasPrefix("✔ swift test"))
        #expect(!RunTestSelector.executedNothing(report, exitCode: 0, testBundles: .undetermined))
    }

    /// A passing run that executed tests is not a zero.
    @Test
    func aRunThatExecutedATestIsNotAZero() throws {
        let report = try TestSources.runReport("swift-test-pass", invokedAs: Self.arguments, exitCode: 0)

        #expect(!RunTestSelector.executedNothing(report, exitCode: 0, testBundles: .declaredByManifest(1)))
    }
}
