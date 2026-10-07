//
// Copyright © Agulhas Labs
//

import Foundation
import Testing

/// What a name standing in code must be to bless a comment that says it: a type, not a word the code chose for a call site.
struct ExampleNamesReferencedTests {
    /// The survey of one Swift file's source, as the gate reads each file.
    private static func survey(of source: String) -> ExampleNamesTests.Survey {
        var survey = ExampleNamesTests.Survey()
        survey.absorb(ExampleNameScanner.split(swift: Array(source.utf8)), from: "Sources/Sample.swift")

        return survey
    }

    private static func owing(_ survey: ExampleNamesTests.Survey) -> Set<String> {
        Set(survey.sightingsOwingAPermit.map(\.sighting.name))
    }

    /// A name the code uses only as an argument label does not bless a comment naming it.
    @Test
    func aNameUsedOnlyAsAnArgumentLabelBlessesNoComment() {
        let label = "Qzx" + "Label" + "Only"
        let source = "// Says \(label) here.\nlet sample = build(first: 1, \(label): 2)\nlet other = build(\(label): 3)\n"

        #expect(Self.owing(Self.survey(of: source)) == [label])
    }

    /// A name the code uses only as a parameter name, with or without an external label before it, does not bless a comment either.
    @Test
    func aNameUsedOnlyAsAParameterNameBlessesNoComment() {
        let bare = "Qzx" + "Parameter" + "Bare"
        let labelled = "Qzx" + "Parameter" + "Labelled"
        let source = "// Says \(bare) and \(labelled).\nfunc build(first: Int, \(bare): Int, \(labelled) inner: Int) {}\n"

        #expect(Self.owing(Self.survey(of: source)) == [bare, labelled])
    }

    /// A name the code uses only in lowercase-initial form, as a label or a parameter, blesses nothing.
    @Test
    func aLowercaseInitialNameBlessesNoComment() {
        let lower = "qzx" + "Lower" + "Label"
        let source = "// Says \(lower) here.\nfunc build(\(lower): Int) {}\n"

        #expect(Self.owing(Self.survey(of: source)) == [lower])
    }

    /// A real framework type in a type position still blesses a comment naming it: as a parameter's type, a return type, a generic argument, a tuple member and a dictionary key.
    @Test
    func aNameInATypePositionStillBlessesAComment() {
        let names = ["Qzx" + "Parameter" + "Type", "Qzx" + "Return" + "Type", "Qzx" + "Generic" + "Type", "Qzx" + "Tuple" + "Type", "Qzx" + "Key" + "Type", "Qzx" + "Call" + "Type"]
        let comments = names.map { "// Says \($0).\n" }.joined()
        let source = comments + """
        func build(value: \(names[0]), pairs: [\(names[4]): Int], items: Array<\(names[2]), \(names[3])>) -> \(names[1]) {
            \(names[5]).make()
        }

        """

        #expect(Self.owing(Self.survey(of: source)).isEmpty)
    }

    /// A list line needed only by a comment naming a type some code mentions is stale, because that comment owes no permit.
    @Test
    func aPermitLineNeededOnlyByAReferencedCommentIsStale() {
        let framework = "Qzx" + "Framework" + "Type"
        let source = "// Reads a \(framework).\nfunc read(_ value: \(framework)) {}\n"

        #expect(!Self.survey(of: source).unaccountedFor.contains(framework))
    }

    /// A comment naming a name no code mentions keeps its list line.
    @Test
    func aPermitLineNeededByAnUnreferencedCommentIsNotStale() {
        let invented = "Qzx" + "Invented" + "Comment"

        #expect(Self.survey(of: "// Says \(invented).\n").unaccountedFor == [invented])
    }
}
