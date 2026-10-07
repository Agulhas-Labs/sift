//
// Copyright © Agulhas Labs
//

import Foundation

/// What a replay tells its caller as it goes: the sessions it will replay, then each one done with the time taken so far, so a run of many minutes reads as slow, not stuck, and shows which sessions cost the time.
public struct ReplayProgress {
    let tell: (String) -> Void
    let started: Date

    func began(_ replayed: Int, of total: Int) {
        let sample = replayed < total ? " (a sample of \(total))" : ""
        tell("replaying \(replayed) sessions\(sample), each with its subagents, against the hook; each can take a minute")
    }

    func finished(_ index: Int, of replayed: Int, contexts: Int, now: Date = Date()) {
        tell("replayed \(index) of \(replayed) sessions (this one \(contexts) \(contexts == 1 ? "context" : "contexts")), \(Self.elapsed(now.timeIntervalSince(started)))")
    }

    /// How long a run has taken, to the second: `elapsed 4s`, `elapsed 2m 5s`, `elapsed 1h 0m 3s`.
    public static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        let (hours, minutes, rest) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        let spelled = hours > 0 ? "\(hours)h \(minutes)m \(rest)s" : minutes > 0 ? "\(minutes)m \(rest)s" : "\(rest)s"
        return "elapsed \(spelled)"
    }
}
