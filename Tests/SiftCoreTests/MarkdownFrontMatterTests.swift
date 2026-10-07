//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// A front-matter block is YAML, where `#` begins a comment, so the outline never reads a heading out of it.
struct MarkdownFrontMatterTests {
    private static func titles(_ document: String) -> [String] {
        MarkdownOutline.sections(of: SourcePassthrough.lines(of: document)).map(\.title)
    }

    @Test
    func aCommentInFrontMatterIsNoHeading() {
        #expect(Self.titles("---\ntitle: Guide\n# a comment\n---\n\n# Real\n") == ["Real"])
    }

    @Test
    func aDotsLineClosesFrontMatterToo() {
        #expect(Self.titles("---\n# a comment\n...\n# Real\n") == ["Real"])
    }

    @Test
    func aCrlfDocumentsFrontMatterIsSkipped() {
        #expect(Self.titles("---\r\n# a comment\r\n---\r\n# Real\r\n") == ["Real"])
    }

    @Test
    func aDocumentWithoutFrontMatterIsUnchanged() {
        #expect(Self.titles("# One\n\n## Two\n") == ["One", "Two"])
    }

    @Test
    func aLaterRuleDoesNotStartFrontMatter() {
        #expect(Self.titles("# One\n\n---\n# Two\n---\n# Three\n") == ["One", "Two", "Three"])
    }

    @Test
    func aRuleOnLineOneThatIsNeverClosedIsNotFrontMatter() {
        #expect(Self.titles("---\n# One\n") == ["One"])
    }

    @Test
    func aBulletInFrontMatterIsNotAnItem() {
        let lines = SourcePassthrough.lines(of: "---\n# c\n- tag\n---\n# Real\n- item\n")

        #expect(MarkdownOutline.bullets(of: lines).map(\.title) == ["item"])
    }
}
