//
// Copyright © Agulhas Labs
//

import Foundation

/// One line of ``ServerLifecycleLog``, read back.
public struct ServerLifecycleEntry: Equatable, Sendable {
    public let event: String
    public let pid: Int32
    public let stamp: String
    public let reason: String?
    public let detail: String?
    public let seconds: Int?

    /// The directory the server was serving, on a start line.
    ///
    /// Naming a server by pid alone is enough to *report* one, and not enough to decide whether the one you meant to stop is the one you are about to (``ServerRoster``).
    public let root: String?

    /// The conversation the server was serving, on a start line.
    ///
    /// This is what lets a session recognise its own server among several, which is the guard that keeps a reap from taking the caller's index away from it. Absent where the server was started by hand, and that absence is reported rather than assumed away.
    public let session: String?

    /// The process that spawned the server, on a start line: the pid its parent watch is armed on.
    ///
    /// Read before the line is written, so a parent that dies once the line is on record is always one the server knows to watch. A `1` is a server with no parent worth watching, which nothing will end but its input closing or a signal.
    public let parent: Int32?

    /// When this line was written, where the stamp can be read back as one.
    public var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: stamp)
    }

    public init(
        event: String,
        pid: Int32,
        stamp: String,
        reason: String? = nil,
        detail: String? = nil,
        seconds: Int? = nil,
        root: String? = nil,
        session: String? = nil,
        parent: Int32? = nil
    ) {
        self.event = event
        self.pid = pid
        self.stamp = stamp
        self.reason = reason
        self.detail = detail
        self.seconds = seconds
        self.root = root
        self.session = session
        self.parent = parent
    }
}
