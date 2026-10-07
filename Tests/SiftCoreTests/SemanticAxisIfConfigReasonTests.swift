//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// A declaration under `#if` with no occurrence recorded moves the header as a declaration without a unit does: unresolved, never stale.
struct SemanticAxisIfConfigReasonTests {
    @Test
    func anUnrecordedDeclarationUnderIfCountsAsUnresolved() {
        let refusals = [
            SemanticRefusal(path: "Sources/Lib/Pick.swift", reason: .unrecordedUnderCondition("#if os(Linux)"), symbol: "Lib.tone()", kind: .function),
            SemanticRefusal(path: "Sources/Lib/Box.swift", reason: .noCoveringUnit, symbol: "Lib.Box", kind: .structKind),
        ]

        #expect(SemanticAxis.of(refusals: refusals, occurrences: []).rendered == "fresh, 2 declarations not found in the store")
    }
}
