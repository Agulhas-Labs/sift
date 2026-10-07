//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A base identifier spelled like a type is credited as a call site of that type's member only where nothing shadows it: a local `let`/`var`, or a parameter of the same name, makes the base a value instead.
///
/// `let Holder = Placeholder(tick: 1); take(Holder.tick)` read `Holder.tick` as the type `Holder`'s own member handed on unapplied — crediting a local variable's member read as a call site of a same-spelled type's function.
@Suite(.temporaryDirectories)
struct WhereShadowedTypeNameTests {
    static var shell: String {
        """
        enum Holder {
            static func tick() {}
        }
        struct Placeholder {
            let tick: Int
        }
        func take(_ value: Any) {}
        func realCall() {
            Holder.tick()
        }
        """
    }

    static func lookup(_ symbol: String, in root: URL) async throws -> String {
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    /// A local variable spelled like the type shadows it: the base is the variable's value, not the type, so its member is never credited as `Holder.tick()`'s call site — only the genuine call remains.
    @Test
    func aLocalVariableShadowingTheTypeNameIsNotCredited() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.shell, to: "Sources/App/Shell.swift", in: root)
        try TestSources.write(
            """
            struct Uses {
                func run() {
                    let Holder = Placeholder(tick: 1)
                    take(Holder.tick)
                }
            }
            """,
            to: "Sources/App/Uses.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await Self.lookup("Holder.tick()", in: root)

        #expect(output.contains("\"tick\" (1 call site in 1 file"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Shell.swift:9  in realCall()"), "\(output)")
        #expect(!output.contains("Uses.swift"), "\(output)")
    }

    /// With nothing shadowing it, the base written `Holder.tick` is still credited as the type's own member handed on unapplied, beside the genuine call.
    @Test
    func anUnshadowedBaseIsStillCredited() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.shell, to: "Sources/App/Shell.swift", in: root)
        try TestSources.write(
            """
            struct Uses {
                func run() {
                    take(Holder.tick)
                }
            }
            """,
            to: "Sources/App/Uses.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await Self.lookup("Holder.tick()", in: root)

        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Shell.swift:9  in realCall()"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Uses.swift:3  in Uses.run()"), "\(output)")
    }

    /// An `if let` binds its name only inside its own body, so a base written after that statement is the type again and is still credited.
    @Test
    func anEarlierIfLetShadowsOnlyItsOwnBody() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.shell, to: "Sources/App/Shell.swift", in: root)
        try TestSources.write(
            """
            struct Uses {
                func run(_ maybe: Placeholder?) {
                    if let Holder = maybe { take(Holder.tick) }
                    take(Holder.tick)
                }
            }
            """,
            to: "Sources/App/Uses.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await Self.lookup("Holder.tick()", in: root)
        let sites = WhereAnswerRepetitionTests.sitesOnePerLine(output)

        #expect(!sites.contains("Sources/App/Uses.swift:3  in Uses.run(_:)"), "\(output)")
        #expect(sites.contains("Sources/App/Uses.swift:4  in Uses.run(_:)"), "\(output)")
    }

    /// A parameter named like the type shadows it the same way a local variable does.
    @Test
    func aParameterShadowingTheTypeNameIsNotCredited() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.shell, to: "Sources/App/Shell.swift", in: root)
        try TestSources.write(
            """
            struct Uses {
                func run(_ Holder: Placeholder) {
                    take(Holder.tick)
                }
            }
            """,
            to: "Sources/App/Uses.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await Self.lookup("Holder.tick()", in: root)

        #expect(output.contains("\"tick\" (1 call site in 1 file"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Shell.swift:9  in realCall()"), "\(output)")
        #expect(!output.contains("Uses.swift"), "\(output)")
    }
}
