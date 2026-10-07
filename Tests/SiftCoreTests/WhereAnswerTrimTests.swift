//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Three cuts to a `where` answer's weight, none of them a loss of information: identical sites fold onto one row, a single-file refusal drops a path the declarations above already named, and the call-sites heading states its rule once instead of restating it in the answer body.
@Suite(.temporaryDirectories)
struct WhereAnswerTrimTests {
    /// Sites sharing a file and the same enclosing declaration fold onto one row per line, and the rows come out by line ascending, whatever their wording.
    @Test
    func identicalDetailsGroupTheirLines() {
        let sites = [
            SyntacticCallSite(path: "Sources/App/Use.swift", line: 9, enclosing: "make()"),
            SyntacticCallSite(path: "Sources/App/Use.swift", line: 4, enclosing: "make()"),
            SyntacticCallSite(path: "Sources/App/Use.swift", line: 7, enclosing: "other()"),
        ]

        let rows = NameMatchedSites.rows(sites) { "in \($0.enclosing)" }

        #expect(rows == [
            "  Sources/App/Use.swift:",
            "    :4  in make()",
            "    :7  in other()",
            "    :9  in make()",
        ])
    }

    /// A flagged site never folds with an unflagged one at the same line and enclosing declaration, because the flag makes its `detail` a different string.
    @Test
    func aFlaggedRowNeverFoldsWithAnUnflaggedOne() {
        let sites = [
            SyntacticCallSite(path: "Sources/App/Use.swift", line: 4, enclosing: "make()"),
            SyntacticCallSite(path: "Sources/App/Use.swift", line: 4, enclosing: "make()"),
        ]
        var flagNext = false

        let rows = NameMatchedSites.rows(sites) { _ in
            defer { flagNext = true }
            return flagNext ? "in make() (may be unapplied on Self)" : "in make()"
        }

        #expect(rows == [
            "  Sources/App/Use.swift:",
            "    :4  in make()",
            "    :4  in make() (may be unapplied on Self)",
        ])
    }

    /// The call-site cap counts sites, not the rows folding puts them on: a cap of 2 applied before folding still stops after 2 sites even where they fold onto one row.
    @Test
    func theCapCountsSitesNotFoldedRows() {
        let sites = [
            SyntacticCallSite(path: "Sources/App/Use.swift", line: 1, enclosing: "make()"),
            SyntacticCallSite(path: "Sources/App/Use.swift", line: 2, enclosing: "make()"),
            SyntacticCallSite(path: "Sources/App/Use.swift", line: 3, enclosing: "make()"),
        ]

        let rows = NameMatchedSites.rows(sites.prefix(2)) { "in \($0.enclosing)" }

        #expect(rows == [
            "  Sources/App/Use.swift:",
            "    :1  in make()",
            "    :2  in make()",
        ])
    }

    /// A single-file refusal, told not to name declarations, drops the path too once every declaration the answer named already shares that one file.
    @Test
    func aSingleFileRefusalDropsThePathWhenDeclarationsShareIt() {
        let refusals = [
            SemanticRefusal(path: "Sources/Lib/Base.swift", reason: .modifiedSinceBuild, symbol: "Lib.Base.init()", kind: .initializer),
        ]

        let lines = SemanticRefusal.lines(refusals, namingDeclarations: false, declarationsSpanMultipleFiles: false)

        #expect(lines == ["", "semantic REFUSED — changed since the last build; build the project, then retry"])
    }

    /// The same single-file refusal keeps the path once the declarations the answer named are spread over more than one file — there the path is what tells the reader which of them was refused.
    @Test
    func aSingleFileRefusalKeepsThePathWhenDeclarationsSpanMultipleFiles() {
        let refusals = [
            SemanticRefusal(path: "Sources/Lib/Base.swift", reason: .modifiedSinceBuild, symbol: "Lib.Base.init()", kind: .initializer),
        ]

        let lines = SemanticRefusal.lines(refusals, namingDeclarations: false, declarationsSpanMultipleFiles: true)

        #expect(lines == ["", "semantic REFUSED — Sources/Lib/Base.swift was changed since the last build; build the project, then retry"])
    }

    /// A `.noCoveringUnit` refusal gets the same trim, in its own wording.
    @Test
    func aNoCoveringUnitRefusalAlsoDropsThePath() {
        let refusals = [
            SemanticRefusal(path: "Sources/Lib/Base.swift", reason: .noCoveringUnit, symbol: "Lib.Base.init()", kind: .initializer),
        ]

        let lines = SemanticRefusal.lines(refusals, namingDeclarations: false, declarationsSpanMultipleFiles: false)

        #expect(lines == [
            "",
            "semantic REFUSED — no unit in the store covers it; build this target, then retry — it may be in a target the last build skipped",
        ])
    }

    /// `affected`'s default call — naming declarations — is untouched by the new parameter's default.
    @Test
    func namingDeclarationsStaysByteIdenticalRegardlessOfSpan() {
        let refusals = [
            SemanticRefusal(path: "Sources/Lib/Base.swift", reason: .modifiedSinceBuild, symbol: "Lib.Base.init()", kind: .initializer),
        ]

        let lines = SemanticRefusal.lines(refusals)

        #expect(lines == [
            "",
            "semantic REFUSED — Sources/Lib/Base.swift was changed since the last build; build the project, then retry (1 declaration: Lib.Base.init() (init))",
        ])
    }

    /// The call-sites heading states its shape once, without restating the "verify a hit" rule `sift help answers` already carries.
    @Test
    func theHeadingStatesItsShapeOnce() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            "struct Depot {\n    func run(in place: String) {}\n}\nfunc use(_ depot: Depot) { depot.run(in: \"a\") }\n",
            to: "Sources/App/Depot.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Depot.run", freshness: freshness)

        #expect(output.contains("syntactic call sites — by written name over the working tree, never stale — see sift help answers (call sites)"))
        #expect(!output.contains("a name is not a symbol"))
        #expect(!output.contains("verify a hit"))
    }
}
