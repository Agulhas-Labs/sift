//
// Copyright © Agulhas Labs
//

import Foundation
import Testing

/// The subprocess tests launch this run's own `sift`, whichever scratch path the build was given.
struct BuiltExecutableTests {
    /// The executable sits in the products directory of the test bundle whose code is running, which is the build of the code under test.
    ///
    /// The running bundle is found from the loaded image this code is in rather than through `Bundle`, so the check does not restate the lookup it checks. Compared with symlinks resolved, because the default products directory is reached through one: a binary found under the package's fixed `.build/debug` agrees with a default run, and is exactly what a run under another scratch path must not launch.
    @Test
    func theExecutableIsTheOneBuiltBesideTheRunningTestBundle() throws {
        var image = Dl_info()
        try #require(dladdr(#dsohandle, &image) != 0 && image.dli_fname != nil, "the running test image could not be located")
        let imagePath = String(cString: image.dli_fname)
        var bundle = URL(fileURLWithPath: imagePath)
        while bundle.pathExtension != "xctest", bundle.pathComponents.count > 1 {
            bundle.deleteLastPathComponent()
        }
        try #require(bundle.pathExtension == "xctest", "the running test image \(imagePath) sits in no test bundle")
        let sift = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)")

        #expect(sift.deletingLastPathComponent().resolvingSymlinksInPath() == bundle.deletingLastPathComponent().resolvingSymlinksInPath())
    }
}
