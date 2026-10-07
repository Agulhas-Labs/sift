//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// Engines kept open per root across the answers of one replay: opened once a root, and never answering from a head or a tree the root has moved on from.
@Suite(.temporaryDirectories) struct EngineReuseTests {
    /// Answers under a bound reuse open one engine for a root, however many of them it answers.
    @Test
    func answersOfOneRootUnderABoundReuseOpenOneEngine() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let reuse = EngineReuse()

        let first = try await Self.answer(.fileDigest(path: "Sources/App/Depot.swift"), from: root.path, reusing: reuse)
        let second = try await Self.answer(.fileDigest(path: "Sources/App/Depot.swift"), from: root.path, reusing: reuse)

        #expect(first?.reason.contains("struct Depot — 40 members") == true, "\(String(describing: first))")
        #expect(second?.reason == first?.reason)
        #expect(reuse.opened == 1)
    }

    /// An engine kept across answers answers from the head the root moved to since, with the member the new commit added.
    @Test
    func aKeptEngineAnswersFromTheHeadTheRootMovedTo() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let reuse = EngineReuse()
        let first = try #require(try await Self.answer(.fileDigest(path: "Sources/App/Depot.swift"), from: root.path, reusing: reuse))

        let members = (1 ... 40).map { index in
            "    func restock\(index)() -> Int {\n        let count = \(index)\n        let tripled = count * 3\n        return tripled + count\n    }"
        }
        try MCPTestRepo.add(["Sources/App/Depot.swift": "/// A depot.\nstruct Depot {\n" + members.joined(separator: "\n") + "\n}\n"], to: root)
        let second = try #require(try await Self.answer(.fileDigest(path: "Sources/App/Depot.swift"), from: root.path, reusing: reuse))

        #expect(reuse.opened == 1, "the one engine answered both")
        #expect(second.reason.contains("func restock1()"), "\(second.reason)")
        #expect(!second.reason.contains("func stock1()"), "\(second.reason)")
        let firstHead = try #require(Self.head(in: first.reason))
        let secondHead = try #require(Self.head(in: second.reason))
        #expect(firstHead != secondHead, "the header names the head the commit moved to")
    }

    /// Two roots under one reuse are each answered by an engine of their own, never one root's engine for the other's files.
    @Test
    func eachRootIsAnsweredByItsOwnEngine() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let other = try await InPlaceAnswerTests.indexedRepository()
        let reuse = EngineReuse()

        let first = try #require(try await Self.answer(.fileDigest(path: "Sources/App/Depot.swift"), from: root.path, reusing: reuse))
        let second = try #require(try await Self.answer(.fileDigest(path: "Sources/App/Depot.swift"), from: other.path, reusing: reuse))
        let again = try #require(try await Self.answer(.fileDigest(path: "Sources/App/Depot.swift"), from: other.path, reusing: reuse))

        #expect(CanonicalPath.of(first.root) == CanonicalPath.of(root.path))
        #expect(CanonicalPath.of(second.root) == CanonicalPath.of(other.path))
        #expect(CanonicalPath.of(again.root) == CanonicalPath.of(other.path))
        #expect(reuse.opened == 2)
    }

    /// An engine still out with one answer is never handed to a second: that one opens its own, and both come back for later answers.
    @Test
    func anEngineStillOutIsNotHandedToASecondAnswer() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let reuse = EngineReuse()

        let held = try reuse.checkOut(root: root.path)
        let second = try reuse.checkOut(root: root.path)
        #expect(held !== second)
        reuse.checkIn(second, root: root.path)
        reuse.checkIn(held, root: root.path)
        let third = try reuse.checkOut(root: root.path)
        let fourth = try reuse.checkOut(root: root.path)

        #expect(reuse.opened == 2)
        #expect(third === held, "the one handed back last is handed out first")
        #expect(fourth === second)
    }

    /// An engine whose database went while it was kept is never handed out again, and past its capacity the reuse closes the engine used longest ago.
    @Test
    func aKeptEngineWhoseStoreWentIsReplacedAndTheOldestIsClosedPastCapacity() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let linked = try await InPlaceAnswerTests.indexedRepository()
        let reuse = EngineReuse(capacity: 1)

        let gone = try reuse.checkOut(root: root.path)
        reuse.checkIn(gone, root: root.path)
        try FileManager.default.removeItem(at: SiftPaths.cache(in: gone.repoRoot))
        let reopened = try reuse.checkOut(root: root.path)
        #expect(reopened !== gone)
        reuse.checkIn(reopened, root: root.path)

        let other = try reuse.checkOut(root: linked.path)
        reuse.checkIn(other, root: linked.path)
        let evicted = try reuse.checkOut(root: root.path)

        #expect(evicted !== reopened, "the root's engine was closed to keep the other root's")
        #expect(reuse.opened == 4)
    }

    /// Two answers through one kept engine both read an index store still warming, as two newly opened engines do: the open the first answer gave up on is never found finished by the second.
    ///
    /// A zero budget holds each open in its warming state, and the second answer is asked only once the first open has landed, so a kept engine that still held that open would answer from it.
    @Test
    func aKeptEngineOpensTheIndexStoreAfreshForEachAnswer() async throws {
        let root = try await Self.builtPackage()
        let landed = OpenLanded()
        let reuse = EngineReuse { root in
            let engine = try SiftEngine(directory: URL(fileURLWithPath: root), registry: nil)
            engine.openBudget = 0
            engine.afterSemanticOpen = { landed.mark() }
            return engine
        }
        let call = InPlaceCall.symbols(names: ["Depot"], paths: ["Sources"])

        let first = try #require(try await Self.answer(call, from: root.path, reusing: reuse))
        try await landed.settle()
        let second = try #require(try await Self.answer(call, from: root.path, reusing: reuse))

        #expect(reuse.opened == 1, "the one engine answered both")
        for answered in [first, second] {
            let header = InPlaceAnswer.answer(inReason: answered.reason)?.split(separator: "\n").first.map(String.init)
            #expect(header?.hasSuffix("semantic: warming (index store still loading — ask again shortly)") == true, "\(answered.reason)")
        }
    }

    /// The answer `call` gets from `directory` with `reuse` bound, as a replay binds it, or `nil` and a recorded issue where it is withheld.
    static func answer(_ call: InPlaceCall, from directory: String, reusing reuse: EngineReuse, sourceLocation: SourceLocation = #_sourceLocation) async throws -> InPlaceAnswerer.Answered? {
        let backoff = try InPlaceAnswerTests.backoff()
        let outcome = await InPlaceAnswerTests.onItsOwnThread {
            EngineReuse.$current.withValue(reuse) {
                InPlaceAnswerer.answer(call, from: directory, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff)
            }
        }
        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer, got \(outcome)", sourceLocation: sourceLocation)
            return nil
        }
        return answered
    }

    /// A package built with an index store, declaring a type the rest of it uses, and indexed.
    static func builtPackage() async throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([
            "Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n",
            "Sources/App/Depot.swift": "public struct Depot {\n    public init() {}\n}\n",
            "Sources/App/Uses.swift": "struct Holder {\n    var depot = Depot()\n}\n",
        ], to: root)
        try MCPTestRepo.build(root)
        try await SiftEngine(directory: root).ensureFresh()
        return root
    }

    /// The head an answer's freshness header names, read off the header line.
    static func head(in reason: String) -> String? {
        guard let answer = InPlaceAnswer.answer(inReason: reason), let header = answer.split(separator: "\n").first else { return nil }
        return header.components(separatedBy: "  ").first { $0.hasPrefix("head: ") }
    }
}

private extension EngineReuseTests {
    /// Whether an index-store open has landed, marked from the thread that ran it.
    final class OpenLanded: @unchecked Sendable {
        private let lock = NSLock()
        private var landed = false

        /// Records that an open has landed.
        func mark() {
            lock.withLock { landed = true }
        }

        /// Returns once an open has landed and had a moment to be stored, or throws past a minute.
        ///
        /// The mark is made just before the open hands its store back, so a short wait after it lets the open's own thread record the outcome.
        func settle() async throws {
            let deadline = Date().addingTimeInterval(60)
            while !lock.withLock({ landed }) {
                guard Date() < deadline else { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .milliseconds(500))
        }
    }
}
