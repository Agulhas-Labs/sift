//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers enum cases as search results: found by `name:`, confined by `kind:case`, one declaration per name as the index holds them.
struct StructuralSearchCaseTests {
    private static func matches(_ query: String, in source: String) throws -> [StructuralMatch] {
        try StructuralMatcher.matches(in: source, path: "Sources/App/Fixture.swift", query: StructuralQuery(query))
    }

    private static var axis: String {
        """
        enum SemanticAxis {
            case syntacticOnly
            case noStore
            static func noStoreNote(for tree: String) -> String { tree }
        }
        """
    }

    /// A name search lists a case beside the functions that share its word, and `kind:case` keeps only the case.
    @Test
    func aCaseIsFoundByNameAndConfinedByKind() throws {
        let byName = try Self.matches("name:noStore", in: Self.axis)
        #expect(byName.map(\.qualifiedName) == ["SemanticAxis.noStore", "SemanticAxis.noStoreNote(for:)"])

        let cases = try Self.matches("name:noStore kind:case", in: Self.axis)
        #expect(cases.map(\.qualifiedName) == ["SemanticAxis.noStore"])
        #expect(cases.map(\.kind) == ["case"])
        #expect(cases.map(\.line) == [3])
        #expect(cases.map(\.signature) == ["case noStore"])
    }

    /// A case with associated values is named as `where` names it, labels and all, and a bare word still finds it.
    @Test
    func aCaseWithAssociatedValuesIsNamedWithItsLabels() throws {
        let source = """
        enum Mode {
            case value(Int)
            case pair(left: Int, right: Int)
        }
        """
        let cases = try Self.matches("kind:case", in: source)

        #expect(cases.map(\.qualifiedName) == ["Mode.value(_:)", "Mode.pair(left:right:)"])
        #expect(cases.map(\.signature) == ["case value(Int)", "case pair(left: Int, right: Int)"])
        #expect(try Self.matches("name:pair", in: source).map(\.qualifiedName) == ["Mode.pair(left:right:)"])
    }

    /// `case a, b` declares two cases on one line, each with its own signature, so `sig:` and `uses:` tell them apart.
    @Test
    func eachNameOfAOneLineCaseIsADeclarationOfItsOwn() throws {
        let source = """
        enum Node {
            case lineStart, lineEnd(Int)
        }
        """
        let cases = try Self.matches("kind:case", in: source)

        #expect(cases.map(\.qualifiedName) == ["Node.lineStart", "Node.lineEnd(_:)"])
        #expect(cases.map(\.line) == [2, 2])
        #expect(cases.map(\.signature) == ["case lineStart", "case lineEnd(Int)"])
        #expect(try Self.matches("kind:case sig:lineEnd", in: source).map(\.qualifiedName) == ["Node.lineEnd(_:)"])
        #expect(try Self.matches("kind:case uses:Int", in: source).map(\.qualifiedName) == ["Node.lineEnd(_:)"])
    }

    /// A nested enum's case is qualified by both enums and owned by the inner one; a `switch`'s `case` and an enum inside a function body are not declarations search lists.
    @Test
    func aNestedEnumsCaseIsQualifiedAndASwitchCaseIsNot() throws {
        let source = """
        enum InPlaceAnswerer {
            enum Withholding {
                case noStore
                case backingOff
            }

            func describe(_ reason: Withholding) -> String {
                enum Local { case noStore }
                switch reason {
                case .noStore: return "store"
                case .backingOff: return "back"
                }
            }
        }
        """
        let cases = try Self.matches("name:noStore kind:case", in: source)

        #expect(cases.map(\.qualifiedName) == ["InPlaceAnswerer.Withholding.noStore"])
        #expect(try Self.matches("kind:case owner:Withholding", in: source).count == 2)
        #expect(try Self.matches("kind:case owner:InPlaceAnswerer", in: source).isEmpty)
    }

    /// An attribute or modifier written on a `case` is a fact of every name it declares.
    @Test
    func aCasesAttributesAndModifiersAreItsOwn() throws {
        let source = """
        enum Mode {
            @available(*, deprecated) case value(Int)
            indirect case pair(left: Mode, right: Mode)
        }
        """

        #expect(try Self.matches("kind:case attr:available", in: source).map(\.qualifiedName) == ["Mode.value(_:)"])
        #expect(try Self.matches("kind:case modifier:indirect", in: source).map(\.qualifiedName) == ["Mode.pair(left:right:)"])
    }
}
