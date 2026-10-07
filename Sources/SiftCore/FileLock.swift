//
// Copyright © Agulhas Labs
//

import Foundation

/// Cross-process locking for the per-user files this tool appends to and rewrites.
///
/// **Why these files need it at all.** Every one of them is written by *several processes at once* by construction: one `sift mcp` per Claude Code session, plus every hook process and every wrapped run, all appending to one `~/.sift`. A read-modify-write across that is a race with no owner, and an append is one too the moment anything positions its own offset.
///
/// `flock` rather than an exclusive-create lock file, for the reason ``SiftMCP/AdviceLedger`` already gives: the kernel releases it when the descriptor closes — including when the process dies holding it — so there is no stale lock to time out and no wedged writer. It blocks rather than spinning, because every critical section here is one small read or one small write.
///
/// **Unavailable is never fatal, and neither is contended.** A lock that cannot be taken *within a short deadline* gives up and the caller proceeds unserialised. That is not a nicety: these files are appended to from inside `MCPServer`'s dispatch, between a tool call and its answer, so a blocking wait on a pathological holder would stall every index call in every concurrent session — and `sift status`, the command someone runs to diagnose exactly that. Unbounded, a process holding the lock for twenty seconds stalls `sift status` for nearly all of them.
///
/// So the contract these files already state in their own docs — *"nothing here may raise or block; a ledger is a record of work, never a precondition for it"* — is true of the locking as well as of the writing. Losing serialisation costs at worst an interleaved rewrite in a diagnostic file; waiting costs the tool's whole purpose.
public struct FileLock {
    /// How long a caller will wait for a contended lock before proceeding without it.
    ///
    /// Every critical section behind this is one small read or one small write, so a wait beyond this is not contention but a holder that has gone wrong.
    public static let deadline: TimeInterval = 0.25

    /// Takes the lock, retrying briefly while it is merely contended; `false` when it was not taken.
    ///
    /// A caller that gets `false` must go on and do its work anyway — see the type's note.
    @discardableResult
    public static func take(_ descriptor: Int32, _ mode: Mode, within limit: TimeInterval = deadline) -> Bool {
        let giveUp = Date().addingTimeInterval(limit)
        while true {
            if flock(descriptor, mode.operation | LOCK_NB) == 0 {
                return true
            }
            let code = errno
            // Held by somebody else, or a signal interrupted the attempt: both are worth another try.
            // Anything else — a filesystem that does not implement `flock` at all — never will be.
            guard code == EWOULDBLOCK || code == EINTR else { return false }
            guard Date() < giveUp else { return false }
            usleep(2000)
        }
    }

    public static func release(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
    }
}

public extension FileLock {
    enum Mode {
        /// One writer, no readers — for an append or a rewrite.
        case exclusive
        /// Any number of readers, no writer — for a read that must not see a rewrite half-done.
        case shared

        var operation: Int32 {
            switch self {
            case .exclusive: LOCK_EX
            case .shared: LOCK_SH
            }
        }
    }
}
