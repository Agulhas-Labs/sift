//
// Copyright © Agulhas Labs
//

import Foundation

/// Catches the signals that end a server, so being killed is a line in the log rather than an absence.
///
/// **The ending most worth recording.** A hung `sift mcp` process cleared with `pkill -f "sift mcp"` takes every server the pattern matches with it, including the live server of a session running alongside, and that session loses its index tools with no reconnect to follow. Without this, every piece of that is invisible from inside the process — `pkill` sends `SIGTERM`, whose default action is to end the process before a single line of Swift runs.
///
/// Ignoring the signal first is what makes the source work at all: a `DispatchSource` signal handler runs *in addition to* the default action, so without `SIG_IGN` the process is gone before the handler is called. The handler runs on a queue rather than in signal context, so writing a file from it is ordinary code.
///
/// **Arming this makes a server harder to kill, and that is the sharpest hazard on this path.** `SIG_IGN` is permanent, and delivery is deferred to a queue worker — so a process whose thread pool is starved, or whose handler wedges, would take `SIGTERM` and `SIGINT` as *no-ops* where an unarmed one simply dies. Reaching for `pkill` against a hung `sift mcp` is exactly what somebody does; taking that escape hatch away in the name of recording it would be a worse bug than the one this fixes. So the handler is **one-shot**: its first act, before anything that can block, is to put every armed signal back to `SIG_DFL`. A second `pkill` then kills outright, however wedged the process is.
///
/// **The residual, stated as it actually is.** The restore lives *inside* the handler, so it covers a handler that wedges — one stuck writing the log, or stuck in `exit` — and nothing else. If the queue never runs the handler at all, `SIG_IGN` is never lifted and every subsequent signal of these three is swallowed too; only `SIGKILL` ends such a process. That is the one state in which this is strictly worse than not arming anything, and it is documented rather than hedged. It is hard to reach — 4096 blocked work items were not enough to stop libdispatch running the handler on the first `SIGTERM` — but hard to reach is not the same as impossible, and in this repository the docs are the spec.
///
/// Only one handler proceeds past the claim — three sources on one concurrent queue could otherwise run two in parallel, writing two stop lines and calling `exit` twice at once, which Darwin can wedge in static destruction.
///
/// `SIGKILL` cannot be caught by anything, and is exactly the case ``ServerLifecycleReport`` reads as a start with no stop whose process is gone.
public struct ServerSignalWatch {
    /// The signals worth recording.
    ///
    /// The two a `pkill` or `kill` and a Ctrl-C send, and the one a closing terminal does.
    public static let watched: [Int32] = [SIGTERM, SIGINT, SIGHUP]

    /// Arms `handle` for each signal and hands back the sources, which the caller must keep alive.
    ///
    /// **A watched signal that arrived before anything was listening is handled too, not lost.** It can only still be pending if it was blocked, and blocked is exactly how an image that replaced this process in place starts (``ServerReexec``): the old image has the kernel hold these signals across the exec, so one sent while the new image is still starting — loading, parsing its arguments, writing its first log line, which takes milliseconds — waits for this watch rather than killing a process that has not recorded anything yet, or vanishing under `SIG_IGN`. So the sources are listening first, what is pending is read next, and only then is `SIG_IGN` set — setting it discards whatever is pending, and a signal that lands between the two is seen by both paths and acted on once.
    ///
    /// **Both of those happen on the main thread, wherever this is called from** (``settleOnMainThread(_:)``), and that is the whole of what makes the read see anything. A signal sent to the process while every thread blocks it is held pending *on one thread* — with no thread to take it, the kernel leaves it on the process's first, the main thread — and `sigpending` reports only the calling thread's; a server arms from a pool thread, which would find nothing, and the `SIG_IGN` that follows would throw the signal away.
    ///
    /// **Then the main thread is let take them again**, in the same step, which matters only in that same image, because the main thread is the one an exec hands its mask to. Nothing receives a signal every thread blocks — GCD's workers block all of these, and a thread started from a blocked one inherits the block — so a main thread left as the exec started it would hold a *second* signal pending forever, and the one-shot restore to `SIG_DFL` in ``respond(to:armed:first:handle:)`` would no longer mean that a second `pkill` kills.
    public static func arm(signals: [Int32] = watched, handle: @escaping @Sendable (Int32) -> Void) -> [any DispatchSourceSignal] {
        let first = OnceGuard()
        let sources = signals.map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler { respond(to: number, armed: signals, first: first, handle: handle) }
            source.resume()
            return source
        }
        if let number = settleOnMainThread(signals).first {
            respond(to: number, armed: signals, first: first, handle: handle)
        }
        return sources
    }

    /// On the main thread, in this order: which of `signals` are pending there, then `SIG_IGN` for each, then the main thread unblocked for them — and what was pending, for the caller to act on.
    ///
    /// Run at once when this is the main thread, and otherwise synchronously on the main queue, which the main thread of an async program drains; synchronously, because the ignore must not happen anywhere but after the read, and the caller acts on what the read found.
    static func settleOnMainThread(_ signals: [Int32]) -> [Int32] {
        let settle: @Sendable () -> [Int32] = {
            var pending = sigset_t()
            sigpending(&pending)
            let found = signals.filter { sigismember(&pending, $0) == 1 }
            for number in signals {
                signal(number, SIG_IGN)
            }
            var set = sigset_t()
            sigemptyset(&set)
            for number in signals {
                sigaddset(&set, number)
            }
            pthread_sigmask(SIG_UNBLOCK, &set, nil)
            return found
        }
        return Thread.isMainThread ? settle() : DispatchQueue.main.sync(execute: settle)
    }

    /// What every armed source does when its signal arrives.
    ///
    /// Split from `arm` so it can be *entered twice* in a test. The re-entrancy guard cannot be exercised through the real sources: by the time a second signal could be sent, the first handler has already put the disposition back to `SIG_DFL`, so sending one would kill the test runner rather than reach the guard. Asserting on ``OnceGuard`` alone asserts that a lock is a lock — it says nothing about whether the handler consults it, which is the part that can be deleted.
    static func respond(to number: Int32, armed: [Int32], first: OnceGuard, handle: @Sendable (Int32) -> Void) {
        // Before anything that can block, and for every armed signal rather than only this one: from here on,
        // a signal kills this process the way it would have without any of this.
        for signalNumber in armed {
            signal(signalNumber, SIG_DFL)
        }
        guard first.claim() else { return }
        handle(number)
    }
}
