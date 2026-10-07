//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers a server picking up a replaced binary without a restart: the same process, the same pipes, and the next answer from the new code.
///
/// **Why these are subprocess tests.** An exec replaces the process that runs it, so no in-process assertion can watch one happen — the same reason ``ServerExitTests`` is shaped this way. Each test that replaces a binary launches a *copy* of this build's `sift`, so the file it replaces is one no other test and no real session is running, and every test points both per-user logs at files of its own, with no conversation named in its environment: its calls are real tool calls, and the record a person reads must not gain a line from them.
@Suite(.serialized, .temporaryDirectories)
struct ServerReexecTests {
    /// The whole claim: replace the binary mid-session and the next answer comes from the new one — no notice, the same pid, the session carrying on — and the log says a re-exec, not a stop and a start.
    @Test
    func aReplacedBinaryTakesTheSessionOverInPlace() async throws {
        let server = try LaunchedServer.start()
        defer { server.clearUp() }
        try await server.initialise()
        let before = try await server.call(id: 2)
        #expect(!Self.text(of: before).contains("replaced on disk"))

        try server.replaceBinary(with: server.built)
        let answer = try await server.call(id: 3)

        #expect(!Self.text(of: answer).contains("replaced on disk"), "the answer after the replacement still came from the old code")
        #expect(Self.text(of: answer).contains("struct Alpha"))
        let start = try #require(server.entries().first { $0.event == "start" })
        #expect(start.pid == server.process.processIdentifier)
        #expect(server.entries().map(\.event) == ["start", "reexec"], "the log does not read as one process that re-exec'd")
        // One process throughout: the kernel's start time still agrees with the start line, which an exec keeps.
        #expect(ServerLifecycleReport.isStillRunning(start))

        _ = try await server.call(id: 4)
        server.closeInput()
        #expect(server.waitForExit(), "the server did not exit once its input closed")
        #expect(server.process.terminationStatus == 0)
        #expect(server.entries().map(\.event) == ["start", "reexec", "stop"])
        #expect(server.entries().last?.reason == "input-closed")
    }

    /// A replacement that cannot say it reads this handover is not exec'd into — an older build would drop the request it was handed — and the session serves on from the old code, saying so.
    @Test
    func aReplacementThatCannotTakeOverLeavesTheSessionServing() async throws {
        let server = try LaunchedServer.start()
        defer { server.clearUp() }
        try await server.initialise()
        // What a build from before handovers existed answers the question with.
        let older = server.directory.appendingPathComponent("older")
        try "#!/bin/sh\necho \"Error: Unknown option '--read-handover'\" >&2\nexit 64\n".write(to: older, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: older.path)

        try server.replaceBinary(with: older)
        let answer = try await server.call(id: 2)

        #expect(Self.text(of: answer).contains("replaced on disk"))
        #expect(!server.entries().contains { $0.event == "reexec" })
        #expect(server.process.isRunning)
        let later = try await server.call(id: 3)
        #expect(Self.text(of: later).contains("struct Alpha"))
        server.closeInput()
        #expect(server.waitForExit())
        #expect(server.process.terminationStatus == 0)
    }

