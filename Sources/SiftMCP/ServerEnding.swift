//
// Copyright © Agulhas Labs
//

import Foundation

/// The one way a server's life ends: exactly one stop recorded, and at most one exit, whichever path arrives first.
///
/// **Why the exit is in here and not at the call site.** A guard over only the *record* is enough for one exit path, and stops being enough the moment a second one is armed: two dispatch sources on one concurrent queue can enter their handlers in parallel, and two handlers calling `exit` at once is the hazard ``ServerSignalWatch`` already names — Darwin can wedge in static destruction. Closing a terminal reaches both of them by construction rather than by coincidence, since it delivers `SIGHUP` to the foreground group and kills the parent shell in the same event. So the claim covers the whole ending, and the loser of the race returns rather than exiting: the process is already on its way out through the winner.
///
/// **An exec is the one thing that is neither serving nor ending, and it takes the same claim.** Replacing the image (``ServerReexec``) leaves the process running, so a stop recorded while it happens would close a start line whose process then goes on serving — invisible to `sift status` from that moment. So while an image is being replaced no stop is written: one that arrives is held, and if the exec fails the held stop is carried out exactly as it would have been. Everything slow about a replacement is done before the claim is taken, so the only thing that happens inside it is the exec.
///
/// The residuals are stated rather than hidden. A winner that wedges before it exits leaves the process alive, and the escape hatch is that the signal handler has already restored `SIG_DFL`, so a second signal kills outright. And a stop that arrives while an exec that then succeeds is under way is held by an image that is about to stop existing: the new image never hears of it, and the sender's next signal is the one that lands. That window runs from the claim until the kernel has given the new image its blocked mask — the exec itself, of the order of a millisecond, once the file has already been launched once, which the probe (``ServerReexec``) always does first: a binary's own first-ever launch can itself run to hundreds of milliseconds under macOS's first-launch assessment, and it is the probe that pays that, not this window. The new image's startup, which is far longer regardless, is not part of it: a signal sent then waits, blocked, for the new image's watch (``ServerSignalWatch``).
public struct ServerEnding: Sendable {
    private let write: @Sendable (ServerStop) -> Void
    private let leave: @Sendable (Int32) -> Void
    private let phase: Phase

    /// `leave` is injected only so this can be entered twice in a test; nothing but a test ever passes it.
    public init(record: @escaping @Sendable (ServerStop) -> Void, leave: @escaping @Sendable (Int32) -> Void = { Foundation.exit($0) }) {
        write = record
        self.leave = leave
        phase = Phase()
    }

    /// Records why the server stopped, for the path that returns rather than exiting.
    ///
    /// A `SIGHUP` landing as the client closes its end would otherwise record twice against one start, and `sift status` reads the last stop — so the pair would disagree exactly when the signal is the half worth knowing about.
    public func record(_ stop: ServerStop) {
        guard phase.claimEnding(stop, status: nil) else { return }
        write(stop)
    }

    /// Records why the server stopped and ends the process, for the paths that cannot return.
    ///
    /// A caller that loses the claim returns without exiting, which is deliberate: the process is already ending on the thread that won, and a second `exit` is the thing being avoided rather than a tidy-up.
    public func end(_ stop: ServerStop, status: Int32) {
        guard phase.claimEnding(stop, status: status) else { return }
        write(stop)
        leave(status)
    }

    /// Holds every ending off while this process replaces its image; `false` where it is already ending, and then nothing may be replaced.
    ///
    /// Taken immediately before the exec and nowhere earlier: an ending that arrives while it is held waits for the exec's outcome, so the claim must cover nothing slower than the exec itself.
    public func beginReplacing() -> Bool {
        phase.beginReplacing()
    }

    /// The image was not replaced: serving resumes, and an ending that arrived meanwhile is carried out now, as it would have been had nothing been in the way.
    public func abandonReplacing() {
        guard let held = phase.abandonReplacing() else { return }
        if let status = held.status {
            end(held.stop, status: status)
        } else {
            record(held.stop)
        }
    }
}

private extension ServerEnding {
    /// Where a server's life stands, under one lock, so a stop, an exit and an exec are decided in one place.
    final class Phase: @unchecked Sendable {
        private let mutex = NSLock()
        private var state = State.serving

        /// Whether this caller is the one that ends the server; an ending that arrives mid-replacement is held instead, the first of them only.
        func claimEnding(_ stop: ServerStop, status: Int32?) -> Bool {
            mutex.lock()
            defer { mutex.unlock() }
            switch state {
            case .serving:
                state = .ended
                return true
            case .replacing(held: nil):
                state = .replacing(held: Held(stop: stop, status: status))
                return false
            case .replacing, .ended:
                return false
            }
        }

        func beginReplacing() -> Bool {
            mutex.lock()
            defer { mutex.unlock() }
            guard case .serving = state else { return false }
            state = .replacing(held: nil)
            return true
        }

        /// Back to serving; hands back the ending that was held, which the caller now carries out.
        func abandonReplacing() -> Held? {
            mutex.lock()
            defer { mutex.unlock() }
            guard case let .replacing(held) = state else { return nil }
            state = .serving
            return held
        }
    }
}

private extension ServerEnding.Phase {
    /// An ending that arrived while the image was being replaced: the stop, and the status to exit with — `nil` for the path that returns.
    struct Held {
        let stop: ServerStop
        let status: Int32?
    }

    enum State {
        case serving
        case replacing(held: Held?)
        case ended
    }
}
