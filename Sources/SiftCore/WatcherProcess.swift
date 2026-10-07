//
// Copyright © Agulhas Labs
//

import Foundation

/// The process plumbing every watcher is started and heard from through, kept in one place because each guardian that promises cleanup after a kill depends on exactly the same three properties of it.
///
/// **A watcher is started out of its owner's reach.** Through `/bin/sh … &`, so it is re-parented away and is no descendant of the run — a tool that tears down a process tree to stop a hung command takes the run and leaves the watcher — and in a session of its own, so the terminal's `SIGINT` and `SIGHUP` go to the run and never to it. It inherits nothing but the two descriptors it is handed.
///
/// **It learns of its owner's death from a pipe, not from a process id.** The owner holds the only write end, opened close-on-exec so no command it launches inherits it; when the owner dies, however it dies, the kernel closes that end and the watcher's read returns end-of-file. There is no pid to be reused and no polling.
///
/// **It says it is watching before the owner does anything that needs it.** The owner reads that byte off a second pipe with a deadline, and a watcher that does not confirm in time is one the owner must assume is not there.
struct WatcherProcess {
    private init() {}

    /// Where a watcher reads its owner's liveness.
    static let livenessDescriptor: Int32 = 3
}

extension WatcherProcess {
    /// Why no watcher is running, for a guardian to put in front of a reader in its own words.
    enum Failure: Error, CustomStringConvertible, Sendable {
        /// Nothing was started, and whatever needed a watcher must not now be done.
        case unavailable(String)

        var description: String {
            switch self {
            case let .unavailable(reason):
                reason
            }
        }
    }

    /// A pipe whose ends sit above every descriptor a child is handed, and close on exec in every child but the one they are handed to.
    ///
    /// Above, because a `dup2` onto a descriptor that is already the source is a no-op that would leave it close-on-exec — and the watcher would start without the pipe it exists to read.
    static func elevatedPipe() throws -> (read: Int32, write: Int32) {
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else {
            throw Failure.unavailable("no pipe: \(String(cString: strerror(errno)))")
        }
        let read = fcntl(ends[0], F_DUPFD_CLOEXEC, 10)
        let write = fcntl(ends[1], F_DUPFD_CLOEXEC, 10)
        close(ends[0])
        close(ends[1])
        guard read >= 0, write >= 0 else {
            throw Failure.unavailable("no descriptor: \(String(cString: strerror(errno)))")
        }
        return (read, write)
    }

    /// Runs `/bin/sh -c script` in a session of its own, with `stdout` as its standard output, `liveness` as descriptor 3, `/dev/null` for the rest and nothing else inherited; returns the spawn's result and the shell's pid.
    static func spawnDetached(script: String, arguments: [String], stdout: Int32, liveness: Int32) -> (Int32, pid_t) {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, liveness, livenessDescriptor)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // The owner ignores these while it runs, and an ignored signal survives exec; the watcher starts
        // from the defaults and chooses for itself.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for number in [SIGINT, SIGTERM, SIGHUP, SIGPIPE, SIGQUIT] {
            sigaddset(&defaults, number)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        let argv = ["/bin/sh", "-c", script] + arguments
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        var shell: pid_t = 0
        let result = withCStrings(argv) { argvPointers in
            withCStrings(environment) { environmentPointers in
                posix_spawn(&shell, "/bin/sh", &actions, &attributes, argvPointers, environmentPointers)
            }
        }
        return (result, shell)
    }

    /// One byte from `descriptor`, or `nil` on end-of-file, an error, or `timeout` passing first.
    static func awaitByte(on descriptor: Int32, timeout: TimeInterval) -> UInt8? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                return nil
            }
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(remaining * 1000))
            if ready < 0, errno == EINTR {
                continue
            }
            guard ready > 0 else {
                return nil
            }
            var byte: UInt8 = 0
            let count = read(descriptor, &byte, 1)
            if count < 0, errno == EINTR {
                continue
            }
            return count == 1 ? byte : nil
        }
    }

    /// One byte from the owner, or `nil` once it is gone.
    static func readByte() -> UInt8? {
        var byte: UInt8 = 0
        while true {
            let count = read(livenessDescriptor, &byte, 1)
            if count == 1 {
                return byte
            }
            if count < 0, errno == EINTR {
                continue
            }
            return nil
        }
    }

    private static func withCStrings<Result>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> Result) -> Result {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers {
                free(pointer)
            }
        }
        return body(pointers)
    }
}
