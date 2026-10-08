//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// The stop gate reads a green run however its line was laid out, and asks git about each directory once per stop.
@Suite(.temporaryDirectories)
struct StopLowsTests {
    /// A run continued onto its own line, one carrying a comment, and one followed by blanks are the same run, and clear the edit as it does.
    @Test(arguments: ["cd Sources && \\\nsift run -- swift build", "sift run -- swift build # check", "sift run -- swift build;  "])
    func aGreenRunLaidOutAnyOfTheseWaysClearsTheEdit(command: String) async throws {
        let fixture = try StopGateFixture()
        let transcript = try fixture.transcript([
            StopGateFixture.edit("t1", path: fixture.depot),
            StopGateFixture.result("t1"),
            StopGateFixture.bash("t2", command: command, cwd: fixture.repo.path),
            StopGateFixture.result("t2"),
        ])

        #expect(await fixture.hook(["transcript_path": transcript]).isEmpty)
    }

    /// Comments, line continuations and blank statements are read as the shell reads them, and never widen what a run vouches for.
    @Test(arguments: [
        ("cd xc && \\\nsift run -- swift build", ["/w/repo/xc"]),
        ("sift run -- swift build # check", ["/w/repo"]),
        ("sift run -- swift build;  ", ["/w/repo"]),
        ("# cd /w/xc && \\\nsift run -- swift build", ["/w/repo"]),
        ("sift run -- swift build \\\n| tail -5", []),
        ("sift run -- swift build # fine\necho done", []),
        ("sift run -- swift build;  \necho done", []),
        ("cd /w/xc\nsift run -- swift build", []),
    ])
    func theDirectoriesARunLaidOutThisWayVouchesFor(command: String, directories: [String]) {
        #expect(SwiftEditsSinceGreenRun.validatedDirectories(of: command, cwd: "/w/repo") == directories)
    }

    /// Six edited files in three directories, nothing run: git is asked about each directory once, not once per file and again per directory.
    @Test
    func aStopAsksForTheRootOfEachEditedDirectoryOnce() async throws {
        let fixture = try StopGateFixture()
        let transcript = try fixture.transcript(Self.edits(in: fixture))

        let (printed, asked) = await Self.stop(fixture, transcript: transcript)
        let reason = try #require(try StopGateFixture.blockReason(of: printed))

        #expect(reason.contains("6 Swift files"))
        #expect(asked.count == 3)
        #expect(Set(asked).count == asked.count)
    }

    /// With a green run in another repository the edits stand, and the transcript's reading and the repositories' share one answer per directory: three edited, one run.
    @Test
    func theTranscriptAndTheRepositoriesShareOneAnswerPerDirectory() async throws {
        let fixture = try StopGateFixture()
        let other = try MCPTestRepo.make(declaring: "Gauge")
        let transcript = try fixture.transcript(Self.edits(in: fixture) + [
            StopGateFixture.bash("r1", command: "sift run -- swift build", cwd: other.path),
            StopGateFixture.result("r1"),
        ])

        let (printed, asked) = await Self.stop(fixture, transcript: transcript)
        let reason = try #require(try StopGateFixture.blockReason(of: printed))

        #expect(reason.contains("6 Swift files"))
        #expect(asked.count == 4)
        #expect(Set(asked).count == asked.count)
    }

    /// Two edits in each of three directories, each answered green.
    private static func edits(in fixture: StopGateFixture) throws -> [[String: Any]] {
        var lines: [[String: Any]] = []
        for (index, path) in ["A", "B", "C"].flatMap({ ["Sources/\($0)/One.swift", "Sources/\($0)/Two.swift"] }).enumerated() {
            let file = try fixture.file(path)
            lines += [StopGateFixture.edit("e\(index)", path: file), StopGateFixture.result("e\(index)")]
        }
        return lines
    }

    /// What the hook printed for a stop over `transcript`, and every directory the discovery bound around it was asked about.
    private static func stop(_ fixture: StopGateFixture, transcript: String) async -> (printed: String, asked: [String]) {
        let asked = AskedDirectories()
        let discovery = RootDiscovery { directory in
            asked.note(directory.path)
            return GitContext.spawnedRoot(from: directory)
        }
        let payload: [String: Any] = ["hook_event_name": "Stop", "session_id": "s1", "cwd": fixture.repo.path, "stop_hook_active": false, "transcript_path": transcript]
        let input = ResultBox<[String: Any]>()
        input.value = payload
        let recorded = RecordedOutput()
        let marks = fixture.marks
        await InPlaceAnswerTests.onItsOwnThread {
            RootDiscovery.$current.withValue(discovery) {
                StopCommand.answer(to: input.value ?? [:], output: recorded.output, marks: marks, timeBudget: InPlaceAnswerTests.roomy)
            }
        }
        return (recorded.printed, asked.all)
    }
}

private extension StopLowsTests {
    /// The directories a discovery was asked about, in order, from whichever thread asked.
    final class AskedDirectories: @unchecked Sendable {
        private let lock = NSLock()
        private var directories: [String] = []

        var all: [String] {
            lock.withLock { directories }
        }

        func note(_ directory: String) {
            lock.withLock { directories.append(directory) }
        }
    }
}
