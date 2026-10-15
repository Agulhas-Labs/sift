//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a run whose command exits while something it started still holds its output open: the run returns once the output goes quiet, with every byte the command wrote, and says what it left running.
///
/// These run real subprocesses. Each holder is a `sleep` far longer than the injected patience, which prints its pid first so the test can end it; nothing here races the window, because the window only opens once the command has exited and everything it wrote is already in the pipe.
@Suite(.temporaryDirectories)
struct RunLaunchHeldOutputTests {
    /// Small enough that a held run returns at once, and far inside every holder's sleep.
    private static let patience = RunOutputPatience(grace: 0.2, cap: 5)

    /// A command that exits while a background process it started keeps the output open returns its own exit code and output well before the holder ends, whichever way it was started.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aHolderOutlivingTheCommandDoesNotHoldTheRun(setAside: Bool) throws {
        let root = try TestSources.makeTempDirectory()
        let holder = HolderPid()
        defer { holder.end() }
        let started = Date()

        let run = try Self.run(["sh", "-c", "sleep 30 & echo $!; echo x; exit 1"], in: root, setAside: setAside, holder: holder)

        #expect(Date().timeIntervalSince(started) < 15)
        #expect(run.outcome.exitCode == 1)
        #expect(run.lines.dropFirst() == ["x"])
        #expect(holder.pid != nil)
    }

    /// Everything the command wrote before it exited is read, even where it wrote far more than the pipe holds and a holder keeps the pipe open past its exit.
    @Test(.timeLimit(.minutes(1)))
    func everyLineTheCommandWroteIsReadDespiteTheHolder() throws {
        let root = try TestSources.makeTempDirectory()
        let holder = HolderPid()
        defer { holder.end() }

        let run = try Self.run(["sh", "-c", "sleep 30 & echo $!; i=1; while [ $i -le 20000 ]; do echo \"line $i\"; i=$((i + 1)); done"], in: root, setAside: false, holder: holder)

        let expected = (1 ... 20000).map { "line \($0)" }
        #expect(run.outcome.exitCode == 0)
        #expect(Array(run.lines.dropFirst()) == expected)
        let logged = try #require(run.outcome.log?.contents())
        #expect(Array((String(bytes: logged, encoding: .utf8) ?? "").split(separator: "\n").dropFirst().map(String.init)) == expected)
        #expect(run.outcome.heldOutput != nil)
    }

    /// A run that stopped waiting names what the command left running, by pid and name, in one line.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aHeldRunNamesWhatTheCommandLeftRunning(setAside: Bool) throws {
        let root = try TestSources.makeTempDirectory()
        let holder = HolderPid()
        defer { holder.end() }

        let run = try Self.run(["sh", "-c", "sleep 30 & echo $!; exit 1"], in: root, setAside: setAside, holder: holder)

        let pid = try #require(holder.pid)
        let held = try #require(run.outcome.heldOutput)

        #expect(held.holders.contains(RunHeldOutput.Holder(pid: pid, name: "sleep")))
        #expect(held.note.hasPrefix("sift run: the command exited, but its output was still held open — not waited for; still running from it: "))
        #expect(held.note.contains("pid \(pid) (sleep)"))
        #expect(!held.note.contains("\n"))
    }

    /// A command whose output reaches its end — the run as it always was — carries no note at all.
    @Test(arguments: [false, true])
    func aRunWhoseOutputEndsCarriesNoNote(setAside: Bool) throws {
        let root = try TestSources.makeTempDirectory()

        let run = try Self.run(["sh", "-c", "echo x; exit 3"], in: root, setAside: setAside, holder: nil)

        #expect(run.outcome.exitCode == 3)
        #expect(run.lines == ["x"])
        #expect(run.outcome.heldOutput == nil)
    }

    /// The note says so even where nothing left running can be named.
    @Test
    func aNoteWithNothingToNameIsStillOneLine() {
        #expect(RunHeldOutput(holders: []).note == "sift run: the command exited, but its output was still held open — not waited for.")
    }

    /// Runs `arguments` with the test's patience, through a set-aside where asked, recording the first line of output as the holder's pid the moment it arrives.
    private static func run(_ arguments: [String], in root: URL, setAside: Bool, holder: HolderPid?) throws -> (outcome: RunOutcome, lines: [String]) {
        let collected = Collected()
        let outcome = try RunLauncher(workingDirectory: root, repositoryRoot: nil, runLogDirectory: root).run(
            arguments,
            passingThrough: { chunk in
                collected.append(chunk)
                if let holder, holder.pid == nil, let first = collected.lines.first, let pid = Int32(first) {
                    holder.record(pid)
                }
            },
            children: setAside ? SetAsideChildren() : nil,
            patience: patience
        )
        return (outcome, collected.lines)
    }
}

extension RunLaunchHeldOutputTests {
    /// The holder's pid, recorded from the output as soon as it is printed so the holder is ended even when the run under test never returns in time.
    private final class HolderPid: @unchecked Sendable {
        private let gate = NSLock()
        private var recorded: Int32?

        var pid: Int32? {
            gate.withLock { recorded }
        }

        func record(_ pid: Int32) {
            gate.withLock { recorded = recorded ?? pid }
        }

        func end() {
            if let pid {
                kill(pid, SIGKILL)
            }
        }
    }

    /// The output passed through, as bytes and as lines.
    private final class Collected: @unchecked Sendable {
        private let gate = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            gate.withLock { data.append(chunk) }
        }

        var lines: [String] {
            gate.withLock { String(bytes: data, encoding: .utf8) ?? "" }
                .split(separator: "\n")
                .map(String.init)
        }
    }
}
