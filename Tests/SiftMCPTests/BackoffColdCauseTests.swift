//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// Whether an overrun arms the short cold-start back-off turns on what ran out of time, not only on the repository: only an overrun while the index is being built is the first build's one-off cost.
@Suite(.temporaryDirectories)
struct BackoffColdCauseTests {
    /// A deadline already past whenever it is asked, so every answer that reaches the wait overruns.
    private static let alreadyPast = InPlaceDeadline { _ in .now() }

    /// How answering `call` in the never-indexed repository `root` ended, and the back-off window its overrun armed in seconds.
    private static func armedWindow(for call: InPlaceCall, in root: URL) async throws -> (outcome: InPlaceAnswerer.Outcome, window: Int?) {
        let backoff = try InPlaceBackoff(directory: TemporaryDirectory.make("backoff").appendingPathComponent("backoff"))
        let overrun = InPlaceOverrun()
        let outcome = await InPlaceAnswerTests.onItsOwnThread {
            InPlaceOverrun.$current.withValue(overrun) {
                InPlaceAnswerer.answer(call, from: root.path, timeBudget: InPlaceAnswerTests.roomy, deadline: alreadyPast, backoff: backoff)
            }
        }
        return (outcome, overrun.suppressionFields["backoff"] as? Int)
    }

    private static func coldRepository() throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try "struct Depot {\n    func stock() -> Int {\n        1\n    }\n}\n"
            .write(to: root.appendingPathComponent("Sources/App/Depot.swift"), atomically: true, encoding: .utf8)
        try "# Plan\n\n## Steps\n".write(to: root.appendingPathComponent("Plan.md"), atomically: true, encoding: .utf8)
        return root
    }

    /// A document's outline reads no index, so an outline that ran out of time in a never-indexed repository was not the first build.
    @Test
    func anOutlineOverrunArmsTheFullWindowEvenWhereNoIndexWasBuilt() async throws {
        let root = try Self.coldRepository()
        let wasCold = !ReadOnlyIndex.hasUsableIndex(atRoot: root.path)
        let result = try await Self.armedWindow(for: .documentOutline(path: "Plan.md"), in: root)

        #expect(wasCold)
        #expect(result.outcome == .withheld(.overTime))
        #expect(result.window == Int(InPlaceBackoff.window))
    }

    /// A sweep that is still running its own search when time runs out has not reached the index, so it is not the first build either.
    @Test
    func aSweepOverrunInItsOwnSearchArmsTheFullWindowEvenWhereNoIndexWasBuilt() async throws {
        let root = try Self.coldRepository()
        let match = try #require(InPlaceShape.match(forShell: "grep -rnw Depot Sources", in: root.path))
        guard case .references = match.call else {
            Issue.record("expected a sweep, got \(match.call)")
            return
        }
        let wasCold = !ReadOnlyIndex.hasUsableIndex(atRoot: root.path)
        let result = try await Self.armedWindow(for: match.call, in: root)

        #expect(wasCold)
        #expect(result.outcome == .withheld(.overTime))
        #expect(result.window == Int(InPlaceBackoff.window))
    }

    /// An overrun of a digest, which goes straight to the index, is still the first build's.
    @Test
    func aDigestOverrunStillArmsTheShortWindow() async throws {
        let root = try Self.coldRepository()
        let wasCold = !ReadOnlyIndex.hasUsableIndex(atRoot: root.path)
        let result = try await Self.armedWindow(for: .fileDigest(path: "Sources/App/Depot.swift"), in: root)

        #expect(wasCold)
        #expect(result.outcome == .withheld(.overTime))
        #expect(result.window == Int(InPlaceBackoff.coldStartWindow))
    }
}
