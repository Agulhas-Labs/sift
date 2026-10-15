//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// What holds of every `where` and `search` answer is said in full in `sift help answers`, in no primer and no tool description, and on an answer only where it applies (Docs/Design.md §2, *Superseded: the caveat is said where it applies*).
@Suite(.temporaryDirectories)
struct StandingCaveatsTests {
    /// Each standing caveat, by a phrase every place that says it carries.
    static let caveats = [
        "code this build compiled",
        "not a sibling repo, an uncompiled target or a synthesized conformance",
        "under `not code`",
        "may include same-named symbols",
        "may miss protocol, closure, unfolded-typealias uses and unapplied instance-method references",
        "an empty list is not proof it is unused",
        "by name at runtime",
        "split on the XCTest or Testing import, never the path",
    ]

    /// The lines and clauses answers carried before the caveats moved, any one of which on an answer says the move was undone.
    static let removedFromAnswers = [
        "references: code occurrences",
        "own build only",
        "written code only",
        "never the path",
        "never stale",
        "which is not use",
        "match written names",
        "may miss protocol",
    ]

    @Test
    func thePrimerCarriesNoCaveat() throws {
        let primer = try #require(SessionPrimer.render(.insideRoot("/repos/App"), audience: .session))

        for caveat in Self.caveats {
            #expect(!primer.contains(caveat), "\(caveat)")
        }
    }

    @Test(arguments: [SessionPrimer.Audience.subagent, .session])
    func noPrimerCarriesAnyCaveat(audience: SessionPrimer.Audience) throws {
        let primer = try #require(SessionPrimer.render(
            .insideRoot("/repos/App"),
            audience: audience,
            serverAbsent: audience == .session
        ))

        for caveat in Self.caveats {
            #expect(!primer.contains(caveat), "\(caveat)")
        }
    }

    @Test
    func theWhereDescriptionCarriesNoCaveat() throws {
        let description = try Self.description(of: "where")

        for caveat in Self.caveats {
            #expect(!description.contains(caveat), "\(caveat)")
        }
    }

    @Test
    func theSearchDescriptionCarriesNoClause() throws {
        let description = try Self.description(of: "search")

        #expect(!description.contains(StandingCaveats.searchClause))
        #expect(!description.contains("code this build compiled"))
    }

    private static func description(of tool: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let definition = try #require(MCPToolCatalog.tools(loadUpFront: false).first { $0["name"] as? String == tool }, sourceLocation: sourceLocation)
        return try #require(definition["description"] as? String, sourceLocation: sourceLocation)
    }

    @Test
    func theAnswersTopicCarriesEveryCaveat() throws {
        let body = try #require(HelpTopics.topic(named: "answers")).body

        for caveat in Self.caveats {
            #expect(body.contains(caveat), "\(caveat)")
        }
    }

    /// A store answer for a type, a sweep, a property, a case and a function: none repeats a standing caveat.
    @Test
    func aStoreWhereCarriesNoneOfTheRemovedLines() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add([
            "Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n",
            "Sources/App/Gizmo.swift": "public struct Gizmo {\n    public var weight = 0\n    public init() {}\n    public func spin() {}\n}\n\nextension Gizmo {\n    static let heavy = Gizmo()\n}\n\npublic enum Tone {\n    case low, high\n}\n",
            "Sources/App/Depot.swift": "func stock() -> Gizmo {\n    var gizmo = Gizmo()\n    gizmo.weight = 2\n    gizmo.spin()\n    _ = Tone.low\n    return gizmo\n}\n",
        ], to: root)
        try MCPTestRepo.build(root)
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let type = try await engine.lookup(symbol: "Gizmo", freshness: freshness)
        let answers = try await [
            type,
            engine.lookup(symbol: "Gizmo", freshness: freshness, options: WhereOptions(includeReferences: true)),
            engine.lookup(symbol: "Gizmo.weight", freshness: freshness),
            engine.lookup(symbol: "Tone.low", freshness: freshness),
            engine.lookup(symbol: "Gizmo.spin", freshness: freshness, options: WhereOptions(includeReferences: true)),
        ]

        #expect(type.contains("semantic: fresh"), "\(type)")
        #expect(type.contains("used by App.Gizmo"), "\(type)")
        for answer in answers {
            for removed in Self.removedFromAnswers {
                #expect(!answer.contains(removed), "\(removed) in \(answer)")
            }
        }
    }

    /// A type's answer with no store keeps the one caveat true of it in particular: its list is the one most read as proof.
    @Test
    func aNoStoreTypeAnswerKeepsItsEmptyListCaveat() async throws {
        let root = try MCPTestRepo.make(declaring: "Alpha", extending: "Alpha")
        try MCPTestRepo.add(["Sources/App/Use.swift": "func make() -> Alpha {\n    Alpha()\n}\n"], to: root)
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        for options in [WhereOptions(), WhereOptions(includeReferences: true)] {
            let answer = try await engine.lookup(symbol: "Alpha", freshness: freshness, options: options)

            #expect(answer.contains("an empty list is not \"unused\""), "\(answer)")
            for removed in Self.removedFromAnswers {
                #expect(!answer.contains(removed), "\(removed) in \(answer)")
            }
        }
    }
}
