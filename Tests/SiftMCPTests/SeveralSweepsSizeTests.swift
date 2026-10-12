//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// A line of several sweeps is weighed whole as well as part by part: its refusal, header and closing line included, has to be smaller than what all its greps print together, or the line runs as `notSmaller`.
@Suite(.temporaryDirectories)
struct SeveralSweepsSizeTests {
    /// The directory the uses sit in, deep enough that a grep's line there nearly matches the row the syntactic `where` lists it by.
    static var drawer: String {
        "\(NoStoreSweepTests.shelf)/Drawers/Compartments"
    }

    /// A repository no build has indexed, declaring `Depot` and `Crate` in one file and using each on `uses` lines of a shop under ``drawer``.
    static func unbuiltRepository(uses: Int, sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        let shop = "struct Shop {\n    func stock() {\n"
            + String(repeating: "        _ = Depot()\n", count: uses)
            + String(repeating: "        _ = Crate()\n", count: uses)
            + "    }\n}\n"
        try MCPTestRepo.add([
            "Sources/App/Kinds.swift": "struct Depot {\n    var size = 1\n}\nstruct Crate {\n    var size = 1\n}\n",
            "\(drawer)/Shop.swift": shop,
        ], to: root)
        #expect(!ReadOnlyIndex.hasIndexStore(atRoot: root.path), sourceLocation: sourceLocation)
        return root
    }

    /// What the hook does with the whole of `command`, every lookup on the line together, run from `root`.
    static func lineOutcome(_ command: String, in root: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws -> InPlaceAnswerer.Outcome {
        let match = try #require(InPlaceShape.match(forShell: command, in: root.path), "\(command) is not a candidate", sourceLocation: sourceLocation)
        let backoff = try InPlaceAnswerTests.backoff()
        return await InPlaceAnswerTests.onItsOwnThread { InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, backoff: backoff) }
    }

    /// Two sweeps whose answers each sit just under their own greps, but whose one refusal outweighs both greps once the framing they share is added, let the line run: each alone is no smaller either.
    @Test
    func aLineWhoseWholeRefusalOutweighsItsGrepsIsNotSmaller() async throws {
        let root = try Self.unbuiltRepository(uses: 6)

        #expect(try await Self.lineOutcome("grep -rnw Depot Sources", in: root) == .withheld(.notSmaller))
        #expect(try await Self.lineOutcome("grep -rnw Crate Sources", in: root) == .withheld(.notSmaller))
        #expect(try await Self.lineOutcome("grep -rnw Depot Sources; grep -rnw Crate Sources", in: root) == .withheld(.notSmaller))
    }

    /// Two sweeps whose answers are far smaller than their greps are still answered together.
    @Test
    func aLineFarUnderItsGrepsIsAnswered() async throws {
        let root = try Self.unbuiltRepository(uses: 25)

        let outcome = try await Self.lineOutcome("grep -rnw Depot Sources; grep -rnw Crate Sources", in: root)
        guard case let .answered(answered) = outcome else {
            Issue.record("expected the line answered, got \(outcome)")
            return
        }

        #expect(answered.calls.map(\.target) == ["Depot", "Crate"])
    }
}
