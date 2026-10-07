//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `SIFT_HOME` moves the whole per-user directory, so a probe can keep out of the real `~/.sift`.
struct SiftHomeOverrideTests {
    /// The directory it names is the per-user directory itself, not a parent that gets a `.sift` appended.
    @Test
    func anAbsoluteSiftHomeIsThePerUserDirectory() {
        let environment = ["HOME": "/scratch/depot", "SIFT_HOME": "/scratch/probe-state"]

        #expect(SiftPaths.home(environment: environment).path == "/scratch/probe-state")
        #expect(RootsRegistry.fileURL(in: SiftPaths.home(environment: environment)).path == "/scratch/probe-state/roots.json")
    }

    /// Anything it cannot use is the same as unset, so a stray empty or relative value cannot scatter state under the working directory.
    @Test(arguments: ["", "relative/state"])
    func anEmptyOrRelativeSiftHomeIsIgnored(value: String) {
        let environment = ["HOME": "/scratch/depot", "SIFT_HOME": value]

        #expect(SiftPaths.home(environment: environment).path == "/scratch/depot/.sift")
    }

    /// Unset, the directory is `.sift` under the home, as before.
    @Test
    func withoutSiftHomeThePerUserDirectoryIsDotSiftUnderHome() {
        #expect(SiftPaths.home(environment: ["HOME": "/scratch/depot"]).path == "/scratch/depot/.sift")
    }
}
