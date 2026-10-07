//
// Copyright © Agulhas Labs
//

import Foundation

/// One server this machine believes is running, and everything a decision about stopping it rests on.
///
/// Assembled by ``ServerRoster`` from the two ledgers that between them know: ``ServerLifecycleLog`` says a server started and never recorded a stop, and ``UsageLog`` says when it last answered anything. Neither alone is enough — the first knows nothing about whether a client is still there, and the second has no notion of a server at all.
public struct RunningServer: Sendable, Equatable {
    public let pid: Int32

    /// The directory it was started to serve, where the start line named one.
    public let root: String?

    /// The conversation it was started for, where the start line named one.
    public let session: String?

    public let startedAt: Date?

    /// When it last answered an index call, as far as the usage log records.
    public let lastAnswered: Date?

    /// Why this server may not be stopped, or `nil` where nothing stands in the way.
    public let protection: Protection?

    public init(pid: Int32, root: String?, session: String?, startedAt: Date?, lastAnswered: Date?, protection: Protection?) {
        self.pid = pid
        self.root = root
        self.session = session
        self.startedAt = startedAt
        self.lastAnswered = lastAnswered
        self.protection = protection
    }

    /// The most recent thing known to have happened to this server: an answer it served, or failing that its own start.
    ///
    /// Reading both is what closes the hole in reading either. A server that has answered nothing has not been established to be idle — a session thirty seconds old has answered nothing either — and a server whose last answer is hours old has not been established to be gone, which is why this is evidence for a human to read and not a timer.
    public var lastSignOfLife: Date? {
        [startedAt, lastAnswered].compactMap(\.self).max()
    }

    /// The same server, with `protection` decided.
    ///
    /// Split from the initialiser because deciding it needs the assembled server — the sign of life it rests on is read off both of the two dates, and a second copy of that reading is a second thing to keep in step.
    func protected(by protection: Protection?) -> RunningServer {
        RunningServer(pid: pid, root: root, session: session, startedAt: startedAt, lastAnswered: lastAnswered, protection: protection)
    }
}

public extension RunningServer {
    /// Why a running server is not a candidate for stopping.
    ///
    /// Every one of these is a *fact about this machine right now* rather than a policy: whose session it belongs to, whose process tree it sits in, and when it was last known to be doing something. They are printed beside the server they protect, so the refusal is legible as evidence rather than as a rule the tool would not explain.
    enum Protection: Sendable, Equatable {
        /// It is the server serving the conversation that is asking.
        ///
        /// This is not a hypothetical guard. A session can lose its index for hours to a sweep aimed at something else, and a reap command run from inside a session is the shortest path to exactly that.
        case ownSession
        /// It is this process, or one of the processes that spawned it.
        case ownProcessTree
        /// Something happened on it recently enough that its client is evidently still there.
        case recentlyAlive(secondsAgo: Int)

        /// What to print in place of the stop that did not happen.
        public var refusal: String {
            switch self {
            case .ownSession:
                "this session's own server — stopping it would take this session's index away mid-run"
            case .ownProcessTree:
                "this process's own ancestor"
            case let .recentlyAlive(seconds):
                // Through the log's own age vocabulary rather than as a raw count: a listing that says
                // "started 8m ago" beside "514s ago" makes a reader convert one of them to compare them.
                "last sign of life \(ServerLifecycleReport.duration(seconds)) ago, so something is still using it"
            }
        }
    }
}
