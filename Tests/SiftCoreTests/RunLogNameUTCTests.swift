//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The stamp in a raw log's name is UTC, and the name says so.
@Suite(.temporaryDirectories)
struct RunLogNameUTCTests {
    /// `run-20260930-193451Z-2255c15a.log`: the `Z` is what tells a reader comparing the name with their clock that it is not local time.
    @Test
    func aRawLogsNameMarksItsStampAsUTC() throws {
        let root = try TestSources.makeTempDirectory()

        let outcome = try RunLauncher(workingDirectory: root).run(["sh", "-c", "true"])

        let name = try #require(outcome.log).url.lastPathComponent

        #expect(name.wholeMatch(of: /run-\d{8}-\d{6}Z-[0-9a-f]{8}\.log/) != nil, "\(name) does not carry a Z-suffixed stamp")
    }
}
