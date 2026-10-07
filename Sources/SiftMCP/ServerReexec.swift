//
// Copyright © Agulhas Labs
//

import Foundation

/// Replaces this process's image with the binary now on disk, between two requests, and hands the new image the session in progress.
///
/// **Why in place, rather than a notice asking for a restart.** A binary upgraded under a running server leaves that server executing the unlinked old code until something restarts it, and restarting an MCP server is not something an agent can do from inside its session: the client has to reconnect it, which in practice means restarting the session. Until then every answer comes from superseded code and says so. An exec is invisible to the client — the pid it spawned and the pipes it holds are the ones the new image serves on — so what has to be arranged is only that the new image picks the conversation up where the old one put it down (``ServerHandover``).
///
/// **What makes it safe, in the order it happens.**
/// - *The handover has to fit.* An exec carries its argument vector and environment in a space the kernel bounds (`ARG_MAX`), and the handover rides in the environment, so a request too large for it cannot be handed over. That is checked first, before anything is asked of the new binary, and is a fact about this moment rather than about the file: the next request, which is ordinary-sized, tries again.
/// - *The new binary is asked first, with the arguments the exec would run.* It is run once as a child with this process's own argument vector and the read-handover flag appended — not a fixed `mcp --read-handover` that names none of them — given the very handover the exec would carry, and must print it back as it read it (``ServerHandover/readBack(from:)``); this image compares that with what it wrote, field for field. A file still being copied, one whose signature the kernel will not run, an older build that has never heard of a handover, a build that reads this layout differently from how it was written, and a build that no longer accepts an option the running server was started with, all fail that, and the process serves on with the notice rather than exec'ing into something that would drop the request it was handed or fail to start at all.
/// - *Between requests only.* The caller hands over the request it has just read, unanswered, with anything that arrived after it, so the answer comes from the new code and nothing is replaced mid-request. Nothing is being read at that moment either (``LineInput``), so no bytes are in flight.
/// - *No stop is recorded.* ``ServerEnding`` holds endings off for the exec itself, and carries out one that arrived if the exec fails.
/// - *`posix_spawn` with `POSIX_SPAWN_SETEXEC`, not `execve`.* It sets the new image's signal state as part of the exec: the watched signals back at `SIG_DFL` but blocked, so one sent while the new image is still starting waits, pending, for its watch (``ServerSignalWatch``) instead of vanishing under this image's `SIG_IGN`; and a mask given explicitly rather than inherited from the thread that calls this — a pool thread, which blocks every asynchronous signal and would hand the new main thread the same. Every descriptor but the three standard ones is closed across it: the index databases, logs and event queues this image opened belong to code that is about to stop existing.
///
/// Anything that fails leaves the process where it was, serving from the old code with the notice under its answers, which is the whole of what happened before this existed. What it failed on decides when it is tried again (``Attempts``).
public struct ServerReexec: Sendable {
    /// The flag a replacement is asked with.
    static var readBackFlag: String {
        "--read-handover"
    }

    let path: String
    let arguments: [String]
    let startedAt: Date
    let parent: Int32
    let ending: ServerEnding
    /// Asks the binary at a path to read back the handover, given the arguments the exec would run and the environment it would carry.
    let ask: @Sendable (_ path: String, _ arguments: [String], _ environment: [String: String]) -> Answer
    /// The exec itself, which returns only when it failed, with the error number.
    let execute: @Sendable (_ path: String, _ arguments: [String], _ environment: [String: String]) -> Int32

    /// Readies this process to become the binary at `path`, with the start time and parent it was first given.
    ///
    /// `arguments` is the argument vector to become it with — this process's own, so the command line anything else sees is unchanged. `ask` and `execute` are injected only so a test can run this without asking a binary anything or replacing an image; nothing but a test ever passes them.
    public init(
        path: String,
        arguments: [String],
        startedAt: Date,
        parent: Int32,
        ending: ServerEnding,
        ask: (@Sendable (_ path: String, _ arguments: [String], _ environment: [String: String]) -> Answer)? = nil,
        execute: (@Sendable (_ path: String, _ arguments: [String], _ environment: [String: String]) -> Int32)? = nil
    ) {
        self.path = path
        self.arguments = arguments
        self.startedAt = startedAt
        self.parent = parent
        self.ending = ending
        self.ask = ask ?? { Self.readBack(byBinaryAt: $0, arguments: $1, environment: $2) }
        self.execute = execute ?? { Self.becomeBinary(at: $0, arguments: $1, environment: $2) }
    }

