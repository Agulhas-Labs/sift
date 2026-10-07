//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Which servers this machine believes are running, and which of those a person may stop.
///
/// **Why an explicit reap and not a timer.** ``ServerParentWatch`` ends a server whose parent has died, which is a fact; it reaches nothing else. The orphans that remain have *live* parents — the host holds the connection open and has simply stopped speaking — and from inside its own pipe a server cannot tell that apart from a user who went to lunch. An idle timeout would end both, which is an agent losing its index mid-session for a reason it cannot see, built on purpose. So the residue is handed to a person, with the evidence beside it: `sift status` already sees these servers, and this is what makes them actionable without making the tool guess.
///
/// **Three things this refuses to do, and they are the design.** It stops nothing it selected for you — a stop names pids or a root, so there is no form of this command that reaps whatever it finds, and therefore no form of it that becomes an idle timeout with extra steps in somebody's cron. It stops nothing that is demonstrably in use, and prints the evidence rather than the rule. And it stops nothing belonging to the conversation that is asking, because a session reaping its own index mid-run is not a hypothetical: it is a `pkill` aimed at a hung server that matches the live one too, with a different command in front of it.
public struct ServerRoster {
    /// How recently a sign of life protects a server from being stopped.
    ///
    /// Ten minutes, and the number is doing less work than it looks. It is not deciding when a server is dead — nothing here decides that — it is deciding when there is *positive evidence* that one is alive, so that a stop aimed at a pid cannot land on a client mid-conversation. Long enough to cover a pause while an agent thinks or a build runs, short enough that it does not protect the servers this exists for, which have typically answered nothing for hours. The evidence itself is printed either way, so a reader sees the age rather than only the verdict.
    public static let liveWindow: TimeInterval = 600

