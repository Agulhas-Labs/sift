//
// Copyright © Agulhas Labs
//

import Testing

/// The name gate's reading of a doc comment's symbol link.
///
/// A double-backtick member link, the kind the doc compiler resolves, names a function with its argument labels, `Type/member(label:)`. The labels are the function's own parameter names, which the compiler resolves, so they are not example vocabulary; a name standing anywhere else in the comment is still held to the permit list.
struct DocCLinkLabelsTests {
    private static let label = "qzx" + "Label"
    private static let plain = "qzx" + "Plain"

    private static func unpermitted(_ source: String) -> [String] {
        ExampleNameScanner.unpermittedNames(in: Array(source.utf8), isSwift: true, permitted: [], declared: [])
            .map(\.name)
    }

    @Test
    func labelsInADocCMemberLinkPass() {
        let source = "/// See ``Thing/run(\(Self.label):from:)`` for the call.\nlet value = 1\n"

        #expect(Self.unpermitted(source).isEmpty)
    }

    @Test
    func aPlainNameInTheSameCommentStillFails() {
        let source = "/// See ``Thing/run(\(Self.label):from:)`` and \(Self.plain).\nlet value = 1\n"

        #expect(Self.unpermitted(source) == [Self.plain])
    }

    @Test
    func theLabelsOutsideALinkStillFail() {
        let source = "/// Pass \(Self.label) here.\nlet value = 1\n"

        #expect(Self.unpermitted(source) == [Self.label])
    }
}
