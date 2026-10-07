//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the mechanism that turns "the server was killed" from an absence into a line.
///
/// On `SIGUSR1` rather than the three this actually arms, since nothing else in the process claims it. Every part of a test that raises it at its own process, or changes how that process takes it, runs in a child process that runs nothing else (``SignalScenarioProcess``) — never in the test runner, where a one-shot handler that another test's signal had already put back to the default would let this test's signal end the whole run. What is left here touches no process-wide state, so no test in this suite needs to run alone.
struct ServerSignalWatchTests {
    /// The whole claim: with a source armed, a signal whose default action would end the process on the spot runs our code first — which is the only window in which anything can be written down.
    @Test
    func anArmedSignalReachesTheHandlerInsteadOfEndingTheProcess() async {
        await SignalScenarioProcess.run(.anArmedSignalReachesTheHandler)
    }

    /// The handler is one-shot: once it has run, the signal kills this process the way it would have unarmed.
    ///
    /// This is the hazard arming a signal creates rather than removes. `SIG_IGN` is permanent and delivery is deferred to a queue worker, so a wedged server would take `pkill` as a no-op where an unarmed one simply dies — and reaching for `pkill` against a hung `sift mcp` is exactly what someone does. Restoring the default disposition before anything that can block is what keeps the second attempt lethal.
    @Test
    func aSignalThatHasBeenHandledOnceKillsTheProcessTheNextTime() async {
        await SignalScenarioProcess.run(.aHandledSignalLeavesTheDefaultBehind)
    }

    /// Only one handler proceeds, whichever signal arrives first — asserted at the handler, not at the lock.
    ///
    /// Three sources share one *concurrent* queue, and the handler ends in `exit`. Two running in parallel would write two stop lines and call `exit` twice at once, which Darwin can wedge in static destruction — a hang, in the code whose whole job is to make a death legible.
    ///
    /// Entered directly rather than by signalling twice, which is not a shortcut but the only way in: by the time a second signal could be sent the first handler has already restored `SIG_DFL`, so sending one would end the process instead of reaching the guard. `armed:` is empty so no process-wide disposition is touched — the restore is pinned by the test above, and what is pinned here is that the handler *consults* the guard, which asserting on ``OnceGuard`` alone never could.
    @Test
    func onlyTheFirstSignalIsActedOn() {
        let first = OnceGuard()
        let entered = CaughtSignal()

        ServerSignalWatch.respond(to: SIGTERM, armed: [], first: first) { entered.record($0) }
        ServerSignalWatch.respond(to: SIGINT, armed: [], first: first) { entered.record($0) }

        #expect(entered.count == 1, "both handlers ran — two stop lines, and two concurrent exits")
        #expect(entered.current == SIGTERM, "the second handler overwrote the first's answer")
    }

    /// The three signals armed in production are the ones that actually end a server: `pkill` and `kill` send `SIGTERM`, Ctrl-C sends `SIGINT`, and a closing terminal sends `SIGHUP`.
    @Test
    func theWatchedSignalsAreTheOnesThatEndAServer() {
        #expect(ServerSignalWatch.watched == [SIGTERM, SIGINT, SIGHUP])
    }

    /// A signal held pending on the main thread when the watch arms reaches the handler, though the watch is armed from another thread — rather than being thrown away by `SIG_IGN`.
    ///
    /// The state an image begins in when a server has replaced itself in place: the exec leaves these signals blocked on every thread, and one sent to the process then is held on its first thread, the main one, until something takes it (``ServerReexec``). A server arms from a pool thread, whose own pending set is empty, so the read has to be made on the main thread or it finds nothing. Made here with `pthread_kill` on the main thread while the main thread blocks the signal, so it is pending there alone and nothing else in the process can take it; setting `SIG_IGN` discards a pending signal, so a read made anywhere else leaves this handler never called. The end-to-end form, a real server started with the signal already pending, is in ``ServerReexecTests``.
    @Test
    func aSignalPendingOnTheMainThreadWhenTheWatchArmsReachesTheHandler() async {
        await SignalScenarioProcess.run(.aPendingSignalReachesTheHandler)
    }

    /// Arming leaves the main thread able to take the watched signals, however it started — the thread an exec hands its blocked mask to.
    ///
    /// Without it, a server that had replaced itself would have these signals blocked on every thread it runs — GCD's workers block them anyway — so once the one-shot handler had put `SIG_DFL` back, a second `pkill` would sit pending rather than kill. Armed from off the main thread, as a server arms, so the hop to the main queue is what is exercised; the mask is read back on the main thread itself.
    @Test
    func armingUnblocksTheWatchedSignalsOnTheMainThread() async {
        await SignalScenarioProcess.run(.armingUnblocksTheMainThread)
    }