    /// Hands `session` to the binary at the path, which has to be `expected` still; returns only when that did not happen, with why — which decides when it is worth trying again.
    func replace(handing session: ServerHandover.Session, expecting expected: BinaryIdentity) -> NotTakenOver {
        let handover = ServerHandover(pid: getpid(), startedAt: startedAt, parent: parent, session: session)
        guard let value = try? handover.encoded() else {
            return .failed("the session could not be written down")
        }
        var environment = ProcessInfo.processInfo.environment
        environment[ServerHandover.environmentKey] = value
        let space = sysconf(_SC_ARG_MAX)
        // The probe runs the very argument vector the exec would — this process's own, past its own name, with the
        // read-handover flag appended — not a fixed `mcp --read-handover` that names none of them: a later build
        // that renamed or dropped an option the running server was started with fails here, the way it would fail
        // for real, instead of passing a probe that never asked about the option at all.
        let probeArguments = Array(arguments.dropFirst()) + [Self.readBackFlag]
        guard Self.fits(arguments: arguments, environment: environment, within: space),
              Self.fits(arguments: [path] + probeArguments, environment: environment, within: space)
        else {
            return .deferred("the input in hand, \(session.unread.count) bytes, is more than an exec can carry")
        }
        switch ask(path, probeArguments, environment) {
        case let .printed(text):
            guard ServerHandover.decode(text.trimmingCharacters(in: .whitespacesAndNewlines), for: handover.pid) == handover else {
                return .refused("the new binary read the handover back differently from how this one wrote it")
            }
        case let .refused(reason):
            return .refused(reason)
        case let .unanswered(reason):
            return .failed(reason)
        }
        // The file that answered has to be the file exec'd: one replaced again while it was being asked is left for the
        // next request, which will see its identity as new and ask it in turn.
        guard BinaryIdentity.capture(at: path) == expected else {
            return .deferred("the binary changed again while it was being asked")
        }
        guard ending.beginReplacing() else {
            return .failed("the server is already stopping")
        }
        let failure = execute(path, arguments, environment)
        ending.abandonReplacing()
        return .failed("the exec failed: \(String(cString: strerror(failure)))")
    }
}

public extension ServerReexec {
    /// What a replacement said when asked to read a handover back.
    enum Answer: Equatable, Sendable {
        /// It ran, succeeded, and printed this — which is what it read, still to be compared with what was written.
        case printed(String)
        /// It said something about itself: it would not start, it exited with a failure, or it was killed.
        case refused(String)
        /// It said nothing about itself: it did not answer in time, or could not be started for a reason that is not the file's.
        case unanswered(String)
    }
}

extension ServerReexec {
    /// Why a replacement was not taken over, which decides when it is tried again (``Attempts``).
    enum NotTakenOver: Equatable, Sendable {
        /// The new binary's own answer was that it cannot take this session: it would not start, failed, or read the handover back differently.
        ///
        /// Not tried again until the file changes, since the same file would answer the same way.
        case refused(String)
        /// Something that says nothing about the file got in the way — the question went unanswered in time, or the exec itself failed.
        ///
        /// Tried again, after a pause.
        case failed(String)
        /// This moment could not be handed over, whatever the file: the input in hand is more than an exec can carry, or the file changed again while it was being asked.
        ///
        /// Tried again on the next request.
        case deferred(String)

        var reason: String {
            switch self {
            case let .refused(reason), let .failed(reason), let .deferred(reason): reason
            }
        }
    }

    /// When a replacement that was not taken over is tried again — so that a takeover that keeps failing does not cost every request a probe, and one unlucky moment does not cost the session its upgrade.
    ///
    /// Taking the two kinds of failure as one is what went wrong without this: a failure that says nothing about the file, marked as a verdict on it, left a session serving the old code with the notice for good, when the next ordinary request would have taken over. So:
    /// - **A binary that refused is not asked again until the file changes.** What it said was about the file, and the same file would say it again.
    /// - **A failure that said nothing about the file is tried again after a pause**: ``firstPause`` after the first, doubling with each further failure of the same file, to at most once every ``longestPause``. The probe can hold the request that prompted it for up to its timeout, so this is also what bounds how often a probe that keeps timing out can do that.
    /// - **A moment that could not be handed over costs no probe**, and the next request tries again.
    ///
    /// Any change to the file starts over, since everything learnt was about the file it replaced.
    struct Attempts: Equatable, Sendable {
        /// How long after a first failure that says nothing about the file it is tried again.
        static let firstPause: TimeInterval = 30
        /// The longest pause between two tries of one file.
        static let longestPause: TimeInterval = 600

        private var refused: BinaryIdentity?
        private var failing: Failing?

        /// Whether the replacement `identity` may be tried now.
        func allow(_ identity: BinaryIdentity, at now: Date) -> Bool {
            if identity == refused {
                return false
            }
            if let failing, failing.identity == identity, now < failing.retryAt {
                return false
            }
            return true
        }

        /// Takes note of why `identity` was not taken over at `now`, and says when it will be tried again.
        @discardableResult
        mutating func record(_ outcome: NotTakenOver, for identity: BinaryIdentity, at now: Date) -> String {
            switch outcome {
            case .refused:
                refused = identity
                failing = nil
                return "not tried again until the file changes"
            case .failed:
                let count = (failing?.identity == identity ? failing?.count ?? 0 : 0) + 1
                let pause = Self.pause(afterFailures: count)
                failing = Failing(identity: identity, count: count, retryAt: now + pause)
                return "tried again in \(Int(pause)) seconds at the earliest"
            case .deferred:
                return "tried again on the next request"
            }
        }

