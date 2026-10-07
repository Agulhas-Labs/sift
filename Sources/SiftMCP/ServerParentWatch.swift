//
// Copyright © Agulhas Labs
//

import Foundation

/// Ends the server when the process that spawned it goes away, which is the one orphan signal that is a fact rather than a guess.
///
/// **Why this and not an idle timer.** A stdio server cannot tell an abandoned client from a thinking one: both are silence on the same pipe, and a server that exits because it has been quiet for a while is, deliberately built, an agent losing its index mid-session for a reason it cannot see. Parent death carries no such ambiguity. Nothing legitimate holds the other end of this pipe once the process that opened it has exited, so this is the one thing a server can act on without a policy attached to it.
///
/// `EVFILT_PROC` with `NOTE_EXIT` is the kernel's answer to the question, and `DispatchSource`'s process source is the ordinary way to ask it: the handler runs on a queue rather than in signal context, so writing the lifecycle line from it is ordinary code. The watched process need not be a child — same-uid visibility is what the filter requires, and the parent of a server is always the same user's.
///
/// **The window before the source is armed is covered separately, and it has to be.** A parent that dies between reading `getppid()` and registering the source leaves a source that will never fire, on a pid the kernel has already forgotten — and this process would then wait forever for an event that was already in the past. So after arming, the parent is asked for a second time: a process whose parent is no longer the pid it was born under has been re-parented, which on Darwin means the original is gone. That second reading is the whole of the race handling, and it is why the check is a parameter rather than a call inlined into the handler.
///
/// **What is deliberately not watched.** A parent of 1 or 0 — a process already re-parented to `launchd` before it started, or one launched with no parent to speak of — arms nothing and returns `nil`. There is no fact available in that state: the pid that would be watched belongs to the system, and its exit is not a thing this process will live to see.
public struct ServerParentWatch {
    /// Arms an exit watch on `parent` and hands back the source, which the caller must keep alive.
    ///
    /// Returns `nil` where there is nothing worth watching, and calls `handle` — exactly once, whichever path reaches it first — where the parent is already gone.
    ///
    /// The second reading of the parent is injected so the race it covers can be exercised without killing a process at a precise instant; by default it is `getppid()`, asked again.
    ///
    /// `parent` has no default, so where it is read is the caller's decision and visible at the call. A server reads it before announcing itself and passes that pid: a reading taken here, after the announcement, would see a parent killed in between as the system and leave nothing watched — and a default would let exactly that reading back in without a line at the call site changing.
    public static func arm(
        parent: pid_t,
        queue: DispatchQueue = .global(qos: .userInitiated),
        parentIsUnchanged: @escaping @Sendable (pid_t) -> Bool = { $0 == getppid() },
        handle: @escaping @Sendable (pid_t) -> Void
    ) -> (any DispatchSourceProcess)? {
        guard parent > 1 else { return nil }
        let first = OnceGuard()
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: queue)
        source.setEventHandler {
            guard first.claim() else { return }
            handle(parent)
        }
        source.resume()
        // Asked *after* the source is live, never before: in that order a parent dying at any instant is
        // caught by one of the two, and a parent dying between them is caught by both and answered once.
        if !parentIsUnchanged(parent), first.claim() {
            handle(parent)
        }

        return source
    }
}
