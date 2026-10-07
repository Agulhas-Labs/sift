//
// Copyright © Agulhas Labs
//

import Foundation
import Testing

/// A stub child that ignores the request to terminate, for a test that a deadline kills and reaps such a child, and the attempts that test makes until one of its children is ready before the deadline.
///
/// The deadline runs inside the code under test, from the child's launch, so the test cannot hold it until the child is ready. On a loaded machine a child can be stopped before it has set itself to ignore the request, or before it has written its pid; that attempt proves nothing about a child that ignores it, and is made again rather than read.
struct DeadlineChild {
    /// How many attempts a test makes before it fails for want of a child that was ready in time.
    static let attempts = 3

    /// The script a stub runs to become the child: it ignores the request to terminate, then writes its pid to `file` whole, through a rename, so a pid read there proves the child got that far.
    static func prelude(writingPidTo file: URL) -> String {
        "trap '' TERM; echo $$ > '\(file.path).part' && mv '\(file.path).part' '\(file.path)'; exec sleep 100000"
    }

    /// The pid a stub wrote to `file`, if it has written one yet.
    static func pid(in file: URL) -> pid_t? {
        (try? String(contentsOf: file, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// `attempt` run with a fresh pid file until the child it launched wrote its pid before the deadline stopped it, at most ``attempts`` times: that attempt's outcome and the pid, else the last outcome and `nil`.
    ///
    /// The code under test has stopped and reaped its child before `attempt` returns, so the pid file is read once, as the child left it; no wait for it can change what it holds.
    ///
    /// Except where the code under test left its child running: an attempt that returns before the child wrote its pid reads as inconclusive, and a child it never stopped writes it later. So before returning, every earlier attempt's pid file is read again, after up to ``grace`` for one still empty, and a child that wrote its pid there is expected gone as the returned one is. Worst case, the grace adds seconds to attempts each bounded by the caller's watchdog: three of 30 s and 2 s more, inside a two-minute limit.
    static func ready<Outcome>(sourceLocation: SourceLocation = #_sourceLocation, _ attempt: (URL) async throws -> Outcome) async throws -> (outcome: Outcome, pid: pid_t?) {
        var earlier: [URL] = []
        while true {
            let file = try TemporaryDirectory.make("hung").appendingPathComponent("child.pid")
            let outcome = try await attempt(file)
            let pid = pid(in: file)
            if pid != nil || earlier.count + 1 == attempts {
                try await expectNoneLeft(earlier, sourceLocation: sourceLocation)
                return (outcome, pid)
            }
            earlier.append(file)
        }
    }

    /// How long the attempts wait, once one is ready, for an earlier attempt's child to write a pid it had not written when that attempt returned.
    static let grace: TimeInterval = 2

    /// Expects no child of the attempts that wrote to `files` to be running, waiting up to ``grace`` for a file still empty, and kills any that is.
    private static func expectNoneLeft(_ files: [URL], sourceLocation: SourceLocation) async throws {
        let until = Date(timeIntervalSinceNow: grace)
        while files.contains(where: { pid(in: $0) == nil }), Date() < until {
            try await Task.sleep(for: .milliseconds(50))
        }
        for pid in files.compactMap(pid(in:)) {
            expectReaped(pid, sourceLocation: sourceLocation)
        }
    }

    /// Expects the child `pid` to have been killed and reaped, and kills it where it was not.
    static func expectGone(_ pid: pid_t?, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let pid = try #require(pid, "no child of \(attempts) attempts wrote its pid before the deadline stopped it", sourceLocation: sourceLocation)
        expectReaped(pid, sourceLocation: sourceLocation)
    }

    /// Expects `pid` to name no process, killing one it still names.
    private static func expectReaped(_ pid: pid_t, sourceLocation: SourceLocation) {
        errno = 0
        let gone = kill(pid, 0) == -1 && errno == ESRCH
        #expect(gone, "the child \(pid) is still running or unreaped", sourceLocation: sourceLocation)
        if !gone {
            kill(pid, SIGKILL)
        }
    }
}