        /// The pause after `count` failures of one file in a row: ``firstPause``, doubling, to at most ``longestPause``.
        static func pause(afterFailures count: Int) -> TimeInterval {
            min(firstPause * pow(2, Double(max(count, 1) - 1)), longestPause)
        }
    }
}

private extension ServerReexec.Attempts {
    /// One file's run of failures that said nothing about it.
    struct Failing: Equatable, Sendable {
        let identity: BinaryIdentity
        let count: Int
        let retryAt: Date
    }
}

extension ServerReexec {
    /// Whether an exec can carry `arguments` and `environment` within `space` bytes.
    ///
    /// The kernel's own reckoning, measured against it rather than assumed: every string with its terminator, and a pointer for each, the two lists' terminating pointers included. The path being exec'd is carried apart from this and not counted.
    static func fits(arguments: [String], environment: [String: String], within space: Int) -> Bool {
        let pointer = MemoryLayout<UnsafeMutablePointer<CChar>?>.size
        let strings = arguments.reduce(0) { $0 + $1.utf8.count + 1 }
            + environment.reduce(0) { $0 + $1.key.utf8.count + 1 + $1.value.utf8.count + 1 }
        return strings + (arguments.count + environment.count + 2) * pointer <= space
    }

    /// What the binary at `path` prints when asked to read back the handover in `environment`, run with `arguments` — or why it printed nothing.
    ///
    /// The child is never given this process's standard input: that is the client's pipe, and a child reading it would take requests meant for the server. What it prints is the whole handover, larger than a pipe holds, so it is read while the child runs: left to fill the pipe, the child would block and never exit.
    static func readBack(byBinaryAt path: String, arguments: [String], environment: [String: String], timeout: TimeInterval = 10) -> Answer {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            // Never launched, so neither end was closed on the child's behalf.
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            return launchFailure(error)
        }
        let printed = Printed()
        let reader = Thread {
            let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
            try? output.fileHandleForReading.close()
            printed.finish(with: data)
        }
        reader.name = "sift.mcp.read-back"
        reader.start()
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return .unanswered("the new binary did not answer within \(Int(timeout)) seconds")
        }
        guard process.terminationReason == .exit else {
            return .refused("the new binary was killed by signal \(process.terminationStatus) when asked to read the handover back")
        }
        guard process.terminationStatus == 0 else {
            return .refused("the new binary exited \(process.terminationStatus) when asked to read the handover back")
        }
        guard let data = printed.wait(timeout: timeout) else {
            return .unanswered("the new binary exited without closing its output")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .refused("the new binary printed something other than text when asked to read the handover back")
        }
        return .printed(text)
    }

    /// Whether a binary that could not be started says so about itself — missing, not executable, not a program this machine runs — or about the moment, which is worth trying again.
    ///
    /// Only a failure that names the file counts against it. Anything else is taken as the moment's, because the two mistakes are not alike: a bad file retried costs one failed start per pause, and a good one written off costs the session its upgrade.
    static func launchFailure(_ error: any Error) -> Answer {
        let failure = error as NSError
        let aboutTheFile: Set<Int32> = [ENOENT, EACCES, ENOEXEC, EBADARCH, EBADEXEC, EBADMACHO, ESHLIBVERS]
        // Foundation checks the file itself before starting it, and says what it found in its own domain.
        if failure.domain == NSCocoaErrorDomain || (failure.domain == NSPOSIXErrorDomain && aboutTheFile.contains(Int32(failure.code))) {
            return .refused("the new binary would not start: \(failure.localizedDescription)")
        }
        return .unanswered("the new binary could not be started: \(failure.localizedDescription)")
    }

    /// Becomes the binary at `path`, returning only when that failed, with the error number.
    ///
    /// The same pid, the standard descriptors kept and every other one closed, and the watched signals at their default and blocked until the new image arms its watch.
    static func becomeBinary(at path: String, arguments: [String], environment: [String: String]) -> Int32 {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETEXEC | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var watched = sigset_t()
        sigemptyset(&watched)
        for number in ServerSignalWatch.watched {
            sigaddset(&watched, number)
        }
        posix_spawnattr_setsigdefault(&attributes, &watched)
        posix_spawnattr_setsigmask(&attributes, &watched)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addinherit_np(&actions, descriptor)
        }

        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv + envp {
                free(pointer)
            }
        }
        var pid = pid_t()
        return posix_spawn(&pid, path, &actions, &attributes, argv, envp)
    }
}

private extension ServerReexec {
    /// What a replacement printed, handed from the thread that read it to the one waiting for it.
    final class Printed: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private let mutex = NSLock()
        private var data: Data?

        func finish(with data: Data) {
            mutex.lock()
            self.data = data
            mutex.unlock()
            done.signal()
        }

        /// Everything printed, once the output has closed; `nil` if it has not within `timeout`.
        func wait(timeout: TimeInterval) -> Data? {
            guard done.wait(timeout: .now() + timeout) == .success else { return nil }
            mutex.lock()
            defer { mutex.unlock() }
            return data
        }
    }
}
