//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the server's half of taking a replaced binary over in place: when it hands the session on, exactly what it hands, and what it does when it cannot.
///
/// In-process, with the exec standing in as a recorder. What an exec does to a process is pinned by ``ServerReexecTests``, which runs real ones; what is pinned here is the handover itself, which nothing on the far side of a real exec could show a test byte for byte.
@Suite(.temporaryDirectories)
struct MCPServerHandoverTests {
    /// A server started from a handover answers the request it was handed before reading anything, and without being asked to initialise again.
    @Test
    func aResumedServerAnswersWhatItWasHandedWithoutAHandshake() async throws {
        let call = try Self.line(["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "digest", "arguments": ["target": "Alpha"]]])
        let session = try Session.start(resuming: ServerHandover.Session(protocolVersion: "2025-06-18", unread: call))

        let answer = try await session.next()

        #expect(answer["id"] as? Int == 7)
        #expect(Self.text(of: answer).contains("struct Alpha"))
        // And it carries on from its own input, still with no `initialize` ever sent.
        try session.send(Self.line(["jsonrpc": "2.0", "id": 8, "method": "ping"]))
        #expect(try await session.next()["id"] as? Int == 8)
        #expect(await session.close() == .inputClosed)
    }

    /// The request just read, and everything that arrived after it, go to the new binary unanswered — with the protocol version the client agreed to and what the lifecycle log needs.
    ///
    /// Two requests in one write, so the read that takes the first holds the second: the case where handing on only the request in hand would lose a request the client has already sent.
    @Test
    func aReplacedBinaryIsHandedTheRequestJustReadAndEverythingAfterIt() async throws {
        let session = try Session.start(replaceable: true, answering: .readsBack)
        try await session.initialise()
        try session.replaceBinary()
        let call = try Self.line(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "digest", "arguments": ["target": "Alpha"]]])
        let ping = try Self.line(["jsonrpc": "2.0", "id": 3, "method": "ping"])

        session.toServer.fileHandleForWriting.write(call + ping)
        let answer = try await session.next()
        let pong = try await session.next()

        let handedOver = try #require(session.standIns.execEnvironments.first?[ServerHandover.environmentKey])
        let handover = try #require(ServerHandover.decode(handedOver, for: getpid()))
        #expect(handover.session.unread == call + ping, "the handover is missing input the old image had already read")
        #expect(handover.session.protocolVersion == "2025-06-18")
        #expect(handover.parent == 1234)
        #expect(handover.startedAt == Session.startedAt)
        // The new binary is asked about the very handover the exec then carries, not a stand-in for it.
        #expect(session.standIns.askedEnvironments.first?[ServerHandover.environmentKey] == handedOver)
        // The stand-in exec failed, so this image answered after all — from the old code, and saying so.
        #expect(answer["id"] as? Int == 2)
        #expect(Self.text(of: answer).contains("replaced on disk"))
        #expect(pong["id"] as? Int == 3)
        #expect(session.ledger.stops.isEmpty, "a failed exec recorded a stop for a server that went on serving")
        await session.close()
    }

    /// A replacement that refused is asked once: not again on every request, and again as soon as the file changes again.
    ///
    /// Its answer was about the file, and the same file would give it again.
    @Test
    func aReplacementThatRefusedIsAskedOncePerBinary() async throws {
        let session = try Session.start(replaceable: true, answering: .refuses)
        try await session.initialise()
        try session.replaceBinary()

        try await session.call(id: 2)
        try await session.call(id: 3)
        #expect(session.standIns.askedCount == 1)
        #expect(session.standIns.log.first?.hasSuffix("not tried again until the file changes") == true)

        try session.replaceBinary()
        try await session.call(id: 4)
        #expect(session.standIns.askedCount == 2)
        await session.close()
    }

    /// A failure that says nothing about the file — an answer that never came, an exec that failed — is not taken as a refusal, and is not tried again on the very next request either.
    ///
    /// Marked as a verdict on the file, one slow moment would leave the session on the old code for good; tried on every request, a probe that keeps timing out would hold every request up. When it is tried again is ``ServerReexec/Attempts``, pinned in ``ServerReexecAttemptsTests``; what is pinned here is that the server consults it with the right kind of failure.
    @Test
    func aFailureThatSaysNothingAboutTheFileWaitsToBeTriedAgain() async throws {
        for answer in [StandIns.Answering.unanswered, .readsBack] {
            let session = try Session.start(replaceable: true, answering: answer)
            try await session.initialise()
            try session.replaceBinary()

            try await session.call(id: 2)
            try await session.call(id: 3)

            #expect(session.standIns.askedCount == 1, "tried again at once after \(answer)")
            #expect(session.standIns.log.first?.hasSuffix("tried again in 30 seconds at the earliest") == true, "\(answer) was not taken as a failure worth trying again")
            await session.close()
        }
    }

