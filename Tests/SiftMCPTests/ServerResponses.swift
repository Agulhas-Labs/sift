//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP

/// Lines from a `FileHandle`, waited for with a deadline rather than forever — a server's own stdout in the reexec and handover tests, or any other line stream a test reads from.
///
/// A test waiting on a line that never arrives has to fail rather than hang the suite: a server that has stopped answering, or a reader that has stopped delivering, is exactly the regression such a test is there to catch, and a hang reports nothing at all.
final class ServerResponses: @unchecked Sendable {
    private let mutex = NSLock()
    private var lines: [String] = []

    init(_ handle: FileHandle) {
        let stream = FileHandleLines.lines(from: handle)
        Task { [self] in
            for await line in stream {
                append(line)
            }
        }
    }

    /// The next line, or `nil` when none arrives within `seconds`.
    func next(within seconds: Int) async -> String? {
        for _ in 0 ..< (seconds * 100) {
            if let line = take() {
                return line
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return take()
    }

    private func append(_ line: String) {
        mutex.lock()
        defer { mutex.unlock() }
        lines.append(line)
    }

    private func take() -> String? {
        mutex.lock()
        defer { mutex.unlock() }
        return lines.isEmpty ? nil : lines.removeFirst()
    }
}
