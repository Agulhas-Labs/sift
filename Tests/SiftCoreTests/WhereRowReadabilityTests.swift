//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Two readability cuts to a name-matched block's rows: a line more than one site shares prints once with a count instead of repeating, and the block's truncation line sits at the row's own indent rather than the file heading's.
@Suite(.temporaryDirectories)
struct WhereRowReadabilityTests {
    /// Two sites at the same line, in the same enclosing declaration, fold onto one number carrying a `(×2)` count rather than repeating the line — the site count behind the cap still counts both of them.
    @Test
    func repeatedLinesInOneEnclosingDeclarationFoldWithACount() {
        let sites = [
            SyntacticCallSite(path: "Sources/App/Use.swift", line: 2, enclosing: "make()"),
            SyntacticCallSite(path: "Sources/App/Use.swift", line: 2, enclosing: "make()"),
            SyntacticCallSite(path: "Sources/App/Use.swift", line: 3, enclosing: "make()"),
        ]

        let rows = NameMatchedSites.rows(sites) { "in \($0.enclosing)" }

        #expect(rows == [
            "  Sources/App/Use.swift:",
            "    :2 (×2)  in make()",
            "    :3  in make()",
        ])
    }

    /// A line shared by three or more sites still prints once, with the full count.
    @Test
    func aLineSharedByMoreThanTwoSitesCountsAllOfThem() {
        let sites = [
            SyntacticCallSite(path: "Sources/App/Use.swift", line: 5, enclosing: "run()"),
            SyntacticCallSite(path: "Sources/App/Use.swift", line: 5, enclosing: "run()"),
            SyntacticCallSite(path: "Sources/App/Use.swift", line: 5, enclosing: "run()"),
        ]

        let rows = NameMatchedSites.rows(sites) { "in \($0.enclosing)" }

        #expect(rows == [
            "  Sources/App/Use.swift:",
            "    :5 (×3)  in run()",
        ])
    }

    /// The grouped (`where`) truncation line sits at the row's own 4-space indent, not the 2-space indent of the file heading above it.
    @Test
    func theGroupedTruncationLineSitsAtTheRowIndent() {
        let sites = (1 ... 5).map { SyntacticCallSite(path: "Sources/App/Use.swift", line: $0, enclosing: "run()") }

        let lines = WrapperAttributeSites.lines(sites, named: "Clamp", for: "init(wrappedValue:)", cap: 2, grouped: true)
        let truncated = lines.last { $0.contains("truncated:") }

        #expect(truncated?.hasPrefix("    ") == true, "\(lines)")
        #expect(truncated?.hasPrefix("     ") == false, "\(lines)")
    }

    /// The ungrouped (`diff`) truncation line is untouched: `diff` output must not change.
    @Test
    func theUngroupedTruncationLineStaysAtTwoSpaces() {
        let sites = (1 ... 5).map { SyntacticCallSite(path: "Sources/App/Use.swift", line: $0, enclosing: "run()") }

        let lines = WrapperAttributeSites.lines(sites, named: "Clamp", for: "init(wrappedValue:)", cap: 2)
        let truncated = lines.last { $0.contains("truncated:") }

        #expect(truncated == "  truncated: 3 more call sites", "\(lines)")
    }

    /// A block with a folded `(×2)` row and a 4-space truncation line still reads as entirely inside the block: nothing it lists leaks out as a located line.
    @Test
    func aFoldedRowAndItsTruncationLineStayInsideTheBlock() {
        let answer = [
            "declarations (1):",
            "  App.make — func — Sources/App/A.swift:1",
            "",
            "\(NameMatchedSites.headingOpening) over the working tree, never stale — see sift help answers (call sites)",
            "\"make\" (3 call sites in 1 file):",
            "  Sources/App/Use.swift:",
            "    :2 (×2), :3  in make()",
            "    truncated: 1 more call site",
        ].joined(separator: "\n")

        let outside = NameMatchedSites.linesOutside(answer: answer)

        #expect(outside == [
            "declarations (1):",
            "  App.make — func — Sources/App/A.swift:1",
            "",
        ])
    }
}
