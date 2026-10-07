//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import Testing

/// The context a compound line is handed names the kind of file it read, so a Markdown document is never called Swift's.
@Suite(.temporaryDirectories)
struct BatchedMarkdownReadNoteTests {
    /// A document read beside a Swift file on a line let run whole is not "the Swift read": the line reads both kinds, so the note says "the read".
    @Test
    func aLineReadingAMarkdownDocumentIsNotCalledTheSwiftRead() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository(padding: InPlaceAnswerTests.pastTheFloor)
        let sections = (1 ... 40).map { "# Heading \($0)\n\n" + String(repeating: "Body text of the section.\n", count: 6) }
        try sections.joined(separator: "\n").write(to: root.appendingPathComponent("NOTES.md"), atomically: true, encoding: .utf8)

        let decided = try await BatchedReadNoteTests.decide("cat Sources/App/Depot.swift; cat NOTES.md; ls", in: root)
        let note = try #require(BatchedReadNoteTests.specific(decided.json)?["additionalContext"] as? String, "\(decided)")

        #expect(note.hasPrefix("sift: the read on this line is answered by "), "\(note)")
        #expect(note.hasSuffix("put that on the line in place of the read."), "\(note)")
        #expect(!note.contains("Swift"), "\(note)")
    }
}