    /// A later build that no longer accepts an option the server was started with is declined, not exec'd into: the probe runs with this process's own argument vector, so a build that renamed or dropped `--root` fails the probe the same way it would fail the real exec — and the session serves on from the old code, saying so.
    ///
    /// Before the probe ran the exec's own arguments, it asked a fixed `mcp --read-handover`, which never named `--root`: this fake binary reads the handover back correctly under that fixed probe (it would have been exec'd), and only fails once asked with the option the server actually runs with.
    @Test
    func aReplacementThatCannotAcceptTheServersOwnOptionIsDeclined() async throws {
        let server = try LaunchedServer.start()
        defer { server.clearUp() }
        try await server.initialise()
        let incompatible = server.directory.appendingPathComponent("incompatible")
        let script = "#!/bin/sh\n"
            + "for arg in \"$@\"; do\n"
            + "    if [ \"$arg\" = \"--root\" ]; then\n"
            + "        echo \"Error: Unknown option '--root'\" >&2\n"
            + "        exit 64\n"
            + "    fi\n"
            + "done\n"
            + "printf '%s' \"$\(ServerHandover.environmentKey)\"\n"
        try script.write(to: incompatible, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: incompatible.path)

        try server.replaceBinary(with: incompatible)
        let answer = try await server.call(id: 2)

        #expect(Self.text(of: answer).contains("replaced on disk"))
        #expect(!server.entries().contains { $0.event == "reexec" })
        #expect(server.process.isRunning)
        let later = try await server.call(id: 3)
        #expect(Self.text(of: later).contains("struct Alpha"))
        server.closeInput()
        #expect(server.waitForExit())
    }

    /// Two requests written in one packet both survive a real exec: the one that follows the request the takeover was prompted by is not lost — pinned end to end, not just through the in-process stand-in.
    @Test
    func twoRequestsInOneWriteBothSurviveARealExec() async throws {
        let server = try LaunchedServer.start()
        defer { server.clearUp() }
        try await server.initialise()
        try server.replaceBinary(with: server.built)

        try server.sendTogether([
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "digest", "arguments": ["target": "Alpha"]]],
            ["jsonrpc": "2.0", "id": 3, "method": "ping"],
        ])
        let answer = try await server.next()
        let pong = try await server.next()

        #expect(answer["id"] as? Int == 2)
        #expect(!Self.text(of: answer).contains("replaced on disk"), "the request that prompted the takeover was answered by the old code")
        #expect(Self.text(of: answer).contains("struct Alpha"))
        #expect(pong["id"] as? Int == 3, "the request that arrived after it in the same write was lost")
        #expect(server.entries().map(\.event) == ["start", "reexec"])
        server.closeInput()
        #expect(server.waitForExit())
    }

    /// A request larger than an exec can carry is answered by the old code, with the notice and no stop recorded — and the next, ordinary request takes the replacement over.
    ///
    /// The size is a fact about that moment, not about the new binary, so it is checked before anything is asked of the binary and holds nothing against it: before that, the one large request right after an upgrade left the whole session on the old code, when the next request would have taken over fine.
    @Test
    func aRequestTooLargeToHandOverLeavesTheNextOneToTakeOver() async throws {
        let server = try LaunchedServer.start()
        defer { server.clearUp() }
        try await server.initialise()

        try server.replaceBinary(with: server.built)
        let padding = String(repeating: "p", count: sysconf(_SC_ARG_MAX))
        let answer = try await server.call(id: 2, arguments: ["target": "Alpha", "padding": padding])

        #expect(Self.text(of: answer).contains("replaced on disk"))
        #expect(!server.entries().contains { $0.event == "reexec" || $0.event == "stop" })
        #expect(server.process.isRunning)
        #expect(server.stderr().contains("more than an exec can carry"))
        let later = try await server.call(id: 3)
        #expect(Self.text(of: later).contains("struct Alpha"))
        #expect(!Self.text(of: later).contains("replaced on disk"), "the ordinary request after a large one was still answered by the old code")
        #expect(server.entries().map(\.event) == ["start", "reexec"])
        server.closeInput()
        #expect(server.waitForExit())
        #expect(server.entries().map(\.event) == ["start", "reexec", "stop"])
    }

    /// The parent watch carries over: after a takeover, the server still ends when the process that spawned it does, and says so.
    ///
    /// The watch the first image armed is gone with it; the new image re-arms on the pid the first one read, and a parent that died during the exec would be caught by the second reading. Killed outright, with the client end still open, so nothing but the watch can explain the exit.
    @Test
    func aTakenOverServerStillEndsWithTheProcessThatSpawnedIt() async throws {
        let server = try LaunchedServer.start(underWrapper: true)
        defer { server.clearUp() }
        try await server.initialise()
        try server.replaceBinary(with: server.built)
        let answer = try await server.call(id: 2)
        #expect(!Self.text(of: answer).contains("replaced on disk"))
        let start = try #require(server.entries().first { $0.event == "start" })
        #expect(server.entries().contains { $0.event == "reexec" && $0.pid == start.pid })

        kill(server.process.processIdentifier, SIGKILL)
        let stop = try #require(await server.stopLine(), "the server outlived the process that spawned it")

        #expect(stop.reason == "parent-exited")
        #expect(stop.detail == "parent pid \(server.process.processIdentifier)")
        #expect(stop.pid == start.pid)
    }

    /// The signal watch carries over: after a takeover, a `SIGTERM` is recorded by the new image and ends it with the status a signal gives.
    @Test
    func aTakenOverServerStillRecordsTheSignalThatEndsIt() async throws {
        let server = try LaunchedServer.start()
        defer { server.clearUp() }
        try await server.initialise()
        try server.replaceBinary(with: server.built)
        let answer = try await server.call(id: 2)
        #expect(!Self.text(of: answer).contains("replaced on disk"))

        kill(server.process.processIdentifier, SIGTERM)

        #expect(server.waitForExit())
        #expect(server.process.terminationStatus == 128 + SIGTERM)
        #expect(server.entries().map(\.event) == ["start", "reexec", "stop"])
        #expect(server.entries().last?.reason == "signalled")
        #expect(server.entries().last?.detail == "SIGTERM")
    }

    /// A signal already waiting when a new image starts is recorded, and ends the server — not thrown away while its watch arms.
    ///
    /// The state an exec leaves a new image in: the watched signals at their default and blocked on its only thread, so a `kill` sent while it is still starting is held there until the watch takes it. The signal here is sent before the image has run an instruction, which is the widest that window gets, and the server's client is still connected, so nothing but the signal can end it. Read from the thread the watch is armed on rather than the main one, it was never seen: the server kept serving with a start line and no stop.
    @Test
    func aSignalWaitingWhenANewImageStartsIsRecordedAndEndsIt() throws {
        let server = try SuspendedServer.start(pending: SIGTERM)
        defer { server.clearUp() }

        let status = server.waitForExit()

        #expect(status == 128 + SIGTERM, "the server did not end on the signal that was waiting for it")
        #expect(server.entries().map(\.event) == ["start", "stop"])
        #expect(server.entries().last?.reason == "signalled")
        #expect(server.entries().last?.detail == "SIGTERM")
    }

    private static func text(of response: [String: Any]) -> String {
        let result = response["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        return content?.first?["text"] as? String ?? ""
    }
}

