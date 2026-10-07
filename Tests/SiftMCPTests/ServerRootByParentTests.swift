//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// `sift pre-tool-use`, driven through the built binary, finding the server that answers its caller by its own ancestry: the live server whose recorded parent is the hook's closest ancestor, whatever session that server's line names.
///
/// The test process plays the harness: it spawns the hook, and a long-lived child of its own plays the server, so the server's recorded parent is the hook's parent exactly as `claude` is both. Every log is a scratch file the child reads through `SIFT_SERVER_LOG`, so nothing depends on the servers running on the machine.
@Suite(.temporaryDirectories)
struct ServerRootByParentTests {
    /// After a cleared conversation the payload carries a new session while the server's line keeps the old one, and the server is still found through the parent the hook shares with it.
    @Test
    func aClearedConversationIsStillComparedWithItsServer() throws {
        let repo = try MCPTestRepo.make()
        let server = try SiblingServer()
        defer { server.stop() }
        let log = try Self.log([server.start(session: "before-clear", root: repo.path, parent: getpid())])

        let run = try ServerRootFromLogTests.run(
            payload: ServerRootFromLogTests.payload(cwd: repo.appendingPathComponent("Sources/App").path, session: "after-clear"),
            serverLog: log
        )

        #expect(run.status == 0)
        #expect(run.printed.isEmpty, "printed \(run.printed)")
    }

    /// A live server under the payload's own session whose recorded parent is no ancestor of the hook was started by some other process, as a server started from a shell is, and is not the one answering.
    @Test
    func aServerSpawnedOutsideTheHooksAncestryIsNoEvidence() throws {
        let repo = try MCPTestRepo.make()
        let server = try SiblingServer()
        defer { server.stop() }
        let shell = try Self.exitedPid()
        let log = try Self.log([server.start(session: "this-session", root: repo.path, parent: shell)])

        let run = try ServerRootFromLogTests.run(payload: ServerRootFromLogTests.payload(cwd: repo.path, session: "this-session"), serverLog: log)

        try ServerRootFromLogTests.expectPinned(run, to: repo.path)
    }

    /// Where the hook's ancestor has a server of its own in another tree, that server decides, and a newer server under the payload's session started from elsewhere is passed over.
    @Test
    func theAncestorsServerDecidesOverOneUnderTheSession() throws {
        let repo = try MCPTestRepo.make()
        let other = try MCPTestRepo.make(declaring: "Beta")
        let server = try SiblingServer()
        defer { server.stop() }
        let stray = try SiblingServer()
        defer { stray.stop() }
        let log = try Self.log([
            server.start(session: "before-clear", root: other.path, parent: getpid()),
            stray.start(session: "this-session", root: repo.path, parent: Self.exitedPid()),
        ])

        let run = try ServerRootFromLogTests.run(payload: ServerRootFromLogTests.payload(cwd: repo.path, session: "this-session"), serverLog: log)

        try ServerRootFromLogTests.expectPinned(run, to: repo.path)
    }

    /// The closest ancestor with a live server decides, even where a farther ancestor's server is the newer line.
    @Test
    func theClosestAncestorsServerDecides() throws {
        let repo = try MCPTestRepo.make()
        let other = try MCPTestRepo.make(declaring: "Beta")
        let server = try SiblingServer()
        defer { server.stop() }
        let farther = ServerStart(pid: getpid(), parent: getppid(), session: "outer", root: other.path, launched: ServerLifecycleReport.startTime(of: getpid()) ?? Date())
        let log = try Self.log([server.start(session: "inner", root: repo.path, parent: getpid()), farther])

        let run = try ServerRootFromLogTests.run(payload: ServerRootFromLogTests.payload(cwd: repo.path, session: "inner"), serverLog: log)

        #expect(run.status == 0)
        #expect(run.printed.isEmpty, "printed \(run.printed)")
    }

    /// A subagent's hook runs under the same harness as its parent's and shares the parent's server, so that server's tree decides for it too.
    @Test
    func aSubagentIsComparedWithTheSharedServer() throws {
        let repo = try MCPTestRepo.make()
        let server = try SiblingServer()
        defer { server.stop() }
        let log = try Self.log([server.start(session: "parent-session", root: repo.path, parent: getpid())])
        var payload = ServerRootFromLogTests.payload(cwd: repo.path, session: "parent-session")
        payload["agent_id"] = "subagent-1"

        let run = try ServerRootFromLogTests.run(payload: payload, serverLog: log)

        #expect(run.status == 0)
        #expect(run.printed.isEmpty, "printed \(run.printed)")
    }

    /// A server spawned by the hook's parent that has since exited answers nothing, so the call is pinned.
    @Test
    func anAncestorsServerThatHasExitedIsNoEvidence() throws {
        let repo = try MCPTestRepo.make()
        let server = try SiblingServer()
        let start = server.start(session: "this-session", root: repo.path, parent: getpid())
        server.stop()
        let log = try Self.log([start])

        let run = try ServerRootFromLogTests.run(payload: ServerRootFromLogTests.payload(cwd: repo.path, session: "this-session"), serverLog: log)

        try ServerRootFromLogTests.expectPinned(run, to: repo.path)
    }

    /// A scratch lifecycle log holding a start line for each of `starts`, oldest first.
    static func log(_ starts: [ServerStart], sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        let directory = try TemporaryDirectory.make("server-parent-log", sourceLocation: sourceLocation)
        let file = directory.appendingPathComponent("server.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let log = ServerLifecycleLog(fileURL: file)
        for start in starts {
            log.recordStart(pid: start.pid, session: start.session, root: start.root, parent: start.parent, now: start.launched)
        }
        return file
    }

    /// The pid of a process run to its end and reaped, which is no ancestor of anything now.
    static func exitedPid() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }
}

extension ServerRootByParentTests {
    /// One start line for a scratch lifecycle log.
    struct ServerStart {
        let pid: Int32
        let parent: Int32
        let session: String
        let root: String
        let launched: Date
    }

    /// A child of this test process standing in for a server the harness spawned: alive until its input closes.
    final class SiblingServer {
        private let process = Process()
        private let input = Pipe()

        init() throws {
            process.executableURL = URL(fileURLWithPath: "/bin/cat")
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }

        /// The start line this server would have written, naming `parent` as the process that spawned it.
        func start(session: String, root: String, parent: Int32) -> ServerStart {
            let pid = process.processIdentifier
            return ServerStart(pid: pid, parent: parent, session: session, root: root, launched: ServerLifecycleReport.startTime(of: pid) ?? Date())
        }

        /// Ends the server and reaps it.
        func stop() {
            guard process.isRunning else { return }
            input.fileHandleForWriting.closeFile()
            process.waitUntilExit()
        }
    }
}
