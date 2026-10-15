//
// Copyright © Agulhas Labs
//

import Foundation

/// How long a run keeps reading its command's output once the command itself has exited.
///
/// The output pipe reaches its end only when every process holding its write end has closed it, and a command can leave one running that inherited it: `xcodebuild` starts `simctl diagnose` after a failing test, which holds the pipe for up to ten minutes after the verdict. Everything the command wrote before it exited is read in full whatever these say; they bound only the wait on what it left behind.
///
/// Injected rather than fixed, as every wall-clock window here is: a test drives it with small values, and a loaded machine never decides its verdict.
public struct RunOutputPatience: Sendable {
    /// How long the output may stay quiet after the command exited before reading stops.
    public let grace: TimeInterval
    /// How long after the command exited reading stops however busy the output still is, for a holder that keeps writing.
    public let cap: TimeInterval
    /// The clock both windows are measured on.
    public let now: @Sendable () -> Date

    public init(grace: TimeInterval, cap: TimeInterval, now: @escaping @Sendable () -> Date = { Date() }) {
        self.grace = grace
        self.cap = cap
        self.now = now
    }

    /// The patience of every real invocation: two quiet seconds, ten at most.
    public static let standard = RunOutputPatience(grace: 2, cap: 10)
}