    /// A request larger than an exec can carry is answered by the old code — and the next, ordinary request takes the replacement over.
    ///
    /// The size says nothing about the file, so nothing is asked of it and nothing is held against it: before this, the one large request right after an upgrade left the whole session on the old code.
    @Test
    func aRequestTooLargeToHandOverLeavesTheNextOneToTakeOver() async throws {
        let session = try Session.start(replaceable: true, answering: .readsBack)
        try await session.initialise()
        try session.replaceBinary()

        let large = try await session.call(id: 2, arguments: ["target": "Alpha", "padding": String(repeating: "p", count: sysconf(_SC_ARG_MAX))])

        #expect(Self.text(of: large).contains("struct Alpha"))
        #expect(Self.text(of: large).contains("replaced on disk"))
        #expect(session.standIns.askedCount == 0, "the new binary was asked about a handover no exec could carry")
        #expect(session.standIns.log.first?.hasSuffix("tried again on the next request") == true)
        try await session.call(id: 3)
        #expect(session.standIns.askedCount == 1)
        #expect(session.standIns.execEnvironments.count == 1, "the ordinary request after a large one did not take the replacement over")
        await session.close()
    }

    /// A binary that cannot read this handover back as it was written is never exec'd into — it would drop the request it was handed — and the answer carries the notice instead.
    ///
    /// Among them the one only a read-back can catch: a build that decodes this layout under the same number and gets it wrong.
    @Test
    func aBinaryThatCannotReadTheHandoverBackIsNeverExecd() async throws {
        for answer in [StandIns.Answering.refuses, .readsDifferently, .unanswered] {
            let session = try Session.start(replaceable: true, answering: answer)
            try await session.initialise()
            try session.replaceBinary()

            let reply = try await session.call(id: 2)

            #expect(session.standIns.askedCount == 1)
            #expect(session.standIns.execEnvironments.isEmpty, "exec'd into a binary that answered \(answer)")
            #expect(Self.text(of: reply).contains("replaced on disk"))
            await session.close()
        }
    }

    private static func line(_ payload: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        return data
    }

    private static func text(of response: [String: Any]) -> String {
        let result = response["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        return content?.first?["text"] as? String ?? ""
    }
}

private extension MCPServerHandoverTests.StandIns {
    /// How the stand-in binary answers when asked to read the handover back.
    enum Answering: Sendable {
        /// Prints the handover exactly as it was handed — a build that reads it.
        case readsBack
        /// Prints a handover that differs from the one it was handed — a build that decodes this layout wrongly.
        case readsDifferently
        /// Exits with a failure — a build that does not know the question.
        case refuses
        /// Never answers in time.
        case unanswered
    }
}

private extension MCPServerHandoverTests {
    /// The stand-ins for asking the new binary and for the exec, and everything each was handed: the question is answered as the test says, and every exec fails, so the server carries on.
    final class StandIns: @unchecked Sendable {
        private let answering: Answering
        private let mutex = NSLock()
        private var asked: [[String: String]] = []
        private var execs: [[String: String]] = []
        private var logged: [String] = []

        init(answering: Answering) {
            self.answering = answering
        }

        var askedEnvironments: [[String: String]] {
            mutex.lock()
            defer { mutex.unlock() }
            return asked
        }

        var askedCount: Int {
            askedEnvironments.count
        }

        var execEnvironments: [[String: String]] {
            mutex.lock()
            defer { mutex.unlock() }
            return execs
        }

        /// What the server logged, which says what it made of each failure.
        var log: [String] {
            mutex.lock()
            defer { mutex.unlock() }
            return logged
        }

        func ask(_ environment: [String: String]) -> ServerReexec.Answer {
            mutex.lock()
            asked.append(environment)
            mutex.unlock()
            let handedOver = environment[ServerHandover.environmentKey] ?? ""
            switch answering {
            case .readsBack:
                return .printed(handedOver)
            case .readsDifferently:
                guard let handover = ServerHandover.decode(handedOver) else { return .printed("") }
                let misread = ServerHandover(pid: handover.pid, startedAt: handover.startedAt, parent: handover.parent, session: ServerHandover.Session(protocolVersion: handover.session.protocolVersion, unread: Data()))
                return .printed((try? misread.encoded()) ?? "")
            case .refuses:
                return .refused("the stand-in exited 64")
            case .unanswered:
                return .unanswered("the stand-in did not answer")
            }
        }

