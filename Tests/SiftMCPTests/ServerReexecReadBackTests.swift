//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Pins the probe ``ServerReexec`` asks a replacement with directly, on small commands, rather than only through a real replacement.
///
/// Nothing else here reaches this function except through the default `ask` closure, which the in-process tests never exercise (they inject an `Answer` directly) and the subprocess tests only ever meet answering `.printed` (the real binary) or exiting 64 (a shell script) — never a timeout, a kill, a missing path or a print larger than a pipe holds. So a mutation that read a timeout as `.refused` instead of `.unanswered`, or dropped the concurrent reader that keeps up with a large print, would pass every other test in the suite.
///
/// Every scenario here runs a binary the machine already has — `/bin/sh`, `/usr/bin/head` — rather than a freshly written throwaway file. A file this machine has never launched before pays a first-launch assessment cost that ranges from a couple of hundred milliseconds to tens of seconds (Design.md's own stated limit), which is exactly the moment these tests exist to pin and not something they should be measuring by accident: a system binary has been launched before, so nothing here waits on that.
@Suite(.serialized)
struct ServerReexecReadBackTests {
    /// A probe that never answers within its timeout says nothing about the file — `.unanswered`, not `.refused` — so it is tried again rather than written off for good.
    @Test
    func aTimeoutIsUnanswered() {
        let answer = ServerReexec.readBack(byBinaryAt: "/bin/sh", arguments: ["-c", "sleep 5"], environment: Self.environment, timeout: 1)

        guard case .unanswered = answer else {
            Issue.record("a probe that timed out read as \(answer)")
            return
        }
    }

    /// A probe killed by a signal is `.refused`: it said something about itself.
    @Test
    func aKillIsRefused() {
        let answer = ServerReexec.readBack(byBinaryAt: "/bin/sh", arguments: ["-c", "kill -9 $$"], environment: Self.environment, timeout: 10)

        guard case .refused = answer else {
            Issue.record("a probe killed by a signal read as \(answer)")
            return
        }
    }

    /// A path with nothing at it is `.refused`: launching it fails for a reason that names the file, not the moment.
    @Test
    func aMissingPathIsRefused() {
        let answer = ServerReexec.readBack(byBinaryAt: "/nonexistent/sift-\(UUID().uuidString)", arguments: [], environment: Self.environment, timeout: 5)

        guard case .refused = answer else {
            Issue.record("a missing path read as \(answer)")
            return
        }
    }

    /// A well-behaved probe that prints more than a pipe holds is read in full — the concurrent reader keeps up with the child rather than leaving it blocked on a full pipe.
    @Test
    func aPrintLargerThanAPipeArrivesInFull() {
        let answer = ServerReexec.readBack(byBinaryAt: "/usr/bin/head", arguments: ["-c", "200000", "/dev/zero"], environment: Self.environment, timeout: 10)

        guard case let .printed(text) = answer else {
            Issue.record("a large, well-behaved print read as \(answer)")
            return
        }

        #expect(text.utf8.count == 200_000)
    }

    /// A real environment, `PATH` included — an empty one leaves `/bin/sh` unable to find `sleep` or `kill`, and that is not the thing any of these tests mean to pin.
    private static let environment = ProcessInfo.processInfo.environment
}
