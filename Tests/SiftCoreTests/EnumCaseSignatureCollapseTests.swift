//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// An enum case's signature is one line, cut for display at the length every other kind's is.
struct EnumCaseSignatureCollapseTests {
    private static var path: String {
        "Sources/App/Fixture.swift"
    }

    private static var multiline: String {
        """
        enum Tree {
            case multi(
                // the first
                first: Int,
                second: String = "x"
            ), other
        }
        """
    }

    private static var long: String {
        let values = (0 ..< 30).map { "value\($0): Int" }.joined(separator: ", ")
        return "enum Wide {\n    case wide(\(values))\n}"
    }

    private static func searched(_ source: String) throws -> [String] {
        try StructuralMatcher.matches(in: source, path: path, query: StructuralQuery("kind:case")).map(\.signature)
    }

    private static func indexed(_ source: String) throws -> [String] {
        try TestSources.parsed(source, path: path).symbols.filter { $0.kind == .enumCase }.map(\.signature)
    }

    /// Associated values written over several lines are one line in the index and in `search`.
    @Test
    func aMultiLineCaseIsOneLineInTheIndexAndInSearch() throws {
        let expected = ["case multi( // the first first: Int, second: String = \"x\" )", "case other"]

        #expect(try Self.indexed(Self.multiline) == expected)
        #expect(try Self.searched(Self.multiline) == expected)
    }

    /// `search` cuts a long case at the display cap, as `where` and `digest` do, ending in an ellipsis.
    @Test
    func aLongCaseIsCutInSearchWhereTheIndexKeepsItWhole() throws {
        let whole = try #require(Self.indexed(Self.long).first)
        let shown = try #require(Self.searched(Self.long).first)

        #expect(whole.count > SourceSlicer.signatureCap)
        #expect(shown.count == SourceSlicer.signatureCap)
        #expect(shown.hasSuffix("…"))
        #expect(shown == SourceSlicer.cut(whole, at: SourceSlicer.signatureCap))
    }
}
