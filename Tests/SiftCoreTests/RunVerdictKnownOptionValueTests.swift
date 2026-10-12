//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers an `xcodebuild` option known to take a value consuming the word behind it, so that word is never read as the action.
///
/// `sift run -- xcodebuild build-for-testing -scheme X -derivedDataPath build` is the call the hook hands out, and it used to answer `⚠ … could not tell which verdict the command owed` over a green build, because the `build` behind `-derivedDataPath` was doubted as a possible last action. Only an option no table names still leaves that doubt.
struct RunVerdictKnownOptionValueTests {
    /// A known option's value spelled like an action word leaves the action named before it standing.
    @Test(arguments: [
        (["xcodebuild", "build-for-testing", "-scheme", "Gizmo", "-derivedDataPath", "build"], "build-for-testing"),
        (["xcodebuild", "build", "-scheme", "Gizmo", "-derivedDataPath", "build"], "build"),
        (["xcodebuild", "test", "-scheme", "Gizmo", "-derivedDataPath", "build"], "test"),
        (["xcodebuild", "test", "-scheme", "build"], "test"),
        (["xcodebuild", "build-for-testing", "-configuration", "test"], "build-for-testing"),
        (["xcodebuild", "-scheme", "test", "-project", "Gizmo.xcodeproj"], "build"),
    ])
    func aKnownOptionsValueIsNeverTheAction(arguments: [String], action: String) {
        #expect(RunVerdict.Contract.xcodebuildAction(of: arguments) == action)
    }

    /// An action word behind an option no table names may be that option's value or the last action, so the reading still refuses.
    @Test(arguments: [
        ["xcodebuild", "build-for-testing", "-aFlagAddedAfterThisTableWasWritten", "build"],
        ["xcodebuild", "-aFlagAddedAfterThisTableWasWritten", "test", "-derivedDataPath", "build"],
    ])
    func anUnknownOptionsActionWordStillLeavesTheActionInDoubt(arguments: [String]) {
        #expect(RunVerdict.Contract.xcodebuildAction(of: arguments) == nil)
        #expect(RunVerdict.Contract.of(arguments) == .unreadable)
    }

    /// End to end: a green build under `-derivedDataPath build` is a pass, not a `⚠`.
    @Test
    func aGreenBuildIntoADirectoryNamedBuildIsAPass() throws {
        let invocation = ["xcodebuild", "build", "-scheme", "Gizmo", "-derivedDataPath", "build"]
        let report = try TestSources.runReport("xcodebuild-build-success", invokedAs: invocation)
        let answer = RunReportRenderer(kind: .xcodebuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Depot"))
            .render(report, exitCode: 0, logURL: URL(fileURLWithPath: "/Users/dev/Depot/.sift/runs/run-20260906-194437-1c4de9a2.log"))

        #expect(answer.hasPrefix("✔ xcodebuild\n"))
    }
}
