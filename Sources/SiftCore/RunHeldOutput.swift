//
// Copyright © Agulhas Labs
//

import Foundation

/// A run that stopped reading its command's output because something the command left running still held it open after the command exited.
///
/// Nothing is ended: the run stops reading and says so, and whatever the command left behind is the user's, as it would be in their shell.
///
/// **That guarantee is `sift run`'s alone.** The set-aside callers (`ShardRunner`, `PackageTestRun`, `RunWithoutCommand`) compute `RunOutcome.heldOutput` and never print it, and then end the holders (`SetAsideChildren.settle(_:)`, or `endAll()` in `PackageTestRun`): SIGTERM, then SIGKILL.
public struct RunHeldOutput: Sendable, Equatable {
    /// What was still running in the command's process group or session when reading stopped, in pid order — empty where nothing could be found.
    public let holders: [Holder]

    /// The most holders the note names before it counts the rest.
    static let named = 5

    /// The one line a run prints about it, on the stream its other notes go to.
    public var note: String {
        let lead = "sift run: the command exited, but its output was still held open — not waited for"
        guard !holders.isEmpty else {
            return lead + "."
        }
        let listed = holders.prefix(Self.named).map { holder in
            holder.name.map { "pid \(holder.pid) (\($0))" } ?? "pid \(holder.pid)"
        }
        let more = holders.count > Self.named ? " and \(holders.count - Self.named) more" : ""
        return lead + "; still running from it: " + listed.joined(separator: ", ") + more + "."
    }

    /// What is still running in the process group or session `pid` led, less this process.
    ///
    /// The group is how a command started by `Process` is found, the session how one a set-aside started is. A group or session id is never handed to a new process while a member of it lives, so a leader already reaped still names its own.
    static func left(by pid: Int32) -> RunHeldOutput {
        let own = getpid()
        let holders = KernelProcess.allPids()
            .filter { $0 != own && (getpgid($0) == pid || getsid($0) == pid) }
            .sorted()
            .map { Holder(pid: $0, name: KernelProcess.name(of: $0)) }
        return RunHeldOutput(holders: holders)
    }
}

public extension RunHeldOutput {
    /// One process still running from the command when reading stopped.
    struct Holder: Sendable, Equatable {
        public let pid: Int32
        /// The kernel's short name for it, or `nil` where it has none to give.
        public let name: String?
    }
}