private extension ServerReexecTests {
    /// A copy of this build's `sift` running as a real server over pipes, rooted at a small repository, its logs and its binary in a directory of its own.
    final class LaunchedServer: @unchecked Sendable {
        let built: URL
        let directory: URL
        let binary: URL
        let process: Process
        private let toServer: Pipe
        private let responses: ServerResponses

        private init(built: URL, directory: URL, binary: URL, process: Process, toServer: Pipe, responses: ServerResponses) {
            self.built = built
            self.directory = directory
            self.binary = binary
            self.process = process
            self.toServer = toServer
            self.responses = responses
        }

        /// Launched directly, or else as the child of a shell that stays alive as its parent, so the parent can be killed on its own.
        static func start(underWrapper: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) throws -> LaunchedServer {
            let built = try #require(
                BuiltExecutable.sift,
                "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)",
                sourceLocation: sourceLocation
            )
            let directory = try TemporaryDirectory.make("reexec")
            let binary = directory.appendingPathComponent("sift")
            try FileManager.default.copyItem(at: built, to: binary)
            let root = try MCPTestRepo.make()

            let process = Process()
            if underWrapper {
                // `& wait` keeps the shell alive as the parent; `<&0` keeps the server's input on this test's pipe.
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "'\(binary.path)' mcp --root '\(root.path)' <&0 & wait"]
            } else {
                process.executableURL = binary
                process.arguments = ["mcp", "--root", root.path]
            }
            var environment = ProcessInfo.processInfo.environment
            environment["SIFT_SERVER_LOG"] = directory.appendingPathComponent("server.jsonl").path
            environment["SIFT_USAGE_LOG"] = directory.appendingPathComponent("usage.jsonl").path
            // No conversation: its calls are filed under none, and it can claim no caller slip left for a real one.
            environment["CLAUDE_CODE_SESSION_ID"] = nil
            process.environment = environment
            let toServer = Pipe()
            let fromServer = Pipe()
            process.standardInput = toServer
            process.standardOutput = fromServer
            let stderr = directory.appendingPathComponent("stderr.txt")
            FileManager.default.createFile(atPath: stderr.path, contents: nil)
            process.standardError = try FileHandle(forWritingTo: stderr)
            try process.run()
            return LaunchedServer(
                built: built,
                directory: directory,
                binary: binary,
                process: process,
                toServer: toServer,
                responses: ServerResponses(fromServer.fileHandleForReading)
            )
        }

        func initialise() async throws {
            try send([
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "test", "version": "0"]],
            ])
            _ = try await next()
        }

        /// A `digest` call, answered — with the id it was sent under, or the test fails here rather than later.
        func call(
            id: Int,
            arguments: [String: Any] = ["target": "Alpha"],
            sourceLocation: SourceLocation = #_sourceLocation
        ) async throws -> [String: Any] {
            try send(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": "digest", "arguments": arguments]])
            let answer = try await next(sourceLocation: sourceLocation)
            #expect(answer["id"] as? Int == id, sourceLocation: sourceLocation)
            return answer
        }

        func send(_ payload: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: payload)
            data.append(0x0A)
            try toServer.fileHandleForWriting.write(contentsOf: data)
        }

        /// `payloads`, one per line, in a single `write(2)` — so the read that takes the first is the only chance to hand the rest on.
        func sendTogether(_ payloads: [[String: Any]]) throws {
            var data = Data()
            for payload in payloads {
                var line = try JSONSerialization.data(withJSONObject: payload)
                line.append(0x0A)
                data.append(line)
            }
            try toServer.fileHandleForWriting.write(contentsOf: data)
        }

        func next(sourceLocation: SourceLocation = #_sourceLocation) async throws -> [String: Any] {
            let line = try #require(await responses.next(within: 60), "no answer within a minute", sourceLocation: sourceLocation)
            return try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], sourceLocation: sourceLocation)
        }

        /// The upgrade shape: `rm`, then a new file at the same path — never a copy over the old inode.
        func replaceBinary(with source: URL) throws {
            try FileManager.default.removeItem(at: binary)
            try FileManager.default.copyItem(at: source, to: binary)
        }

        func entries() -> [ServerLifecycleEntry] {
            ServerLifecycleReport.entries(in: directory.appendingPathComponent("server.jsonl"))
        }

        func stderr() -> String {
            (try? String(contentsOf: directory.appendingPathComponent("stderr.txt"), encoding: .utf8)) ?? ""
        }

        /// The stop line, once one is written.
        func stopLine() async -> ServerLifecycleEntry? {
            for _ in 0 ..< 3000 {
                if let stop = entries().last(where: { $0.event == "stop" }) {
                    return stop
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return nil
        }

        func closeInput() {
            toServer.fileHandleForWriting.closeFile()
        }

        /// Polls rather than blocking on `waitUntilExit`, so a server that never exits fails the test instead of hanging the suite.
        func waitForExit(seconds: Int = 30) -> Bool {
            let deadline = Date() + Double(seconds)
            while process.isRunning, Date() < deadline {
                usleep(20000)
            }
            return !process.isRunning
        }

        /// Whatever happened, nothing this test launched is left running, and nothing it made is left on disk.
        func clearUp() {
            if let start = entries().first(where: { $0.event == "start" }), ServerLifecycleReport.isStillRunning(start) {
                kill(start.pid, SIGKILL)
            }
            if process.isRunning {
                process.terminate()
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// This build's `sift` started in the signal state an exec hands a new image — the watched signals at their default and blocked on its only thread — with one of them already sent before it runs.
    ///
    /// `posix_spawn` with the attributes ``ServerReexec`` execs with, plus `POSIX_SPAWN_START_SUSPENDED`, so the signal can be sent while the image has not run an instruction; `SIGCONT` then lets it run. The test process cannot exec itself away to show the exec itself, and what the new image meets is the same either way: a signal pending on its main thread, blocked there, with nothing listening yet. Its input is a pipe this test holds open, so a client is still connected and only the signal can end it.
    final class SuspendedServer: @unchecked Sendable {
        let pid: pid_t
        private let directory: URL
        private let toServer: Pipe
        private var reaped: Int32?

        private init(pid: pid_t, directory: URL, toServer: Pipe) {
            self.pid = pid
            self.directory = directory
            self.toServer = toServer
        }

        static func start(pending number: Int32, sourceLocation: SourceLocation = #_sourceLocation) throws -> SuspendedServer {
            let built = try #require(
                BuiltExecutable.sift,
                "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)",
                sourceLocation: sourceLocation
            )
            let directory = try TemporaryDirectory.make("pending")
            let root = try MCPTestRepo.make()
            var environment = ProcessInfo.processInfo.environment
            environment["SIFT_SERVER_LOG"] = directory.appendingPathComponent("server.jsonl").path
            environment["SIFT_USAGE_LOG"] = directory.appendingPathComponent("usage.jsonl").path
            environment["CLAUDE_CODE_SESSION_ID"] = nil
            let toServer = Pipe()

            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            let flags = POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
            posix_spawnattr_setflags(&attributes, Int16(flags))
            var watched = sigset_t()
            sigemptyset(&watched)
            for watchedNumber in ServerSignalWatch.watched {
                sigaddset(&watched, watchedNumber)
            }
            posix_spawnattr_setsigdefault(&attributes, &watched)
            posix_spawnattr_setsigmask(&attributes, &watched)
            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_adddup2(&actions, toServer.fileHandleForReading.fileDescriptor, STDIN_FILENO)
            posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

            let arguments = [built.path, "mcp", "--root", root.path]
            let argv = arguments.map { strdup($0) } + [nil]
            let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer {
                for pointer in argv + envp {
                    free(pointer)
                }
            }
            var pid = pid_t()
            let spawned = posix_spawn(&pid, built.path, &actions, &attributes, argv, envp)
            try #require(spawned == 0, "could not start the server: \(String(cString: strerror(spawned)))", sourceLocation: sourceLocation)
            kill(pid, number)
            kill(pid, SIGCONT)
            return SuspendedServer(pid: pid, directory: directory, toServer: toServer)
        }

        /// The exit status a shell would report — `128 + n` for a signal — or `nil` when it has not ended within `seconds`.
        func waitForExit(seconds: Int = 10) -> Int32? {
            let deadline = Date() + Double(seconds)
            while reaped == nil, Date() < deadline {
                var status: Int32 = 0
                if waitpid(pid, &status, WNOHANG) == pid {
                    let signal = status & 0x7F
                    reaped = signal == 0 ? (status >> 8) & 0xFF : 128 + signal
                } else {
                    usleep(20000)
                }
            }
            return reaped
        }

        func entries() -> [ServerLifecycleEntry] {
            ServerLifecycleReport.entries(in: directory.appendingPathComponent("server.jsonl"))
        }

        /// Whatever happened, the server this test started is gone and reaped, and nothing it made is left on disk.
        func clearUp() {
            if reaped == nil {
                kill(pid, SIGKILL)
                var status: Int32 = 0
                waitpid(pid, &status, 0)
            }
            toServer.fileHandleForWriting.closeFile()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
