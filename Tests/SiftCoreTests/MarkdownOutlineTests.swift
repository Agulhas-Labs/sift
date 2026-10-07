//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers the heading parser directly, on lines alone: the rules a rendered outline can only show one at a time are pinned here, one each, without an index build in front of them.
struct MarkdownOutlineTests {
    private static func sections(_ document: String) -> [MarkdownOutline.Section] {
        MarkdownOutline.sections(of: SourcePassthrough.lines(of: document))
    }

    private static func bullets(_ document: String) -> [MarkdownOutline.Bullet] {
        MarkdownOutline.bullets(of: SourcePassthrough.lines(of: document))
    }

    @Test
    func aCarriageReturnIsNeitherPartOfATitleNorBetweenItAndItsClosingRun() {
        let found = Self.sections("# Guide\r\n\r\n## Scope ##\r\nBody.\r\n")

        #expect(found.map(\.title) == ["Guide", "Scope"])
        #expect(found.map(\.end) == [4, 4])
    }

    @Test
    func aHashWithNoSpaceAfterItIsAParagraph() {
        #expect(Self.sections("#hashtag\n\n# Real\n").map(\.title) == ["Real"])
    }

    @Test
    func aSeventhHashIsNoHeadingAtAll() {
        let found = Self.sections("###### Six\n####### Seven\n")

        #expect(found.map(\.level) == [6])
        #expect(found.map(\.end) == [2])
    }

    @Test
    func aHeadingWithNoTextIsAHeadingWithAnEmptyTitle() {
        #expect(Self.sections("###\n## Named ##\n").map(\.title) == ["", "Named"])
    }

    @Test
    func aFenceIndentedUpToThreeSpacesStillHidesItsHeadings() {
        let hidden = Self.sections("# Top\n   ```\n# hidden\n   ```\n## After\n")
        let fourSpaces = Self.sections("# Top\n    ```\n# shown\n    ```\n")

        #expect(hidden.map(\.title) == ["Top", "After"])
        // Four spaces make an indented code block, not a fence — so its `#` lines are not headings either, and the fence is not one.
        #expect(fourSpaces.map(\.title) == ["Top", "shown"])
    }

    @Test
    func aClosingFenceMustBeAtLeastAsLongAsTheOpeningOne() {
        let found = Self.sections("# Top\n````\n```\n# still hidden\n````\n## After\n")

        #expect(found.map(\.title) == ["Top", "After"])
    }

    @Test
    func aBacktickFenceInsideATildeFenceDoesNotCloseIt() {
        let found = Self.sections("# Top\n~~~\n```\n# hidden\n```\n~~~\n## After\n")

        #expect(found.map(\.title) == ["Top", "After"])
    }

    @Test
    func anEmptyDocumentAndOneWithoutATrailingNewlineBothOutline() {
        #expect(Self.sections("").isEmpty)
        #expect(Self.sections("# Only").map(\.end) == [1])
    }

    @Test
    func levelsMayJumpEitherWayAndASectionEndsAtTheNextOfItsLevelOrShallower() {
        let found = Self.sections("# A\n### C\n## B\n#### D\n# E\n")

        #expect(found.map(\.start) == [1, 2, 3, 4, 5])
        #expect(found.map(\.end) == [4, 2, 4, 4, 5])
    }

    @Test
    func aBulletsLeadingBoldRunIsItsTitleAndItsRangeRunsToTheNextBulletOrHeading() {
        let found = Self.bullets("""
        ## Known-open

        - **First item title** — the rest of the sentence,
          spilling onto a continuation line.
        - **Second item title** — a shorter one.

        ## Next
        """)

        #expect(found.map(\.title) == ["First item title", "Second item title"])
        #expect(found.map(\.start) == [3, 5])
        #expect(found.map(\.end) == [4, 6])
        #expect(found.map(\.section) == [1, 1])
        #expect(found.map(\.struck) == [false, false])
    }

    @Test
    func aBulletWithNoBoldRunTitlesItselfByItsFirstDozenWords() {
        let found = Self.bullets("## Open\n\n- one two three four five six seven eight nine ten eleven twelve thirteen\n")

        #expect(found.map(\.title) == ["one two three four five six seven eight nine ten eleven twelve…"])
    }

    @Test
    func aBulletOpeningWithAStrikethroughIsFlagged() {
        let found = Self.bullets("## Open\n\n- ~~this item is done~~\n")

        #expect(found.map(\.title) == ["~~this item is done~~"])
        #expect(found.map(\.struck) == [true])
    }

    @Test
    func anIndentedBulletIsASubItemNotATopLevelOne() {
        let found = Self.bullets("## Open\n\n- top level\n  - nested, not its own row\n")

        #expect(found.map(\.title) == ["top level"])
        // The nested bullet is swallowed into the top-level item's own range.
        #expect(found.map(\.end) == [4])
    }

    @Test
    func aBulletAheadOfTheFirstHeadingHasNothingToAttachToAndIsDropped() {
        #expect(Self.bullets("- before any heading\n\n## Open\n").isEmpty)
    }

    @Test
    func aBulletInsideAFencedBlockIsNotABullet() {
        let found = Self.bullets("## Open\n\n```\n- not a bullet\n```\n")

        #expect(found.isEmpty)
    }
}
