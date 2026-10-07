//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// In a tree with no index store, `digest` and `where` head their answers differently, and both places a reader looks the header up explain why, quoting each in the words the header renders.
struct StorelessHeaderDocsTests {
    /// The sentence both documents carry, built from the two renderings so a change to either has to reach them.
    private static var sentence: String {
        "In a tree with no index store yet, such as a fresh worktree, `digest` still says `\(SemanticAxis.syntacticOnly.rendered)` and `where` says `\(SemanticAxis.noStore.rendered)`: `digest` never asked for the store, `where` asked and found none."
    }

    /// Whitespace folded, so a sentence reads the same wherever the wrap fell.
    private static func folded(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The Guide's paragraph on what `semantic:` means names the store-less pair.
    @Test
    func theGuideExplainsTheStorelessPair() throws {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent() // SiftCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent()
        let guide = try String(contentsOf: root.appendingPathComponent("Docs/Guide.md"), encoding: .utf8)

        #expect(Self.folded(guide).contains(Self.sentence))
    }

    /// `sift help answers` names the same pair.
    @Test
    func theAnswersTopicExplainsTheStorelessPair() throws {
        let answers = try #require(HelpTopics.topic(named: "answers")).body

        #expect(Self.folded(answers).contains(Self.sentence))
    }
}