    /// A signal raised after another watch's one-shot handler has fired ends only the process it is raised in — the child a scenario runs in, never the test runner.
    ///
    /// One signal reaches every watch armed for it, so two watches in one process — two tests running side by side, or a test beside anything else that arms one — are both put back to `SIG_DFL` by the first signal, and the second, sent by whichever test comes next, meets the default and ends the process. In the test runner that is the whole run ended by `SIGUSR1`, with no summary. The scenario makes that interleaving happen every time; this test is still here to see the process end only because that process was a child.
    @Test
    func aSignalAfterAnotherWatchHasFiredEndsOnlyItsOwnProcess() async {
        await SignalScenarioProcess.run(.aSignalAfterAnotherWatchHasFired, ending: .bySignal(SIGUSR1))
    }
}

extension ServerSignalWatchTests {
    /// The part of a test that raises a signal at its own process, or changes how that process takes one — named, so it can be handed to another process and run there.
    enum Scenario: String, Codable, Sendable {
        case anArmedSignalReachesTheHandler
        case aHandledSignalLeavesTheDefaultBehind
        case aPendingSignalReachesTheHandler
        case armingUnblocksTheMainThread
        case aSignalAfterAnotherWatchHasFired

        /// Runs the scenario here, reporting what it finds at the test that asked for it.
        func perform(sourceLocation: SourceLocation = #_sourceLocation) async throws {
            switch self {
            case .anArmedSignalReachesTheHandler:
                try await Self.anArmedSignalReachesTheHandler(sourceLocation: sourceLocation)
            case .aHandledSignalLeavesTheDefaultBehind:
                try await Self.aHandledSignalLeavesTheDefaultBehind(sourceLocation: sourceLocation)
            case .aPendingSignalReachesTheHandler:
                try await Self.aPendingSignalReachesTheHandler(sourceLocation: sourceLocation)
            case .armingUnblocksTheMainThread:
                try await Self.armingUnblocksTheMainThread(sourceLocation: sourceLocation)
            case .aSignalAfterAnotherWatchHasFired:
                try await Self.aSignalAfterAnotherWatchHasFired(sourceLocation: sourceLocation)
            }
        }
    }
}

private extension ServerSignalWatchTests.Scenario {
    static func anArmedSignalReachesTheHandler(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let caught = ServerSignalWatchTests.CaughtSignal()
        let sources = ServerSignalWatch.arm(signals: [SIGUSR1]) { caught.record($0) }
        defer {
            for source in sources {
                source.cancel()
            }
            signal(SIGUSR1, SIG_DFL)
        }

        kill(getpid(), SIGUSR1)
        try await settle { caught.current == SIGUSR1 }

        #expect(caught.current == SIGUSR1, sourceLocation: sourceLocation)
    }

