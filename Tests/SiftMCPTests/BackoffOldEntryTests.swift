//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// A back-off record written before windows varied names none, and holds the full window rather than the short cold-start one.
@Suite(.temporaryDirectories)
struct BackoffOldEntryTests {
    @Test
    func anEntryWithNoWindowHoldsTheFullWindow() throws {
        let directory = try TemporaryDirectory.make("backoff").appendingPathComponent("backoff")
        let root = try TemporaryDirectory.make("repo").path
        let clock = Clock()
        let backoff = InPlaceBackoff(directory: directory, now: { clock.now })
        backoff.noteOverrun(root: root, shape: .read)
        let written = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let file = try #require(written.first)
        var entry = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(entry.removeValue(forKey: "window") != nil)
        try JSONSerialization.data(withJSONObject: entry).write(to: file)
        #expect(Set(entry.keys) == ["root", "shape", "ts"])

        clock.advance(by: 200)
        #expect(InPlaceBackoff.coldStartWindow < 200)
        #expect(backoff.isBackingOff(root: root, shape: .read))
        clock.advance(by: 99)
        #expect(backoff.isBackingOff(root: root, shape: .read))
        clock.advance(by: 1)
        #expect(!backoff.isBackingOff(root: root, shape: .read))
    }
}

private extension BackoffOldEntryTests {
    /// A clock a test moves by hand.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date()

        var now: Date {
            lock.withLock { current }
        }

        func advance(by interval: TimeInterval) {
            lock.withLock { current = current.addingTimeInterval(interval) }
        }
    }
}
