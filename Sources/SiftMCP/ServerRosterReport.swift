//
// Copyright © Agulhas Labs
//

import Foundation

/// What `sift servers` prints: the roster, the stop it is about to make, and what came of it.
///
/// **Everything here is written to be read before anything is stopped.** A reap that says only what it did is a reap nobody can check, and the thing being stopped is another session's working index. So a stop with no `--yes` prints the plan and does nothing, every server that was held back is named with the evidence that held it, and a pid or a root that matched nothing is reported rather than passed over — a caller who names something that has already gone has learned something.
///
/// Every one of the three faces opens with the same header, and that is not decoration. Two of the three guards rest on files this command was *told* which copies of to read, and one of them rests on an environment variable that may simply be absent; an answer that named none of those would let a caller read a confident-looking plan whose strongest protection had quietly been switched off (``Evidence``).
public struct ServerRosterReport {
    /// The roster, as `sift servers` prints it with nothing asked of it.
    public static func listing(_ servers: [RunningServer], now: Date, evidence: Evidence) -> String {
        var lines = header(evidence)
        guard !servers.isEmpty else {
            return (lines + ["mcp servers — none this machine believes are running"]).joined(separator: "\n")
        }
        lines.append("mcp servers — \(servers.count) this machine believes \(servers.count == 1 ? "is" : "are") running")
        lines.append(contentsOf: rows(servers, now: now))
        lines.append("stop one with: sift servers --stop --pid <pid>, and add --yes to do it")

        return lines.joined(separator: "\n")
    }

    /// What a `--stop` without `--yes` prints: what it would do, and nothing done.
    public static func plan(_ selection: ServerRoster.Selection, now: Date, evidence: Evidence) -> String {
        let eligible = selection.matched.filter { $0.protection == nil }
        var lines = header(evidence)
        if eligible.isEmpty {
            lines.append("would stop nothing — nothing has been stopped")
        } else {
            lines.append("would stop \(eligible.count) server\(eligible.count == 1 ? "" : "s") — nothing has been stopped; add --yes")
            lines.append(contentsOf: rows(eligible, now: now))
        }
        lines.append(contentsOf: heldBack(selection.matched))
        lines.append(contentsOf: matchedNothing(pids: selection.unmatched, root: selection.unmatchedRoot))

        return lines.joined(separator: "\n")
    }

    /// What a `--stop --yes` prints: what was stopped, what would not be, and what was not there.
    public static func outcome(_ outcome: ServerRoster.Outcome, evidence: Evidence) -> String {
        var lines = header(evidence)
        for server in outcome.stopped {
            lines.append("stopped pid \(server.pid) (SIGTERM)\(server.root.map { " — \($0)" } ?? "")")
        }
        for failure in outcome.failed {
            lines.append("could not stop pid \(failure.pid): errno \(failure.code): \(String(cString: strerror(failure.code)))")
        }
        lines.append(contentsOf: heldBack(outcome.heldBack))
        lines.append(contentsOf: matchedNothing(pids: outcome.unmatched, root: outcome.unmatchedRoot))
        if outcome.stopped.isEmpty, outcome.failed.isEmpty, outcome.heldBack.isEmpty, outcome.unmatchedRoot == nil, outcome.unmatched.isEmpty {
            lines.append("nothing to stop")
        }

        return lines.joined(separator: "\n")
    }

    /// What this answer was read from, and every guard input it could not read.
    ///
    /// On the acting paths as well as the listing, which is the whole point of it being a header rather than a footnote on the one face where nothing happens: a caller who cannot be recognised is *about to stop things*, and that is the moment to say that the guard which would have spared their own server is inoperative.
    private static func header(_ evidence: Evidence) -> [String] {
        var lines = ["read: \(evidence.lifecycleLog) · signs of life: \(evidence.usageLog)"]
        if evidence.sessionsWithActivity == 0 {
            lines.append("  no answered call was readable there, so no server below is protected by recent activity — only by its own start")
        }
        // The roster is built from this file alone, so an unreadable one gives exactly the answer a machine with
        // nothing running gives — a mistyped `--file` and a clean machine would otherwise be one sentence.
        if evidence.lifecycleEntries == 0 {
            lines.append("  no server start or stop was readable in \(evidence.lifecycleLog), so an empty roster here does not show that nothing is running")
        }
        if !evidence.callerIsNamed {
            lines.append("  this session does not name itself (CLAUDE_CODE_SESSION_ID is unset or empty), so no server is recognised as its own")
        }

        return lines
    }

