//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// `reset` looks in the repository's root whatever directory it runs from, so an answer that found nothing names that root rather than "here".
@Suite(.temporaryDirectories)
struct ResetFromSubdirectoryTests {
    @Test
    func nothingToRemoveFromASubdirectoryNamesTheRootItLookedIn() throws {
        let root = try TemporaryDirectory.make("reset-subdirectory")
        try RunWithoutCommandTests.git(["init", "-q"], in: root)
        let subdirectory = root.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)

        let reset = try SiftEngine.reset(directory: subdirectory)

        #expect(CanonicalPath.of(reset.root.path) == CanonicalPath.of(root.path))
        #expect(ResetCommand.line(root: reset.root, removed: reset.removed) == "nothing to remove: there is no .sift/ in \(reset.root.path)")
    }
}
