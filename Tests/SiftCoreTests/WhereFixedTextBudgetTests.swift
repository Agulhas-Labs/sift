//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins the byte weight of a `where` answer's fixed text — the wording that does not vary with the code found — so a heading or a notice line cannot regrow into a paragraph unnoticed, the way the call-sites heading did twice.
@Suite(.temporaryDirectories)
struct WhereFixedTextBudgetTests {
    /// The largest fixed text measured on the fixture below (an initializer 285 bytes, a property 291, an enum case 290, and a function with a narrowed label 303 — the widest, since it also carries "labels narrowed") is 303 bytes; this constant is that measurement with about 25% headroom, rounded.
    ///
    /// Raising this constant is a deliberate decision about how much fixed wording a `where` answer may carry, never a way to let a regrown heading or notice paragraph slip back through this test.
    static let fixedTextByteBudget = 380

    /// A repository built once with an index store, then edited so every declaration in `Widgets.swift` refuses as stale while its call sites — scanned from the working tree, never stale — still resolve.
    ///
    /// `Box` carries two initializers, `Ledger` a property, `Status` an enum case, and `Depot`/`Orchard` a same-named function whose labels differ, so asking for `Depot.run` drops `Orchard`'s call and prints "labels narrowed".
    static func makeRefusedFixture() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [.target(name: "Lib")]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            """
            struct Box {
                let x: Int
                init(x: Int) { self.x = x }
                init(y: Int) { self.x = y }
            }

            struct Ledger {
                var balance: Int = 0
            }

            enum Status {
                case active
                case idle
            }

            struct Depot {
                func run(in place: String, limit: Int = 3) {}
            }

            struct Orchard {
                func run() {}
            }
            """,
            to: "Sources/Lib/Widgets.swift",
            in: root
        )
        try TestSources.write(
            """
            func use() {
                let a = Box(x: 1)
                let b = Box(y: 2)
                var ledger = Ledger()
                ledger.balance = 10
                let s: Status = .active
                Depot().run(in: "a")
                Orchard().run()
            }
            """,
            to: "Sources/Lib/Caller.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.swiftBuild(packageAt: root)
        // Rewritten after the build, with the same declarations, so every symbol in this file refuses as stale.
        try TestSources.write(
            """
            struct Box {
                let x: Int
                init(x: Int) { self.x = x }
                init(y: Int) { self.x = y }
            }

            struct Ledger {
                var balance: Int = 0
            }

            enum Status {
                case active
                case idle
            }

            struct Depot {
                func run(in place: String, limit: Int = 3) {}
            }

            struct Orchard {
                func run() {}
            }
            // touched after the build
            """,
            to: "Sources/Lib/Widgets.swift",
            in: root
        )
        return root
    }

    /// Extracts a rendered `where` answer's fixed text — the words that do not vary with the code found — to weigh it against a byte budget.
    ///
    /// Fixed text is every line of the answer's body (everything after the leading freshness header, which every sift answer shares and is not this issue's subject, so it is excluded) except an indented line — a declaration row, a call-sites file heading, a site row, or a truncation line, all indented — and a line starting with `"` (the `"name" (…):` line introducing a call-sites list). What remains is the `mode:` line, the query-echo line, every section title (`declarations (N):`), every notice line (`semantic REFUSED …`, a parse-error or module-guessed banner), and the `syntactic call sites — …` heading — the wording a regrown rule or paragraph would land in.
    static func fixedText(of answer: String) -> String {
        let lines = answer.split(separator: "\n", omittingEmptySubsequences: false)
        let body = lines.dropFirst()
        let fixed = body.filter { !$0.hasPrefix(" ") && !$0.hasPrefix("\"") }
        return fixed.joined(separator: "\n")
    }

    /// One asked symbol's fixed text is within budget, and the answer actually carries the REFUSED and call-sites block it is meant to measure — so this cannot pass on an answer without one.
    static func assertBudget(_ symbol: String, root: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        let answer = try await engine.lookup(symbol: symbol, freshness: freshness)

        #expect(answer.contains("REFUSED"), "\(symbol) — expected a REFUSED notice", sourceLocation: sourceLocation)
        #expect(
            answer.contains(NameMatchedSites.headingOpening),
            "\(symbol) — expected the call-sites heading",
            sourceLocation: sourceLocation
        )

        let fixed = fixedText(of: answer)
        #expect(
            fixed.utf8.count <= fixedTextByteBudget,
            "\(symbol) — fixed text is \(fixed.utf8.count) bytes, over the \(fixedTextByteBudget)-byte budget:\n\(fixed)",
            sourceLocation: sourceLocation
        )
    }

    @Test
    func anInitializersFixedTextStaysWithinBudget() async throws {
        try await Self.assertBudget("Box.init", root: Self.makeRefusedFixture())
    }

    @Test
    func aPropertysFixedTextStaysWithinBudget() async throws {
        try await Self.assertBudget("Ledger.balance", root: Self.makeRefusedFixture())
    }

    @Test
    func anEnumCasesFixedTextStaysWithinBudget() async throws {
        try await Self.assertBudget("Status.active", root: Self.makeRefusedFixture())
    }

    /// `Depot.run`'s call sites drop `Orchard`'s differently labeled call, so this answer also carries "labels narrowed" — the widest of the fixed-text notices measured here.
    @Test
    func aFunctionWithANarrowedLabelsFixedTextStaysWithinBudget() async throws {
        let root = try Self.makeRefusedFixture()
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        let answer = try await engine.lookup(symbol: "Depot.run", freshness: freshness)

        #expect(answer.contains("labels narrowed"))
        try await Self.assertBudget("Depot.run", root: root)
    }

    /// The call-sites heading itself is a single line, well under the 200-byte ceiling `CallSiteHeadingTests` already asserts — kept to a tighter number here since this suite is the one pinning byte weight.
    @Test
    func theCallSitesHeadingIsASingleShortLine() async throws {
        let root = try Self.makeRefusedFixture()
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        let answer = try await engine.lookup(symbol: "Box.init", freshness: freshness)

        let heading = try #require(answer.split(separator: "\n").first { $0.hasPrefix(NameMatchedSites.headingOpening) })

        #expect(heading.utf8.count <= 160)
    }
}
