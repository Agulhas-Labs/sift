//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The name-matched heading names no rule of its own any longer — those moved to `sift help answers` — and a row that survived label narrowing without matching a declaration says why on its own line instead.
@Suite(.temporaryDirectories)
struct CallSiteHeadingTests {
    static func lookup(_ symbol: String, in root: URL) async throws -> String {
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    /// The heading is one short line naming no rule, well under the 733-byte paragraph it replaced.
    @Test
    func theHeadingIsOneLineAndNamesNoRule() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            "struct Depot {\n    func run(in place: String) {}\n}\nfunc use(_ depot: Depot) { depot.run(in: \"a\") }\n",
            to: "Sources/App/Depot.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await Self.lookup("Depot.run", in: root)
        let heading = try #require(output.split(separator: "\n").first { $0.hasPrefix(NameMatchedSites.headingOpening) })

        #expect(heading.utf8.count < 200)
        #expect(!heading.contains("A property is read"))
        #expect(!heading.contains("An enum case"))
        #expect(!heading.contains("A function is named"))
        #expect(!heading.contains("An initializer is called"))
        #expect(!heading.contains("argument labels could reach"))
        #expect(heading.contains("sift help answers (call sites)"))
    }

    /// "labels narrowed" appears on the heading only where narrowing actually dropped a site for this answer.
    @Test
    func labelsNarrowedAppearsOnlyWhenNarrowingDroppedASite() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            struct Depot {
                func run(in place: String, limit: Int = 3) {}
            }
            struct Orchard {
                func run() {}
            }
            """,
            to: "Sources/App/Types.swift",
            in: root
        )
        try TestSources.write(
            """
            struct Calls {
                func one() { Depot().run(in: "a") }
                func two() { Orchard().run() }
            }
            """,
            to: "Sources/App/Calls.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let narrowed = try await Self.lookup("Depot.run", in: root)
        let narrowedHeading = try #require(narrowed.split(separator: "\n").first { $0.hasPrefix(NameMatchedSites.headingOpening) })
        #expect(narrowedHeading.contains("labels narrowed"))

        let untouched = try TestSources.makeTempRepo()
        try TestSources.write(
            "struct Depot {\n    func run(in place: String) {}\n}\nfunc use(_ depot: Depot) { depot.run(in: \"a\") }\n",
            to: "Sources/App/Depot.swift",
            in: untouched
        )
        try TestSources.commitAll(in: untouched, message: "fixture")
        let plain = try await Self.lookup("Depot.run", in: untouched)
        let plainHeading = try #require(plain.split(separator: "\n").first { $0.hasPrefix(NameMatchedSites.headingOpening) })
        #expect(!plainHeading.contains("labels narrowed"))
    }

    /// A call kept only because its receiver may be the instance an unapplied method runs on is flagged on its own row, not the heading.
    @Test
    func aCallKeptAsMaybeUnappliedOnSelfIsFlaggedOnItsRow() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            struct Depot {
                func run(in place: Int) {}
                static func partial(_ depot: Depot) { _ = Self.run(depot) }
            }
            """,
            to: "Sources/App/Types.swift",
            in: root
        )
        try TestSources.write(
            """
            struct Calls {
                func one(_ depot: Depot) { depot.run(in: 1) }
                func stray(_ depot: Depot) { depot.run(4) }
            }
            """,
            to: "Sources/App/Calls.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await Self.lookup("Depot.run", in: root)

        let partialRow = try #require(output.split(separator: "\n").first { $0.contains("in Depot.partial(") })
        let oneRow = try #require(output.split(separator: "\n").first { $0.contains("in Calls.one(") })

        #expect(!output.contains("in Calls.stray("))
        #expect(partialRow.contains("(may be unapplied on Self)"))
        #expect(!oneRow.contains("(may be unapplied on Self)"))
    }

    /// An initializer site kept although it matches none of the declared initializers' labels is flagged as compiler-written or inherited, on its own row.
    @Test
    func anInitializerSiteMatchingNoDeclaredInitIsFlaggedOnItsRow() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            enum Gizmo: Int {
                case one
                init(spelled: String) { self = .one }
            }
            """,
            to: "Sources/App/Types.swift",
            in: root
        )
        try TestSources.write(
            """
            struct Calls {
                func one() -> Gizmo? { Gizmo.init(rawValue: 1) }
                func two() -> Gizmo { Gizmo.init(spelled: "x") }
            }
            """,
            to: "Sources/App/Calls.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await Self.lookup("Gizmo.init", in: root)

        let rawValueRow = try #require(output.split(separator: "\n").first { $0.contains("in Calls.one()") })
        let spelledRow = try #require(output.split(separator: "\n").first { $0.contains("in Calls.two()") })

        #expect(rawValueRow.contains("(no declared init matches — compiler-written or inherited)"))
        #expect(!spelledRow.contains("(no declared init matches — compiler-written or inherited)"))
    }

    /// `sift help answers` carries every rule the heading used to spell out, under a named "Call sites" section.
    @Test
    func helpAnswersCarriesEveryCallSiteRule() throws {
        let topic = try #require(HelpTopics.topic(named: "answers"))
        let body = topic.body

        #expect(body.contains("**Call sites.**"))
        #expect(body.contains("the scan matched a written name, not a symbol"))
        #expect(body.contains("same-named local variables and parameters"))
        #expect(body.contains("dynamically dispatched call"))
        #expect(body.contains("its uses are listed: every expression spelling its name"))
        #expect(body.contains("matched in a case pattern"))
        #expect(body.contains("handed on unapplied as T.f(x:)"))
        #expect(body.contains("#selector"))
        #expect(body.contains("self.init call or Self.init call inside T"))
        #expect(body.contains("super.init call in a class naming T as its superclass"))
        #expect(body.contains("T is declared a property wrapper"))
        #expect(body.contains("a call through a subclass or a typealias is missed"))
        #expect(body.contains("Label narrowing:"))
        #expect(body.contains("a defaulted argument left out, a trailing closure standing for its parameter"))
        #expect(body.contains("is kept whatever its labels"))
        #expect(body.contains("a metatype held in a lowercase name"))
        #expect(body.contains("one the compiler wrote"))
        #expect(body.contains("unless the query itself named labels"))
    }
}