        func execute(_ environment: [String: String]) -> Int32 {
            mutex.lock()
            defer { mutex.unlock() }
            execs.append(environment)
            return ENOEXEC
        }

        func record(_ line: String) {
            mutex.lock()
            defer { mutex.unlock() }
            logged.append(line)
        }
    }

    /// One in-process server over a pipe pair.
    ///
    /// Where it is replaceable, its binary is a file this test can swap, and asking it and exec'ing it are ``StandIns``.
    struct Session {
        static let startedAt = Date(timeIntervalSince1970: 1_788_000_000)

        let toServer: Pipe
        let fromServer: Pipe
        let binary: URL?
        let standIns: StandIns
        let ledger: ServerEndingTests.Ledger
        let task: Task<ServerStop, Never>
        let responses: ServerResponses

        static func start(
            resuming handedOver: ServerHandover.Session? = nil,
            replaceable: Bool = false,
            answering: StandIns.Answering = .refuses
        ) throws -> Session {
            let root = try MCPTestRepo.make()
            let toServer = Pipe()
            let fromServer = Pipe()
            let binary: URL? = replaceable ? try fakeBinary() : nil
            let standIns = StandIns(answering: answering)
            let ledger = ServerEndingTests.Ledger()
            let ending = ServerEnding(record: { ledger.record($0) }, leave: { ledger.leave($0) })
            let reexec = binary.map { binary in
                ServerReexec(
                    path: binary.path,
                    arguments: ["sift", "mcp"],
                    startedAt: startedAt,
                    parent: 1234,
                    ending: ending,
                    ask: { _, _, environment in standIns.ask(environment) },
                    execute: { _, _, environment in standIns.execute(environment) }
                )
            }
            let server = MCPServer(
                input: toServer.fileHandleForReading,
                output: fromServer.fileHandleForWriting,
                defaultRoot: root,
                log: { standIns.record($0) },
                binaryPath: binary?.path ?? BinaryIdentity.executablePath,
                resuming: handedOver,
                reexec: reexec
            )
            return Session(
                toServer: toServer,
                fromServer: fromServer,
                binary: binary,
                standIns: standIns,
                ledger: ledger,
                task: Task { await server.run() },
                responses: ServerResponses(fromServer.fileHandleForReading)
            )
        }

        /// A file standing in for the executable: only its identity on disk is ever read.
        private static func fakeBinary() throws -> URL {
            let url = try TemporaryDirectory.make("handover-binary").appendingPathComponent("handover-binary")
            try Data("old code".utf8).write(to: url)
            return url
        }

        /// The upgrade shape: `rm`, then a new file at the same path.
        func replaceBinary(sourceLocation: SourceLocation = #_sourceLocation) throws {
            let binary = try #require(binary, sourceLocation: sourceLocation)
            try FileManager.default.removeItem(at: binary)
            try Data("new code \(UUID().uuidString)".utf8).write(to: binary)
        }

        func send(_ line: Data) throws {
            toServer.fileHandleForWriting.write(line)
        }

        func next(sourceLocation: SourceLocation = #_sourceLocation) async throws -> [String: Any] {
            let line = try #require(await responses.next(within: 30), "no answer within 30 seconds", sourceLocation: sourceLocation)
            return try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], sourceLocation: sourceLocation)
        }

        func initialise() async throws {
            try send(MCPServerHandoverTests.line([
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "test", "version": "0"]],
            ]))
            _ = try await next()
        }

        @discardableResult
        func call(
            id: Int,
            arguments: [String: Any] = ["target": "Alpha"],
            sourceLocation: SourceLocation = #_sourceLocation
        ) async throws -> [String: Any] {
            try send(MCPServerHandoverTests.line([
                "jsonrpc": "2.0", "id": id, "method": "tools/call",
                "params": ["name": "digest", "arguments": arguments],
            ]))
            let answer = try await next(sourceLocation: sourceLocation)
            #expect(answer["id"] as? Int == id, sourceLocation: sourceLocation)
            return answer
        }

        /// Closes the server's input and waits, with a deadline, for it to stop: a server that does not stop fails the test here rather than hanging the suite.
        @discardableResult
        func close(sourceLocation: SourceLocation = #_sourceLocation) async -> ServerStop? {
            toServer.fileHandleForWriting.closeFile()
            let task = task
            let stop = await Deadline.within(seconds: 30) { await task.value }
            #expect(stop != nil, "the server did not stop within 30 seconds of its input closing", sourceLocation: sourceLocation)
            return stop
        }
    }
}
