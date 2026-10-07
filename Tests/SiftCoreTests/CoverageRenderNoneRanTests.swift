//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// How the coverage section words a declaration none of whose lines ran.
struct CoverageRenderNoneRanTests {
    @Test func aDeclarationWhereNoLineRanSaysSoInsteadOfRepeatingItsWholeSpan() {
        let declarations = [ChangedDeclaration(path: "Sources/Kit/Greeter.swift", label: "Greeter.greet()", lines: [1 ... 6])]
        let counts: [String: [Int: UInt64]] = ["Sources/Kit/Greeter.swift": [2: 0, 3: 0, 4: 0]]

        #expect(CoverageAnswer.render(declarations, counts: counts, change: "the working tree against HEAD") == [
            "coverage: 1 changed declaration — the working tree against HEAD",
            "  Sources/Kit/Greeter.swift",
            "    Greeter.greet() :1-6 — none of its 3 lines ran",
            "coverage total: 0 of 3 lines ran in the changed declarations (0%)",
        ])
    }

    @Test func aDeclarationWithASingleLineThatDidNotRunKeepsTheRangeThatNamesIt() {
        let declarations = [ChangedDeclaration(path: "Sources/Kit/Greeter.swift", label: "Greeter.greet()", lines: [1 ... 6])]
        let counts: [String: [Int: UInt64]] = ["Sources/Kit/Greeter.swift": [4: 0]]

        #expect(CoverageAnswer.render(declarations, counts: counts, change: "the working tree against HEAD")[2] == "    Greeter.greet() :1-6 — 0 of 1 lines ran; not run :4")
    }
}
