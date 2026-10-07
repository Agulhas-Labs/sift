//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the replaced-binary notice: a long-lived server otherwise goes on silently answering from a superseded binary.
@Suite(.temporaryDirectories)
struct BinaryIdentityTests {
    private static func makeFakeBinary() throws -> URL {
        let url = try TemporaryDirectory.make("binary")
            .appendingPathComponent("binary")
        try Data("old code".utf8).write(to: url)
        return url
    }

    @Test
    func anUntouchedBinaryCarriesNoNotice() throws {
        let url = try Self.makeFakeBinary()
        let original = BinaryIdentity.capture(at: url.path)

        #expect(BinaryIdentity.replacementNotice(path: url.path, original: original) == nil)
    }

    /// The upgrade shape exactly: `rm` then `cp` puts a new inode at the same path.
    @Test
    func aReplacedBinaryAnnouncesItself() throws {
        let url = try Self.makeFakeBinary()
        let original = BinaryIdentity.capture(at: url.path)

        try FileManager.default.removeItem(at: url)
        try Data("new code".utf8).write(to: url)

        let notice = BinaryIdentity.replacementNotice(path: url.path, original: original)

        #expect(notice?.contains("replaced") == true)
        #expect(notice?.contains("Restart") == true)
    }

    /// A deleted binary is as replaced as a swapped one — the running code no longer exists on disk.
    @Test
    func aDeletedBinaryAnnouncesItselfToo() throws {
        let url = try Self.makeFakeBinary()
        let original = BinaryIdentity.capture(at: url.path)

        try FileManager.default.removeItem(at: url)

        #expect(BinaryIdentity.replacementNotice(path: url.path, original: original) != nil)
    }

    /// When startup capture itself failed there is no baseline to compare against — silence, not a false alarm.
    @Test
    func anUncapturableOriginalStaysSilent() {
        #expect(BinaryIdentity.replacementNotice(path: "/nonexistent/sift", original: nil) == nil)
    }
}
