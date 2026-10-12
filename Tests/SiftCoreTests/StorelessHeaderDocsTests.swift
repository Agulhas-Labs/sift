//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `digest` carries no `semantic:` field and `where` says why it has no store, and both places a reader looks the header up explain it, quoting `where`'s reading in the words the header renders.
struct StorelessHeaderDocsTests {
    /// The sentences both documents carry, built from the renderings so a change to either has to reach them.
    private static var sentences: [String] {
        [
            "`digest` never opens the store, so its header carries no `semantic:` field;",
            "In a tree with no index store yet, `where` says `\(SemanticAxis.noStore(inWorktree: false).rendered)`, and in a fresh worktree `\(SemanticAxis.noStore(inWorktree: true).rendered)`: it asked and found none.",
        ]
    }

    /// Whitespace folded, so a sentence reads the same wherever the wrap fell.
    private static func folded(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The Guide's paragraph on what `semantic:` means names both readings.
    @Test
    func theGuideExplainsTheStorelessPair() throws {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent() // SiftCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent()
        let guide = try String(contentsOf: root.appendingPathComponent("Docs/Guide.md"), encoding: .utf8)

        for sentence in Self.sentences {
            #expect(Self.folded(guide).contains(sentence))
        }
    }

    /// `sift help answers` names the same readings.
    @Test
    func theAnswersTopicExplainsTheStorelessPair() throws {
        let answers = try #require(HelpTopics.topic(named: "answers")).body

        for sentence in Self.sentences {
            #expect(Self.folded(answers).contains(sentence))
        }
    }
}
