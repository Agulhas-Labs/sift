//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the record one image of a server hands the next, and who may take it up.
struct ServerHandoverTests {
    private static let sample = ServerHandover(
        pid: 4321,
        startedAt: Date(timeIntervalSince1970: 1_788_000_000),
        parent: 1234,
        session: ServerHandover.Session(protocolVersion: "2025-06-18", unread: Data("{\"id\":7}\n{\"id\":8".utf8))
    )

    /// Everything written is read back as it was — the unanswered input byte for byte, which is the part a client would notice losing.
    @Test
    func aHandoverReadsBackAsItWasWritten() throws {
        let value = try Self.sample.encoded()

        #expect(ServerHandover.decode(value, for: 4321) == Self.sample)
    }

    /// A handover names the process that wrote it, and no other process can take it up — a copy of the variable anything else inherited is not addressed to it.
    @Test
    func anotherProcessCannotTakeAHandoverUp() throws {
        let value = try Self.sample.encoded()

        #expect(ServerHandover.decode(value, for: 4322) == nil)
    }

    /// A layout this build does not read is refused rather than half-read.
    @Test
    func aHandoverInAnotherLayoutIsRefused() throws {
        var object = try #require(JSONSerialization.jsonObject(with: Data(Self.sample.encoded().utf8)) as? [String: Any])
        object["format"] = ServerHandover.format + 1
        let value = try #require(try String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))

        #expect(ServerHandover.decode(value, for: 4321) == nil)
        #expect(ServerHandover.decode("not a handover", for: 4321) == nil)
    }

    /// A process that was handed a session takes it out of its environment, so nothing it spawns inherits it.
    @Test
    func takingAHandoverRemovesItFromTheEnvironment() throws {
        let removed = Removed()
        let environment = try [ServerHandover.environmentKey: Self.sample.encoded()]

        let taken = ServerHandover.take(from: environment, pid: 4321, removing: { removed.add($0) }, note: { _ in })

        #expect(taken == Self.sample)
        #expect(removed.names == [ServerHandover.environmentKey])
    }

    /// One that is not this process's is removed all the same, said out loud, and otherwise ignored: the process starts as a fresh server.
    @Test
    func aHandoverThisProcessCannotUseIsRemovedAndIgnored() throws {
        let removed = Removed()
        let notes = Removed()
        let environment = try [ServerHandover.environmentKey: Self.sample.encoded()]

        let taken = ServerHandover.take(from: environment, pid: 99, removing: { removed.add($0) }, note: { notes.add($0) })

        #expect(taken == nil)
        #expect(removed.names == [ServerHandover.environmentKey])
        #expect(notes.names.count == 1)
    }

    /// Asked to read a handover back, a build prints what it read — whichever process the handover names, since the one asking is the server and the one answering a child it started.
    ///
    /// What the image about to hand over compares, field for field, with what it wrote (``ServerReexec``).
    @Test
    func aHandoverIsReadBackAsThisBuildReadsIt() throws {
        let environment = try [ServerHandover.environmentKey: Self.sample.encoded()]

        let printed = try #require(ServerHandover.readBack(from: environment))

        #expect(ServerHandover.decode(printed, for: 4321) == Self.sample)
    }

    /// Nothing is printed where there is no handover, or none in the layout this build reads — so the question fails, rather than answering with something that could be mistaken for a reading.
    @Test
    func nothingIsReadBackWhereThereIsNoHandoverThisBuildReads() throws {
        var object = try #require(JSONSerialization.jsonObject(with: Data(Self.sample.encoded().utf8)) as? [String: Any])
        object["format"] = ServerHandover.format + 1
        let otherLayout = try #require(try String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))

        #expect(ServerHandover.readBack(from: [:]) == nil)
        #expect(ServerHandover.readBack(from: [ServerHandover.environmentKey: otherLayout]) == nil)
        #expect(ServerHandover.readBack(from: [ServerHandover.environmentKey: "not a handover"]) == nil)
    }

    /// A process started the ordinary way has nothing to take and removes nothing.
    @Test
    func aFreshStartHasNoHandover() {
        let removed = Removed()

        #expect(ServerHandover.take(from: [:], pid: 4321, removing: { removed.add($0) }, note: { _ in }) == nil)
        #expect(removed.names.isEmpty)
    }
}

private extension ServerHandoverTests {
    /// Collects what a closure under test was handed.
    final class Removed: @unchecked Sendable {
        private let mutex = NSLock()
        private var collected: [String] = []

        var names: [String] {
            mutex.lock()
            defer { mutex.unlock() }
            return collected
        }

        func add(_ name: String) {
            mutex.lock()
            defer { mutex.unlock() }
            collected.append(name)
        }
    }
}
