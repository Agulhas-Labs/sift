//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftCore
import Testing

/// `audit --replay --against` ended by a Ctrl-C or a `SIGTERM`: the scratch it made and the child it started are not left behind, and it exits non-zero.
@Suite(.temporaryDirectories) struct ReplayInterruptionTests {
    /// A run signalled while the other binary's child hangs, in the schema probe or in a replayed request, removes the scratch it was using, kills that child, and exits with the signal's status.
    ///
    /// The run is a `sift` of its own with its home and its advice directory moved into the test's scratch, so the replay's scratch is nowhere a live session reads. The hanging child writes the directory it was handed, whose parent is the scratch that request was made from: the schema probe's repository in the probe, the other hook's state in the replay.
    ///
    /// Every wait is for an outcome, bounded only by a deadline far past what any machine takes: the run starts its child after a probe and a schema check that a heavily loaded machine can stretch past half a minute.
    @Test(.timeLimit(.minutes(4)), arguments: [(SIGINT, "index"), (SIGTERM, "replay-hook")])
    func aSignalledRunRemovesItsScratchAndStopsItsChild(signal number: Int32, hangingIn request: String) async throws {
        let sift = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)")
        let scratch = try TemporaryDirectory.make("interrupted")
        let pidFile = scratch.appendingPathComponent("child.pid")
        let handed = scratch.appendingPathComponent("handed")
        let live = scratch.appendingPathComponent("home", isDirectory: true).appendingPathComponent(".sift", isDirectory: true)
        let projects = scratch.appendingPathComponent("projects", isDirectory: true)
        for directory in [live, projects] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let hang = #"echo "$3" > '\#(handed.path)'; echo $$ > '\#(pidFile.path)'; exec sleep 600"#
        // A stub that gets as far as the replay has to pass the schema probe, which compares the resolver fingerprint as well as the schema.
        let fingerprint = request == "index" ? "" : try await ReplayAgainstTests.realResolutionFingerprint(sift: sift)
        let indexing = request == "index" ? hang : #"mkdir -p "$3/.sift" && /usr/bin/sqlite3 "$3/.sift/index.db" 'PRAGMA user_version=\#(IndexSchema.version); CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL); INSERT INTO meta(key, value) VALUES("resolution_fingerprint", "\#(fingerprint)");'; exit 0"#
        let stub = try Self.script("""
        case " $* " in *" --help "*) exit 0 ;; esac
        case "$1" in
          index) \(indexing) ;;
          replay-hook) mkdir -p "$3"; \(hang) ;;
        esac
        """)
        let transcript = projects.appendingPathComponent("replayed-session.jsonl")
        let lines = try [TranscriptAuditReplayTests.call("echo one", id: "c1", cwd: scratch.path, at: "2026-09-20T10:00:00Z")]
        try Data(lines.joined(separator: [0x0A])).write(to: transcript)
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = live.deletingLastPathComponent().path
        environment["SIFT_ADVICE_DIR"] = live.appendingPathComponent("advice").path
        environment["SIFT_USAGE_LOG"] = live.appendingPathComponent("usage.jsonl").path
        let process = Process()
        process.executableURL = sift
        process.arguments = ["audit", "--replay", "--projects", projects.path, "--transcript", transcript.path, "--against", stub.path]
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            if let child = Self.pid(in: pidFile) {
                kill(child, SIGKILL)
            }
            if let made = Self.scratch(handedIn: handed) {
                try? FileManager.default.removeItem(atPath: made)
            }
        }
        // Until the child has started, or the run has ended without starting one.
        let started = Date()
        while Self.pid(in: pidFile) == nil, process.isRunning, Date().timeIntervalSince(started) < Self.patience {
            try await Task.sleep(for: .milliseconds(50))
        }
        let child = try #require(Self.pid(in: pidFile), "the other binary's \(request) never started")
        let made = try #require(Self.scratch(handedIn: handed))
        try #require(FileManager.default.fileExists(atPath: made), "the run made no scratch at \(made)")

        kill(process.processIdentifier, number)
        await InPlaceAnswerTests.onItsOwnThread { process.waitUntilExit() }

        #expect(process.terminationReason == .exit && process.terminationStatus == 128 + number, "ended \(process.terminationReason.rawValue) with \(process.terminationStatus)")
        #expect(!FileManager.default.fileExists(atPath: made), "\(made) is left behind")
        var gone = false
        let stopped = Date()
        while Date().timeIntervalSince(stopped) < Self.patience {
            errno = 0
            gone = kill(child, 0) == -1 && errno == ESRCH
            if gone {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(gone, "the child \(child) is still running")
    }

    /// Once the run is stopped, a unit of work is refused before it runs, so nothing it would write lands in the scratch the stop removed.
    @Test func aUnitOfWorkAfterTheStopIsRefused() throws {
        let written = try TemporaryDirectory.make("stopped").appendingPathComponent("state", isDirectory: true)
        let interruptions = ReplayInterruptions()
        interruptions.track(written)
        interruptions.stop()

        let outcome: Void? = interruptions.admits { Self.write(into: written) }

        #expect(outcome == nil)
        #expect(!FileManager.default.fileExists(atPath: written.path), "a unit of work wrote into \(written.path) after the stop")
    }

    /// The stop removes the scratch only once the unit of work in flight has ended, so that unit's last write goes with the rest rather than landing after the removal.
    @Test(.timeLimit(.minutes(1))) func theStopRemovesTheScratchOnlyAfterTheUnitOfWorkInFlight() async throws {
        let written = try TemporaryDirectory.make("stopped").appendingPathComponent("state", isDirectory: true)
        let interruptions = ReplayInterruptions()
        interruptions.track(written)

        let left = await InPlaceAnswerTests.onItsOwnThread {
            let inFlight = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                _ = interruptions.admits {
                    Self.write(into: written)
                    inFlight.signal()
                    Thread.sleep(forTimeInterval: 0.5)
                    Self.write(into: written)
                }
                finished.signal()
            }
            inFlight.wait()
            interruptions.stop()
            finished.wait()
            return FileManager.default.fileExists(atPath: written.path)
        }

        #expect(!left, "\(written.path) was written again after the stop removed it")
    }

    /// Once the run is stopped, a launch is refused before its child is started, so no child is ever alive that the stop did not kill.
    @Test func aLaunchAfterTheStopIsRefused() {
        let interruptions = ReplayInterruptions()
        interruptions.stop()
        var started = false

        let child = interruptions.launch {
            started = true
            return getpid()
        }

        #expect(child == nil)
        #expect(!started, "the launch ran after the stop")
    }

    /// A child launched through the interruptions is killed by the stop and has exited by the time the stop returns.
    @Test func aLaunchedChildHasExitedByTheTimeTheStopReturns() throws {
        let interruptions = ReplayInterruptions()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["600"]
        let child = try #require(interruptions.launch { (try? process.run()) != nil ? process.processIdentifier : nil })

        interruptions.stop()

        let exited = Self.hasExited(child)
        #expect(exited, "the child \(child) was still running when the stop returned")
        if !exited {
            kill(child, SIGKILL)
        }
    }

    /// A child the other binary is run as for a replayed request is killed by the stop, and the request ends at once rather than at its deadline.
    @Test(.timeLimit(.minutes(2))) func aChildOfTheOtherBinaryIsKilledByTheStop() async throws {
        let scratch = try TemporaryDirectory.make("stopped")
        let pidFile = scratch.appendingPathComponent("child.pid")
        let stub = try Self.script("echo $$ > '\(pidFile.path)'; exec sleep 600")
        let state = scratch.appendingPathComponent("against", isDirectory: true)
        let interruptions = ReplayInterruptions()

        let outcome = await InPlaceAnswerTests.onItsOwnThread {
            let finished = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                let hook = ExternalReplayHook(binary: stub, directory: state, timeBudget: 30, margin: 0, interruptions: interruptions)
                _ = hook.verdict(payload: ["tool_name": "Bash", "tool_input": ["command": "echo 1"]], cwd: "/", at: nil, decides: true)
                finished.signal()
            }
            let started = Date()
            while Self.pid(in: pidFile) == nil, Date().timeIntervalSince(started) < Self.patience {
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard let child = Self.pid(in: pidFile) else { return (child: pid_t?.none, exited: false, ended: false) }
            interruptions.stop()
            let exited = Self.hasExited(child)
            return (child: pid_t?.some(child), exited: exited, ended: finished.wait(timeout: .now() + 10) == .success)
        }

        let child = try #require(outcome.child, "the other binary's child never started")
        #expect(outcome.exited, "the child \(child) was still running when the stop returned")
        #expect(outcome.ended, "the request went on after its child was stopped")
        if !outcome.exited {
            kill(child, SIGKILL)
        }
    }

    /// How long a wait for an outcome goes on before the outcome counts as never coming.
    private static let patience: TimeInterval = 90

    /// The pid a stub wrote to `file`, if it has written one yet.
    private static func pid(in file: URL) -> pid_t? {
        (try? String(contentsOf: file, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// The scratch directory holding the one a stub wrote to `file`, if it has written one yet.
    private static func scratch(handedIn file: URL) -> String? {
        (try? String(contentsOf: file, encoding: .utf8)).map { ($0.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).deletingLastPathComponent }
    }

    /// Whether the child `pid` has exited, asked without waiting and without reaping it: a zombie answers with its pid, one already reaped with `ECHILD`.
    private static func hasExited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else { return errno == ECHILD }
        return info.si_pid == pid
    }

    /// Writes one file into `directory`, making it first, as the replay's own state writers do.
    private static func write(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("1".utf8).write(to: directory.appendingPathComponent("entry"))
    }

    /// A stand-in for another sift binary that runs `body` for every request.
    private static func script(_ body: String) throws -> URL {
        let script = try TemporaryDirectory.make("stub").appendingPathComponent("sift")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}
