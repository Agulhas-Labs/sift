//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// The signature the index stores for an enum case, which `where` and `digest` print and `search` gives alike.
struct IndexedEnumCaseSignatureTests {
    /// Each name of `case a, b` is signed alone: the comma that separates it from the next name belongs to neither.
    @Test
    func aCaseListedBeforeAnotherIsSignedWithoutTheComma() throws {
        let file = try TestSources.parsed(
            """
            enum Node {
                case lineStart, lineEnd
                case mixed(Int, label: String), plain
            }
            """,
            path: "Sources/App/Node.swift"
        )

        let signatures = file.symbols.filter { $0.kind == .enumCase }.map(\.signature)

        #expect(signatures == ["case lineStart", "case lineEnd", "case mixed(Int, label: String)", "case plain"])
    }

    /// The index and `search` give a case the same signature.
    @Test
    func searchSignsACaseAsTheIndexDoes() throws {
        let source = """
        enum Node {
            case lineStart, lineEnd(Int)
        }
        """
        let indexed = try TestSources.parsed(source, path: "Sources/App/Node.swift").symbols.filter { $0.kind == .enumCase }.map(\.signature)
        let searched = try StructuralMatcher.matches(in: source, path: "Sources/App/Node.swift", query: StructuralQuery("kind:case")).map(\.signature)

        #expect(indexed == searched)
    }
}
