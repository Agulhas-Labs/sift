//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the spelling of an invoked path that `install-hook` registers: the one the shell used, with dots collapsed and nothing resolved.
@Suite(.temporaryDirectories)
struct InstallHookPathSpellingTests {
    /// A path that exists under `/private` keeps its `/private`, where URL standardizing rewrites `/private/var/…` to `/var/…`.
    @Test
    func aPrivatePrefixIsKept() throws {
        let scratch = try TemporaryDirectory.make("path-spelling")
        let binary = scratch.appendingPathComponent("sift")
        try Data().write(to: binary)
        let spelled = "/private" + binary.path
        try #require(FileManager.default.fileExists(atPath: spelled))

        #expect(InvokedBinary.path(invokedAs: spelled, environment: [:], executable: nil) == spelled)
    }

    /// Dots and doubled slashes collapse without resolving anything.
    @Test
    func dotsCollapseWithoutResolving() {
        #expect(InvokedBinary.path(invokedAs: "/private/tmp/a/../b/./sift", environment: [:], executable: nil) == "/private/tmp/b/sift")
        #expect(InvokedBinary.path(invokedAs: "/tmp/a//b/sift", environment: [:], executable: nil) == "/tmp/a/b/sift")
    }
}