    /// One line per server: the pid, its age, the last thing known to have happened to it, and where it is serving.
    private static func rows(_ servers: [RunningServer], now: Date) -> [String] {
        let pids = servers.map { "pid \($0.pid)" }
        let ages = servers.map { "started \(age($0.startedAt, now: now)) ago" }
        let seen = servers.map { server in
            server.lastAnswered.map { "last answered \(age($0, now: now)) ago" } ?? "answered nothing"
        }
        let pidWidth = pids.map(\.count).max() ?? 0
        let ageWidth = ages.map(\.count).max() ?? 0
        let seenWidth = seen.map(\.count).max() ?? 0

        return servers.indices.map { index in
            "  " + pids[index].rightPadded(pidWidth)
                + "  " + ages[index].rightPadded(ageWidth)
                + "  " + seen[index].rightPadded(seenWidth)
                + "  " + (servers[index].root ?? "(no root recorded)")
                + (servers[index].protection.map { "  — held: \($0.refusal)" } ?? "")
        }
    }

    /// The selected servers that will not be stopped, each with the evidence that held it back.
    private static func heldBack(_ servers: [RunningServer]) -> [String] {
        let held = servers.filter { $0.protection != nil }
        guard !held.isEmpty else { return [] }

        return ["held back:"] + held.map { server in
            "  pid \(server.pid) — \(server.protection?.refusal ?? "")"
        }
    }

    /// What the caller named that is not there — a pid, or a root, on the same footing.
    ///
    /// A root is reported here as a pid is: silence would make a mistyped path and a clean reap the same answer with the same exit status, and that is the silence this command's own design says a reap must never give.
    private static func matchedNothing(pids: [Int32], root: String?) -> [String] {
        pids.map { "no server this machine believes is running holds pid \($0)" }
            + (root.map { ["no server this machine believes is running is serving \($0) or anything beneath it"] } ?? [])
    }

    /// How long ago `date` was, or a stated absence.
    ///
    /// Clamped at zero, which is the same reading the recent-activity guard gives a date in the future (``ServerRoster``). The two must agree: a row that printed maximal liveness beside a decision to stop the server would show a reader the strongest reason to keep it and the tool's intention to kill it, on one line.
    private static func age(_ date: Date?, now: Date) -> String {
        guard let date else { return "an unknown time" }

        return ServerLifecycleReport.duration(Int(max(0, now.timeIntervalSince(date)).rounded()))
    }
}

public extension ServerRosterReport {
    /// The files an answer about servers was read from, and whether the caller could be recognised at all.
    ///
    /// Carried as one value rather than three parameters because all three faces need all of it: each is a thing that can be *absent*, and each absence removes a guard rather than merely a detail.
    struct Evidence: Sendable, Equatable {
        public let lifecycleLog: String

        /// How many start and stop lines the lifecycle log yielded — zero means the roster was built from nothing, whatever the file was.
        public let lifecycleEntries: Int

        public let usageLog: String

        /// How many conversations the usage log yielded an answered call for — zero means the strongest guard input is empty, whatever the file was.
        public let sessionsWithActivity: Int

        /// Whether this caller's own conversation has a name to match against, which is the guard that spares its own server.
        public let callerIsNamed: Bool

        public init(lifecycleLog: String, lifecycleEntries: Int, usageLog: String, sessionsWithActivity: Int, callerIsNamed: Bool) {
            self.lifecycleLog = lifecycleLog
            self.lifecycleEntries = lifecycleEntries
            self.usageLog = usageLog
            self.sessionsWithActivity = sessionsWithActivity
            self.callerIsNamed = callerIsNamed
        }
    }
}