    /// The servers with an unclosed start whose process is still there, newest first, each carrying why it may or may not be stopped.
    public static func running(
        entries: [ServerLifecycleEntry],
        now: Date,
        callerSession: String?,
        callerTree: Set<Int32>,
        lastAnswered: [String: Date],
        isRunning: (ServerLifecycleEntry) -> Bool = ServerLifecycleReport.isStillRunning
    ) -> [RunningServer] {
        ServerLifecycleReport.unclosedStarts(in: entries)
            .filter { isRunning($0) }
            .map { entry in
                // An answer dated before this server started was given by an earlier server of the same session.
                let answered = entry.session.flatMap { lastAnswered[$0] }.flatMap { $0 >= (entry.date ?? .distantPast) ? $0 : nil }
                let server = RunningServer(
                    pid: entry.pid,
                    root: entry.root,
                    session: entry.session,
                    startedAt: entry.date,
                    lastAnswered: answered,
                    protection: nil
                )
                return server.protected(by: protection(for: server, now: now, callerSession: callerSession, callerTree: callerTree))
            }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    /// Why this server may not be stopped, or `nil` where nothing stands in the way.
    ///
    /// Ordered by how load-bearing the answer is rather than by how cheap it is to compute: a reader who is told only one thing should be told the one that would have cost them most.
    private static func protection(
        for server: RunningServer,
        now: Date,
        callerSession: String?,
        callerTree: Set<Int32>
    ) -> RunningServer.Protection? {
        if let callerSession, let session = server.session, session == callerSession {
            return .ownSession
        }
        if callerTree.contains(server.pid) {
            return .ownProcessTree
        }
        guard let seen = server.lastSignOfLife else { return nil }
        // Clamped at zero and *not* rejected below it. A sign of life stamped in the future is the strongest
        // evidence there is that something is using this server, and reading it as "not recent" would make the
        // stronger evidence destroy the protection the weaker evidence alone would have given: a server
        // started one second ago would be offered for stopping the moment its session's clock ran ahead, which
        // a stepped clock or an unsynchronised machine produces with nothing else being wrong. The listing
        // clamps the same date the same way, so a row and the guard beside it cannot read one timestamp in
        // opposite directions and print maximal liveness over a decision to kill it.
        let age = max(0, now.timeIntervalSince(seen))
        guard age < liveWindow else { return nil }

        return .recentlyAlive(secondsAgo: Int(age.rounded()))
    }

    // MARK: - Selection

    /// The servers `pids` and `root` between them name.
    ///
    /// A root selects its whole subtree, on the same reading ``LogScope`` gives a `--root` argument: repositories nest, and a root that answered "nothing here" while every server sat one component below it would be the silence a reap must never give. Paths are canonicalised at the moment of comparison and never on the way in, which is what makes a symlinked temporary directory compare equal to the path the log recorded.
    ///
    /// A root that matched nothing is carried out as a finding of its own, for the same reason a named pid that matched nothing is: "nothing to stop" and "stopped everything you named" must not be the same answer, and a mistyped path is the likeliest way to get the first while believing the second.
    public static func select(from servers: [RunningServer], pids: [Int32], root: String?) -> Selection {
        let wanted = Set(pids)
        let canonicalRoot = root.map { CanonicalPath.of($0) }
        let matched = servers.filter { server in
            wanted.contains(server.pid) || canonicalRoot.map { under($0, server.root) } == true
        }

        return Selection(
            matched: matched,
            unmatched: pids.filter { pid in !servers.contains { $0.pid == pid } },
            unmatchedRoot: canonicalRoot.flatMap { canonical in
                servers.contains { under(canonical, $0.root) } ? nil : root
            }
        )
    }

    /// Whether `path` is `root` itself or sits beneath it.
    private static func under(_ root: String, _ path: String?) -> Bool {
        guard let path else { return false }
        let canonical = CanonicalPath.of(path)
        return canonical == root || canonical.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Whether `root` names the machine rather than somewhere in it.
    ///
    /// **This closes the one form of this command that would reap whatever it found.** `--root /` is a prefix of every absolute path, so one token would select every server on the machine, and `--root $HOME` the same one level down. That is exactly the shape the design says must not exist, and the guards do not save it: in a cron there is no session id to recognise the caller by, and the ancestry guard never covers a sibling server, so what would remain is a bare idle timeout with a person's name on it. A root at or above the home directory is refused rather than narrowed — those paths are the machine, and this command scopes to a repository.
    ///
    /// A root *below* the home directory is a scope somebody chose, and stays allowed. Putting that in a cron is still an idle timeout over that directory; the difference is that it is a decision made in the open over a named place, which is the line this command is drawn on.
    public static func namesTheWholeMachine(_ root: String, home: URL = SiftPaths.userHome(), accountHome: URL = SiftPaths.accountHome) -> Bool {
        let canonical = CanonicalPath.of(root)
        return canonical == "/"
            || under(canonical, CanonicalPath.of(home.path))
            || under(canonical, CanonicalPath.of(accountHome.path))
    }

    // MARK: - The machine's own answers

    /// When each conversation's server last answered an index call, read from the usage log.
    ///
    /// Keyed on the session rather than on a pid because the usage log records no pid: the session id the server stamps onto every line it writes is the only join between the two ledgers. A server started by hand records no session and therefore gets no evidence here — which reads as "nothing is known", never as "it is idle", and is why the start time counts as a sign of life too.
    ///
    /// **A session is not one server, and the consequence runs one way.** A lifecycle log can hold several server pids under a single session id, so one live server's activity protects every other server that session ever started. That errs towards sparing, which is the safe direction — but it has a cost worth stating rather than discovering: a session cannot reap a server it leaked itself, because its own live server keeps the stale one looking busy and the caller-recognition guard holds it anyway. Clearing one of those is a job for a terminal outside the session, where neither applies.
    public static func lastAnswered(in fileURL: URL) -> [String: Date] {
        guard case let .success(scan) = UsageScan.load(fileURL: fileURL) else { return [:] }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        var newest: [String: Date] = [:]
        for entry in scan.entries {
            guard let session = entry.session, let when = formatter.date(from: entry.stamp) else { continue }
            if let existing = newest[session], existing >= when {
                continue
            }
            newest[session] = when
        }

        return newest
    }

    /// This process and every process that spawned it, so a stop can never reach the caller through its own ancestry.
    ///
    /// Terminated by the set rather than by a length bound: a pid already in it is a chain that has come back on itself, which is the only way a parent walk fails to reach the top, and a count beside that would be a second answer to a question already answered.
    public static func processTree(of pid: Int32 = getpid(), parent: (Int32) -> Int32? = ServerLifecycleReport.parent) -> Set<Int32> {
        var tree: Set<Int32> = []
        var current = pid
        while current > 1, tree.insert(current).inserted {
            guard let next = parent(current) else { break }
            current = next
        }

        return tree
    }

    /// Stops every selected server no guard is holding, and reports all four categories.
    ///
    /// The signal is injected so this can be exercised without a machine full of processes to kill — the guards are the part worth pinning, and a test that had to spawn a server to find out whether one would be spared would only ever pin the easy half.
    public static func stopAll(_ selection: Selection, stop: (Int32) -> Int32? = ServerRoster.stop) -> Outcome {
        var stopped: [RunningServer] = []
        var failed: [Outcome.Failure] = []
        for server in selection.matched where server.protection == nil {
            if let code = stop(server.pid) {
                failed.append(Outcome.Failure(pid: server.pid, code: code))
            } else {
                stopped.append(server)
            }
        }

        return Outcome(
            stopped: stopped,
            failed: failed,
            heldBack: selection.matched.filter { $0.protection != nil },
            unmatched: selection.unmatched,
            unmatchedRoot: selection.unmatchedRoot
        )
    }

    /// Asks `pid` to stop, and reports the `errno` where the kernel would not.
    ///
    /// `SIGTERM` and not `SIGKILL`, which is the whole reason this is worth doing rather than telling somebody to reach for `kill`: the server catches it, writes its own stop line, and the reap is therefore legible afterwards in the same log every other stop is (``ServerSignalWatch``). A `SIGKILL` would leave the shape this tool reads as a crash.
    public static func stop(_ pid: Int32) -> Int32? {
        kill(pid, SIGTERM) == 0 ? nil : errno
    }
}

public extension ServerRoster {
    /// What a stop was asked to act on: the servers it names, and the pids it names that are not there.
    struct Selection: Sendable, Equatable {
        public let matched: [RunningServer]

        /// Pids the caller named that no running server holds — reported rather than silently dropped, because a pid that has already gone is the answer the caller was after.
        public let unmatched: [Int32]

        /// The root the caller named, where it matched no running server at all.
        public let unmatchedRoot: String?

        public init(matched: [RunningServer], unmatched: [Int32], unmatchedRoot: String? = nil) {
            self.matched = matched
            self.unmatched = unmatched
            self.unmatchedRoot = unmatchedRoot
        }
    }

    /// What a stop actually did, once the guards have had their say.
    struct Outcome: Sendable, Equatable {
        public let stopped: [RunningServer]
        public let failed: [Failure]

        /// The selected servers a guard would not let go — carried through so the answer names them rather than quietly stopping fewer things than the caller asked for.
        public let heldBack: [RunningServer]
        public let unmatched: [Int32]

        /// The root the caller named, where it matched nothing.
        public let unmatchedRoot: String?

        public init(stopped: [RunningServer], failed: [Failure], heldBack: [RunningServer], unmatched: [Int32], unmatchedRoot: String? = nil) {
            self.stopped = stopped
            self.failed = failed
            self.heldBack = heldBack
            self.unmatched = unmatched
            self.unmatchedRoot = unmatchedRoot
        }

        /// Whether everything the caller asked for happened — the exit status, so a script can tell a refusal from a reap.
        public var didEverythingAsked: Bool {
            failed.isEmpty && heldBack.isEmpty && unmatched.isEmpty && unmatchedRoot == nil
        }
    }
}

public extension ServerRoster.Outcome {
    /// A server the kernel would not stop, and what it said.
    struct Failure: Sendable, Equatable {
        public let pid: Int32
        public let code: Int32

        public init(pid: Int32, code: Int32) {
            self.pid = pid
            self.code = code
        }
    }
}
