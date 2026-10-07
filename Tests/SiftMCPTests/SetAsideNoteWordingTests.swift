//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// A members answer's note says why the whole digest was set aside as a digest that was not served, so it is never read as the verdict on the answer it opens, which the closing line gives.
@Suite(.temporaryDirectories)
struct SetAsideNoteWordingTests {
    /// The window's members, answered in place of a whole digest no smaller than its lines: the note says what serving that digest would have cost, never that a digest is no smaller, and the closing line states the members answer's own saving.
    @Test
    func theNoteOnADigestSetAsideIsNotTheAnswersVerdict() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        // Long signatures make the digest's first page heavier than the window, and the window's three padded members save the floor with their own.
        let padding = String(repeating: "x", count: 1800)
        let members = (1 ... 100).map { "    func item\($0)(quantity: Int, label: String, owner: String, location: String, reference: Int) -> Int {\n        let count = \($0)\($0 <= 3 ? " // " + padding : "")\n        let doubled = count * 2\n        let tripled = count * 3\n        return doubled + tripled\n    }" }
        try ("/// A crate.\nstruct Crate {\n" + members.joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent("Sources/App/Crate.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        let match = try #require(InPlaceShape.match(forShell: "sed -n 2,20p Sources/App/Crate.swift", in: root.path))
        let backoff = try InPlaceAnswerTests.backoff()

        let outcome = await InPlaceAnswerTests.onItsOwnThread {
            InPlaceAnswerer.answer(match, timeBudget: InPlaceAnswerTests.roomy, sizeBudget: InPlaceAnswer.sizeBudget, backoff: backoff)
        }

        guard case let .answered(answered) = outcome else {
            Issue.record("expected an answer, got \(outcome)")
            return
        }
        let lines = answered.reason.split(separator: "\n")
        let opening = try #require(lines.first)

        #expect(opening.contains("(only the members of lines 2-20 are shown; the whole digest would be no smaller than these lines)"))
        #expect(!opening.contains("is no smaller"))
        #expect(try #require(lines.last).hasSuffix("smaller)."))
    }
}
