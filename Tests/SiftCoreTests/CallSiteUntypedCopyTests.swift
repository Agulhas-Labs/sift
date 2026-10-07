//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers `SyntacticCallSite.untyped(namingAnyOf:)`: untyping a receiver that names a function-local type changes the receiver and records which types around the site are local, and nothing else, so no field the scan recorded is lost on the way.
struct CallSiteUntypedCopyTests {
    /// A site whose receiver names a local type comes back equal to itself with no receiver, its type name's position and line text kept.
    @Test
    func untypingALocalReceiverKeepsEveryOtherField() {
        var site = SyntacticCallSite(path: "Sources/Lib/Lib.swift", line: 4, enclosing: "probe()", enclosingTypes: ["Box"], arguments: nil, receiver: .type("Box", mayBeUnseen: false), calleeAt: "4:9", nameAt: "4:13")
        site.text = "_ = Box.Item()"
        var expected = site
        expected.receiver = nil
        expected.localEnclosingTypes = ["Box"]

        let untyped = site.untyped(namingAnyOf: ["Box"])

        #expect(untyped == expected)
        #expect(untyped.nameAt == "4:13")
        #expect(untyped.text == "_ = Box.Item()")
    }
}
