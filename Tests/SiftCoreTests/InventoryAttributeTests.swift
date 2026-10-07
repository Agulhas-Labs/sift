//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers the attribute-argument readings the inventory's dispositions are decided from, which the stored signature carries whole.
struct InventoryAttributeTests {
    @Test
    func anAttributesArgumentsAreReadWholeAndOnlyUnderItsExactName() {
        let signature = "@Test(.disabled(\"not ready\")) func multipliesLargeNumbers()"

        #expect(AttributeScanner.attributeArguments(in: signature, named: "Test") == ".disabled(\"not ready\")")
        #expect(AttributeScanner.attributeArguments(in: signature, named: "Suite") == nil)
        // A longer attribute name is not the shorter one: the parenthesis is the boundary.
        #expect(AttributeScanner.attributeArguments(in: "@Testing(1) func x()", named: "Test") == nil)
        // An attribute written with no arguments has none to read.
        #expect(AttributeScanner.attributeArguments(in: "@Test func addsTwoNumbers()", named: "Test") == nil)
    }

    @Test
    func nestedParenthesesAndParenthesesInsideALiteralBothStayInsideTheArguments() {
        let signature = "@Test(\"a (b) c\", .enabled(if: flag(for: x))) func decided()"
        let arguments = AttributeScanner.attributeArguments(in: signature, named: "Test")

        #expect(arguments == "\"a (b) c\", .enabled(if: flag(for: x))")
        #expect(AttributeScanner.traitArguments(in: arguments ?? "", named: "enabled") == "if: flag(for: x)")
        #expect(AttributeScanner.firstStringLiteral(in: arguments ?? "") == "a (b) c")
    }

    @Test
    func aTraitWithNoArgumentsIsStillFoundAndReportsNoReason() throws {
        let arguments = try #require(AttributeScanner.attributeArguments(in: "@Test(.disabled()) func x()", named: "Test"))

        #expect(arguments == ".disabled()")
        #expect(AttributeScanner.traitArguments(in: arguments, named: "disabled") == "")
        #expect(AttributeScanner.firstStringLiteral(in: "") == nil)
    }

    @Test
    func anEscapedQuoteDoesNotEndTheLiteralItIsWrittenIn() {
        #expect(AttributeScanner.firstStringLiteral(in: "(\"say \\\"no\\\" twice\")") == "say \"no\" twice")
        #expect(AttributeScanner.firstStringLiteral(in: "no literal here") == nil)
    }
}
