//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// The signatures-only view of members whose body brace is easy to misjudge.
struct MemberSignatureCasesTests {
    private func signature(_ source: String) -> String {
        MemberSignature.lines(of: source.components(separatedBy: "\n")).joined(separator: "\n")
    }

    @Test
    func observersAfterAnInitialValueAreLeftOut() {
        let source = """
        var observed = 0 {
            didSet { log("hidden") }
            willSet { log("also hidden") }
        }
        """

        #expect(signature(source) == "var observed = 0")
    }

    @Test
    func aClosureInitialiserStillCountsAsTheValue() {
        let source = "var made: Int = { 4 }()"

        #expect(signature(source) == source)
    }

    @Test
    func aKeywordInsideAnAttributeStringDoesNotHideTheAccessorClause() {
        let source = """
        @available(*, deprecated, message: "use init(x:) instead") var legacy: Int { get set }
        """

        #expect(signature(source) == source)
    }

    @Test
    func aCustomOperatorEndingOutsideTheAsciiSetLosesItsBody() {
        let source = """
        static func •= (lhs: inout Self, rhs: Self) {
            lhs = rhs
        }
        """

        #expect(signature(source) == "static func •= (lhs: inout Self, rhs: Self)")
    }
}
