//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers when a replacement that was not taken over is tried again — by what it failed on, not once per file whatever happened.
struct ServerReexecAttemptsTests {
    private static let first = BinaryIdentity(inode: 10, mtime: 1_788_000_000)
    private static let second = BinaryIdentity(inode: 11, mtime: 1_788_000_100)
    private static let now = Date(timeIntervalSince1970: 1_788_000_200)

    /// A replacement that refused is not tried again while it is the same file, however long ago that was — and a changed file is tried at once.
    @Test
    func aRefusalHoldsUntilTheFileChanges() {
        var attempts = ServerReexec.Attempts()

        attempts.record(.refused("exited 64"), for: Self.first, at: Self.now)

        #expect(!attempts.allow(Self.first, at: Self.now))
        #expect(!attempts.allow(Self.first, at: Self.now + 86400))
        #expect(attempts.allow(Self.second, at: Self.now))
    }

    /// A failure that says nothing about the file is tried again once its pause is over, and not before.
    @Test
    func aFailureIsTriedAgainAfterItsPause() {
        var attempts = ServerReexec.Attempts()

        attempts.record(.failed("did not answer"), for: Self.first, at: Self.now)

        #expect(!attempts.allow(Self.first, at: Self.now + ServerReexec.Attempts.firstPause - 1))
        #expect(attempts.allow(Self.first, at: Self.now + ServerReexec.Attempts.firstPause))
        #expect(attempts.allow(Self.second, at: Self.now), "a changed file waited out the old one's pause")
    }

    /// Each further failure of the same file doubles the pause, to a ceiling — the bound on how often a probe that keeps failing is run.
    @Test
    func theyPauseLongerEachTimeUpToACeiling() {
        var attempts = ServerReexec.Attempts()
        var moment = Self.now
        var pauses: [TimeInterval] = []

        for _ in 0 ..< 8 {
            attempts.record(.failed("did not answer"), for: Self.first, at: moment)
            // Searched no further than a second past the ceiling, so a pause that never ends fails here rather than
            // spinning the suite: it reads as one longer than any allowed.
            var pause: TimeInterval = 0
            while !attempts.allow(Self.first, at: moment + pause), pause <= ServerReexec.Attempts.longestPause {
                pause += 1
            }
            pauses.append(pause)
            moment += pause
        }

        #expect(pauses == [30, 60, 120, 240, 480, 600, 600, 600])
    }

    /// A moment that could not be handed over holds nothing against the file: the next request may try at once.
    @Test
    func aDeferredMomentHoldsNothingBack() {
        var attempts = ServerReexec.Attempts()

        attempts.record(.deferred("too large"), for: Self.first, at: Self.now)

        #expect(attempts.allow(Self.first, at: Self.now))
    }

    /// A refusal after failures is a refusal; a failure run starts over for a new file.
    @Test
    func whatWasLearntIsAboutOneFile() {
        var attempts = ServerReexec.Attempts()
        attempts.record(.failed("did not answer"), for: Self.first, at: Self.now)
        attempts.record(.failed("did not answer"), for: Self.first, at: Self.now + 30)
        attempts.record(.failed("did not answer"), for: Self.second, at: Self.now + 30)

        #expect(attempts.allow(Self.second, at: Self.now + 30 + ServerReexec.Attempts.firstPause), "a new file inherited the old one's run of failures")

        attempts.record(.refused("exited 64"), for: Self.second, at: Self.now + 100)
        #expect(!attempts.allow(Self.second, at: Self.now + 100 + ServerReexec.Attempts.longestPause))
    }

    /// The exec's limit is reckoned as the kernel reckons it: an environment that just fits is carried, and one byte more is refused — by a real spawn on both sides of the line, not by the arithmetic checking itself.
    @Test
    func whatFitsIsWhatTheKernelCarries() {
        let space = sysconf(_SC_ARG_MAX)
        let arguments = ["/usr/bin/true"]
        var environment = ProcessInfo.processInfo.environment
        environment["SIFT_TEST_PADDING"] = ""
        #expect(ServerReexec.fits(arguments: arguments, environment: environment, within: space))
        // Grow the padding until one more byte would not fit.
        var low = 0
        var high = space
        while low < high {
            let middle = (low + high + 1) / 2
            environment["SIFT_TEST_PADDING"] = String(repeating: "p", count: middle)
            if ServerReexec.fits(arguments: arguments, environment: environment, within: space) {
                low = middle
            } else {
                high = middle - 1
            }
        }
        environment["SIFT_TEST_PADDING"] = String(repeating: "p", count: low)
        #expect(Self.spawn(arguments, environment: environment) == 0, "what fits was not carried")
        environment["SIFT_TEST_PADDING"] = String(repeating: "p", count: low + 1)
        #expect(!ServerReexec.fits(arguments: arguments, environment: environment, within: space))
        #expect(Self.spawn(arguments, environment: environment) == E2BIG, "one byte more than fits was carried after all")
    }

    /// Spawns `arguments` and waits for it; the result of the spawn itself.
    private static func spawn(_ arguments: [String], environment: [String: String]) -> Int32 {
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv + envp {
                free(pointer)
            }
        }
        var pid = pid_t()
        let result = posix_spawn(&pid, arguments[0], nil, nil, argv, envp)
        if result == 0 {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        return result
    }
}
