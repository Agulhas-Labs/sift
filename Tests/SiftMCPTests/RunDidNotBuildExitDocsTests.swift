//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// The did-not-build exit belongs to a run that names its tests, and both places a reader learns the exit codes from say so: an unfiltered run whose build fails keeps the wrapped command's exit.
struct RunDidNotBuildExitDocsTests {
    /// `sift run --help` states the did-not-build exit of the run that names its tests, and says a run naming none keeps the wrapped exit.
    @Test
    func theHelpScopesTheDidNotBuildExitToARunThatNamesItsTests() throws {
        let discussion = RunCommand.configuration.discussion
        let exit = try #require(discussion.range(of: "exits \(RunTestSelector.didNotBuildExitCode)."))
        let opening = try #require(discussion.range(of: "a run that names its tests"))
        let clause = discussion[opening.lowerBound ..< exit.upperBound]

        #expect(clause.contains("and the same run, when its build failed"), "the exit-\(RunTestSelector.didNotBuildExitCode) clause is not tied to the run that names its tests: \(clause)")
        #expect(discussion.contains("A run that names no tests keeps the wrapped command's exit when its build fails."))
    }

    /// The agent guide says the did-not-build exit is the filtered run's, not any build failure's.
    @Test
    func theAgentGuideScopesTheDidNotBuildExitToAFilteredRun() throws {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent() // SiftMCPTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent()
        let guide = try String(contentsOf: root.appendingPathComponent("Sift.md"), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")

        #expect(guide.contains("except \(RunTestSelector.exitCode) (a `--filter` run that executed no test) and \(RunTestSelector.didNotBuildExitCode) (such a run that did not build)"))
    }
}
