//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
@testable import SiftCore
import Testing

/// What `--coverage` says of the revision and the repository it is asked to measure, before and after the run.
@Suite(.temporaryDirectories)
struct RunCoverageRevisionTests {
    private static func repository() throws -> URL {
        let root = try TemporaryDirectory.make("revision").resolvingSymlinksInPath()
        try RunWithoutCommandTests.git(["init", "-b", "main"], in: root)
        try RunWithoutCommandTests.git(["-c", "user.email=test@example.com", "-c", "user.name=Tester", "commit", "--allow-empty", "-m", "seed"], in: root)
        return root
    }

    @Test func aRevisionThatNamesNoCommitIsRefusedBeforeTheRunStarts() throws {
        let root = try Self.repository()

        #expect(throws: ValidationError.self) { try RunCoverage.validateRevision("no-such-revision", in: root) }
        try RunCoverage.validateRevision("HEAD", in: root)
        try RunCoverage.validateRevision("main", in: root)
        try RunCoverage.validateRevision(nil, in: root)
        try RunCoverage.validateRevision("no-such-revision", in: nil)
    }

    @Test func aRunOutsideAnyRepositoryAnswersWithARefusalRatherThanNothing() {
        let lines = RunCoverage.section(workingDirectory: URL(fileURLWithPath: "/nowhere"), root: nil, arguments: ["swift", "test", "--enable-code-coverage"], from: nil, treeBefore: nil, started: Date())

        #expect(lines == ["coverage: refused — this directory is in no git repository, so there is no change to measure"])
    }
}
