//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

struct ProvedRunGreennessTests {
    private func outcome(_ fixture: String, arguments: [String], exitCode: Int32) throws -> RunOutcome {
        try RunOutcome(
            kind: RunCommandKind.recognize(arguments),
            logKey: "swift test",
            exitCode: exitCode,
            report: TestSources.runReport(fixture, invokedAs: arguments, exitCode: exitCode),
            log: nil,
            repositoryRoot: nil
        )
    }

    @Test func aPassingSuiteProvesItsTree() throws {
        let passed = try outcome("swift-test-pass", arguments: ["swift", "test"], exitCode: 0)

        #expect(passed.provedGreen(testBundles: .undetermined))
    }

    /// The one property the whole ledger rests on: a red run leaves nothing behind for a gate to stand on.
    @Test func aFailingSuiteProvesNothing() throws {
        let failed = try outcome("swift-test-fail", arguments: ["swift", "test"], exitCode: 1)

        #expect(!failed.provedGreen(testBundles: .undetermined))
    }

    @Test func aSuiteThatNeverLinkedProvesNothing() throws {
        let linkError = try outcome("swift-test-linkerror", arguments: ["swift", "test"], exitCode: 1)

        #expect(!linkError.provedGreen(testBundles: .undetermined))
    }

    /// A pass read off an exit code rather than off a line the tool printed is not evidence a gate may skip on.
    @Test func aQuietRunWhoseSilenceWasReadAsAPassProvesNothing() throws {
        let quiet = try outcome("xcodebuild-quiet-test-success", arguments: ["xcodebuild", "test", "-quiet"], exitCode: 0)

        #expect(!quiet.provedGreen(testBundles: .undetermined))
    }

    /// Every count in the log reports a pass, and none of them speaks for the bundle that printed none.
    @Test func aPassWithABundleTheManifestDeclaresMissingProvesNothing() throws {
        let passed = try outcome("swift-test-pass", arguments: ["swift", "test"], exitCode: 0)
        let reported = try #require(passed.report).reportedBundleCount

        #expect(!passed.provedGreen(testBundles: .declaredByManifest(reported + 1)))
    }
}
