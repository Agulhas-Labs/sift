//
// Copyright © Agulhas Labs
//

import Foundation
import Testing

/// The one suite without a temporary-directory scope, for the one property that needs its absence.
struct UnscopedTemporaryDirectoryTests {
    /// Asked for outside any scope, the helper refuses — records the issue and makes nothing — rather than make a directory no scope would ever remove.
    @Test func aDirectoryAskedForOutsideAnyScopeIsRefusedAndNotMade() throws {
        withKnownIssue {
            _ = try TemporaryDirectory.make("unscoped")
        }

        #expect(try TemporaryDirectory.entries(containing: "sift-unscoped-").isEmpty)
    }
}
