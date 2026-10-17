//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the line a run carries when its directory lies inside no git repository: it says there is none, not that the inventory could not be read.
@Suite(.temporaryDirectories)
struct RunInventoryNoGitTests {
    /// A package directory with no `.git` above it has no index to read, and the line says so under that head.
    @Test
    func aRunOutsideAnyRepositoryNamesTheMissingRepository() throws {
        let directory = try TemporaryDirectory.make("inventory-nogit").resolvingSymlinksInPath()
        guard GitContext.discoverRoot(from: directory) == nil else {
            Issue.record("\(directory.path) lies inside a git repository")
            return
        }

        let check = RunInventoryCheck.check(RunTestOutcomes(), loggedAt: nil, repositoryRoot: directory)

        guard case let .skipped(reason) = check else {
            Issue.record("expected .skipped, got \(check)")
            return
        }

        #expect(reason == "\(CanonicalPath.of(directory.path)) is not inside a git repository, and the inventory is read from sift's index, which needs one")
        #expect(!reason.contains("could not be read"))
    }
}
