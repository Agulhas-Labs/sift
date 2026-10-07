//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// A signature's whitespace is collapsed for display and comparison, but never inside a string literal: a default argument's text is part of what the signature says.
struct SignatureLiteralWhitespaceTests {
    @Test
    func aDefaultOfFourSpacesIsKept() {
        let collapsed = SourceSlicer.collapsingWhitespace(in: "func join(sep: String   =   \"    \")")

        #expect(collapsed == "func join(sep: String = \"    \")")
    }

    @Test
    func aTabInsideALiteralIsKept() {
        #expect(SourceSlicer.collapsingWhitespace(in: "func f(a: String = \"\t\",  b: Int)") == "func f(a: String = \"\t\", b: Int)")
    }

    @Test
    func aRawLiteralWithSpacesAndAQuoteIsKept() {
        let source = "func f(a: String = #\"a   \"b\"  c\"#,\n    b: Int)"

        #expect(SourceSlicer.collapsingWhitespace(in: source) == "func f(a: String = #\"a   \"b\"  c\"#, b: Int)")
    }

    @Test
    func aMultiLineLiteralKeepsItsNewlinesAndIndent() {
        let source = "func f(a: String = \"\"\"\n    x   y\n    \"\"\",   b: Int)"

        #expect(SourceSlicer.collapsingWhitespace(in: source) == "func f(a: String = \"\"\"\n    x   y\n    \"\"\", b: Int)")
    }

    @Test
    func anEscapedQuoteDoesNotEndTheLiteral() {
        let source = "func f(a: String = \"\\\"   \",   b: Int)"

        #expect(SourceSlicer.collapsingWhitespace(in: source) == "func f(a: String = \"\\\"   \", b: Int)")
    }

    @Test
    func anEmptyLiteralDoesNotHoldTheRestOfTheSignatureOpen() {
        #expect(SourceSlicer.collapsingWhitespace(in: "func f(a: String = \"\",   b: Int  =  1)") == "func f(a: String = \"\", b: Int = 1)")
    }

    @Test
    func ordinarySignatureWhitespaceIsStillCollapsed() {
        #expect(SourceSlicer.collapsingWhitespace(in: "  public   func  f(\n    a: Int,\n\tb: Int\n)  ") == "public func f( a: Int, b: Int )")
    }
}