    static func aHandledSignalLeavesTheDefaultBehind(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let caught = ServerSignalWatchTests.CaughtSignal()
        let sources = ServerSignalWatch.arm(signals: [SIGUSR1]) { caught.record($0) }
        defer {
            for source in sources {
                source.cancel()
            }
        }

        kill(getpid(), SIGUSR1)
        try await settle { caught.current == SIGUSR1 }
        // `signal` hands back the disposition it replaced, which is the one the handler left behind.
        let disposition = signal(SIGUSR1, SIG_DFL)

        #expect(
            bits(disposition) == bits(SIG_DFL),
            "a second signal would still be ignored — pkill would not kill a wedged server",
            sourceLocation: sourceLocation
        )
    }

    @MainActor
    static func aPendingSignalReachesTheHandler(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        var usr1 = set(of: SIGUSR1)
        pthread_sigmask(SIG_BLOCK, &usr1, nil)
        let caught = ServerSignalWatchTests.CaughtSignal()
        let armed = ServerSignalWatchTests.SourceBox()
        defer {
            pthread_sigmask(SIG_UNBLOCK, &usr1, nil)
            armed.cancel()
            signal(SIGUSR1, SIG_DFL)
        }
        pthread_kill(pthread_self(), SIGUSR1)
        #expect(callingThreadHasPending(SIGUSR1), "the signal is not pending on the main thread, so this test proves nothing", sourceLocation: sourceLocation)

        await Task.detached { armed.hold(ServerSignalWatch.arm(signals: [SIGUSR1]) { caught.record($0) }) }.value
        try await settle { caught.current == SIGUSR1 }

        #expect(caught.current == SIGUSR1, "a signal pending on the main thread when the watch armed was discarded instead of handled", sourceLocation: sourceLocation)
    }

    @MainActor
    static func armingUnblocksTheMainThread(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        var usr1 = set(of: SIGUSR1)
        pthread_sigmask(SIG_BLOCK, &usr1, nil)
        let armed = ServerSignalWatchTests.SourceBox()
        defer {
            pthread_sigmask(SIG_UNBLOCK, &usr1, nil)
            armed.cancel()
            signal(SIGUSR1, SIG_DFL)
        }

        await Task.detached { armed.hold(ServerSignalWatch.arm(signals: [SIGUSR1]) { _ in }) }.value
        for _ in 0 ..< 200 where callingThreadBlocks(SIGUSR1) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(pthread_main_np() != 0, "the mask read back was not the main thread's", sourceLocation: sourceLocation)
        #expect(!callingThreadBlocks(SIGUSR1), "the main thread still blocks a watched signal after the watch armed", sourceLocation: sourceLocation)
    }

    /// Two watches in one process, as two tests running side by side would arm them: the first signal runs both one-shot handlers, and the second meets the default they put back — so the process this runs in ends by it.
    static func aSignalAfterAnotherWatchHasFired(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let first = ServerSignalWatchTests.CaughtSignal()
        let second = ServerSignalWatchTests.CaughtSignal()
        let one = ServerSignalWatch.arm(signals: [SIGUSR1]) { first.record($0) }
        let other = ServerSignalWatch.arm(signals: [SIGUSR1]) { second.record($0) }
        defer {
            for source in one + other {
                source.cancel()
            }
        }

        // One test's signal, which reaches both watches.
        kill(getpid(), SIGUSR1)
        try await settle { first.current == SIGUSR1 && second.current == SIGUSR1 }
        #expect(second.current == SIGUSR1, "one signal did not reach both watches, so this test proves nothing", sourceLocation: sourceLocation)

        // The other test's own signal, which now meets the default. The process ends here; still running
        // after this wait, it exits normally, and the test that asked for it records that it should not have.
        kill(getpid(), SIGUSR1)
        try await Task.sleep(for: .seconds(10))
    }

    /// A signal disposition is a C function pointer, which is not `Equatable`; its bit pattern is what distinguishes the two reserved values.
    static func bits(_ handler: sig_t?) -> UInt {
        guard let handler else { return 0 }
        return UInt(bitPattern: unsafeBitCast(handler, to: UnsafeRawPointer.self))
    }

    static func set(of number: Int32) -> sigset_t {
        var set = sigset_t()
        sigemptyset(&set)
        sigaddset(&set, number)
        return set
    }

    static func callingThreadBlocks(_ number: Int32) -> Bool {
        var current = sigset_t()
        pthread_sigmask(SIG_BLOCK, nil, &current)
        return sigismember(&current, number) == 1
    }

    static func callingThreadHasPending(_ number: Int32) -> Bool {
        var pending = sigset_t()
        sigpending(&pending)
        return sigismember(&pending, number) == 1
    }

    /// Polls rather than sleeps a fixed span.
    ///
    /// The handler runs on a queue, so its arrival is prompt but not synchronous, and a fixed wait is either flaky or slow.
    static func settle(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private extension ServerSignalWatchTests {
    /// The signal number the handler saw and how many times it was entered, handed back from the queue it ran on.
    final class CaughtSignal: @unchecked Sendable {
        private let mutex = NSLock()
        private var value: Int32?
        private var entries = 0

        func record(_ number: Int32) {
            mutex.lock()
            defer { mutex.unlock() }
            if value == nil {
                value = number
            }
            entries += 1
        }

        var current: Int32? {
            mutex.lock()
            defer { mutex.unlock() }
            return value
        }

        var count: Int {
            mutex.lock()
            defer { mutex.unlock() }
            return entries
        }
    }

    /// Keeps armed sources alive past the thread that armed them, and cancels them when the test is done.
    final class SourceBox: @unchecked Sendable {
        private let mutex = NSLock()
        private var sources: [any DispatchSourceSignal] = []

        func hold(_ armed: [any DispatchSourceSignal]) {
            mutex.lock()
            defer { mutex.unlock() }
            sources = armed
        }

        func cancel() {
            mutex.lock()
            defer { mutex.unlock() }
            for source in sources {
                source.cancel()
            }
        }
    }
}
