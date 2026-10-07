//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A function handed on unapplied is used without being called, and `where` lists it among the function's callers — by name with no store, and from the store's references with one.
///
/// Asked for calls alone, both halves answered that nothing called a function reached only as `.map(T.f(x:))`, and the function was deleted on the strength of it.
@Suite(.temporaryDirectories)
struct WhereFunctionReferenceTests {
    static var shell: String {
        """
        enum Depot {
            static func restock(from command: String) -> String? {
                command.isEmpty ? nil : command
            }

            static func moves(_ commands: [String]) -> [String?] {
                commands.map(restock(from:))
            }
        }
        """
    }

    static func lookup(_ symbol: String, in root: URL) async throws -> String {
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }

    /// Every spelling of a reference by name is a site: qualified, implicit, bare in the type itself, and with no labels at all.
    @Test
    func aFunctionHandedOnUnappliedIsListedAmongItsCallSites() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.shell, to: "Sources/App/Shell.swift", in: root)
        try TestSources.write(
            """
            struct Uses {
                func qualified(_ commands: [String]) -> [String?] {
                    commands.map(Depot.restock(from:))
                }
                func implicit() -> (String) -> String? {
                    let pick: (String) -> String? = .restock(from:)
                    return pick
                }
                func unlabeled(_ commands: [String]) -> [String?] {
                    commands.map(Depot.restock)
                }
                func mislabeled(_ commands: [String]) -> [String?] {
                    commands.map(Depot.restock(into:))
                }
            }
            """,
            to: "Sources/App/Uses.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await Self.lookup("Depot.restock(from:)", in: root)

        #expect(!output.contains("no call spelled"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Shell.swift:7  in Depot.moves(_:)"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Uses.swift:3  in Uses.qualified(_:)"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Uses.swift:6  in Uses.implicit()"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Uses.swift:10  in Uses.unlabeled(_:)"), "\(output)")
        #expect(output.contains("syntactic call sites — by written name"), "\(output)")
    }

    /// A compound name states the labels of the declaration it means, so one spelling other labels is narrowed out as a call with them is.
    @Test
    func aReferenceWithOtherLabelsIsNotCredited() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.shell, to: "Sources/App/Shell.swift", in: root)
        try TestSources.write(
            """
            struct Uses {
                func mislabeled(_ commands: [String]) -> [String?] {
                    commands.map(Depot.restock(into:))
                }
            }
            """,
            to: "Sources/App/Uses.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await Self.lookup("Depot.restock(from:)", in: root)

        #expect(output.contains("\"restock\" (2 call sites by name, 1 with the labels (from:), in 1 file"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Shell.swift:7  in Depot.moves(_:)"), "\(output)")
        #expect(!WhereStoreSiteTextTests.located(output).contains("Sources/App/Uses.swift:3"), "\(output)")
    }

    /// A selector names a method without calling it, compound or bare.
    @Test
    func aSelectorNamingTheMethodIsListed() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            final class Panel {
                func tap(_ sender: Any) {}
                func wire() -> [Any] {
                    [#selector(tap(_:)), #selector(Panel.tap)]
                }
            }
            """,
            to: "Sources/App/Panel.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await Self.lookup("Panel.tap(_:)", in: root)

        #expect(output.contains("\"tap\" (2 call sites in 1 file"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Panel.swift:4  in Panel.wire()"), "\(output)")
    }

    /// A method named on an instance with no call is spelled as a property read is, so it is not listed — but with nothing listed, the answer says where the name is still written rather than reading as unused.
    @Test
    func aNameWrittenWithNoCallStopsNothingReadingAsUnused() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            struct Hand {
                func wave() {}
            }
            let greeting = Hand().wave
            """,
            to: "Sources/App/Hand.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await Self.lookup("Hand.wave()", in: root)

        #expect(output.contains("no call spelled \"wave\" anywhere in the working tree"), "\(output)")
        #expect(output.contains("but the name is written once with no call"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("  Sources/App/Hand.swift:4  in greeting"), "\(output)")
    }

    /// `sift diff` names a changed function's callers by the same scan, so a reference to it is one of them.
    @Test
    func aDiffListsAChangedFunctionsReferenceAmongItsCallers() async throws {
        let root = try DiffEngineTests.makeRepo()
        try TestSources.write("let polishers = [Widget(count: 1)].map(Widget.polish)\n", to: "Sources/Lib/Polishers.swift", in: root)
        try TestSources.commitAll(in: root, message: "a reference")
        try TestSources.write(DiffEngineTests.polishReturningString(), to: "Sources/Lib/Widget.swift", in: root)

        let output = try await DiffEngineTests.diff(root)

        #expect(output.contains("Sources/Lib/Polishers.swift:1"), "\(output)")
    }

    /// With a fresh store, a reference is recorded with no call role, and it is listed among the callers marked as what it is.
    @Test
    func theStoresCallersIncludeAReferenceMarkedAsNotCalled() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "Gizmo", targets: [.target(name: "GizmoCore")])
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(Self.shell, to: "Sources/GizmoCore/Shell.swift", in: root)
        try TestSources.write(
            """
            struct Uses {
                func qualified(_ commands: [String]) -> [String?] {
                    commands.map(Depot.restock(from:))
                }
                func direct() -> String? {
                    Depot.restock(from: "north")
                }
            }
            """,
            to: "Sources/GizmoCore/Uses.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "buildable fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Depot.restock(from:)", freshness: freshness)

        #expect(output.contains("semantic: fresh"), "\(output)")
        #expect(output.contains("callers of GizmoCore.Depot.restock(from:) (3):"), "\(output)")
        #expect(output.contains("    :7  moves(_:) — referenced, not called  | commands.map(restock(from:))"), "\(output)")
        #expect(output.contains("    :3  qualified(_:) — referenced, not called  | commands.map(Depot.restock(from:))"), "\(output)")
        #expect(output.split(separator: "\n").contains("    :6  direct()  | Depot.restock(from: \"north\")"), "\(output)")
    }

    /// A caller that names the function on one line and calls it on a later one is marked "referenced, not called" only on the line that names it: few enough to list one row per line, its sites are not folded, so each row carries its own mark.
    @Test
    func aFoldedCallerThatAlsoCallsIsNotMarkedAsNotCalled() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "Gizmo", targets: [.target(name: "GizmoCore")])
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(Self.shell, to: "Sources/GizmoCore/Shell.swift", in: root)
        try TestSources.write(
            """
            struct Uses {
                func both() -> [String?] {
                    let pick = Depot.restock(from:)
                    return [pick("south"), Depot.restock(from: "north")]
                }
            }
            """,
            to: "Sources/GizmoCore/Uses.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "buildable fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Depot.restock(from:)", freshness: freshness)

        #expect(output.contains("semantic: fresh"), "\(output)")
        #expect(output.contains("  Sources/GizmoCore/Uses.swift (2):\n    :3  both() — referenced, not called  | let pick = Depot.restock(from:)\n    :4  both()  | return [pick(\"south\"), Depot.restock(from: \"north\")]\n"), "\(output)")
        #expect(!output.contains(":4  both() — referenced"), "\(output)")
        #expect(output.contains("    :7  moves(_:) — referenced, not called  | commands.map(restock(from:))"), "\(output)")
    }

    /// A bare `T.f` handed to a call is the function's only on a type declaring it: on another type it is spelled as that type's case or static property is, and is counted by name rather than listed.
    @Test
    func aMemberOfAnotherTypeHandedToACallIsNotCredited() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            enum Mode {
                case fast
            }
            enum Engine {
                static func fast(level: Int) {}
            }
            func configure(_ mode: Mode) {}
            func start() {
                configure(Mode.fast)
                configure(Mode.fast)
                Engine.fast(level: 1)
            }
            """,
            to: "Sources/App/Engine.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await Self.lookup("Engine.fast(level:)", in: root)

        #expect(output.contains("\"fast\" (1 call site in 1 file"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Engine.swift:11  in start()"), "\(output)")
        #expect(!WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Engine.swift:9  in start()"), "\(output)")
    }

    /// A name written twice on one line with no call — `self.size = size` — is one place to look, listed and counted once.
    @Test
    func aNameWrittenTwiceOnOneLineIsCountedOnce() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            struct Meter {
                func size() -> Int { 0 }
            }
            struct Box {
                var size: Int
                init(size: Int) {
                    self.size = size
                }
            }
            """,
            to: "Sources/App/Box.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")

        let output = try await Self.lookup("Meter.size()", in: root)

        #expect(output.contains("but the name is written once with no call"), "\(output)")
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).components(separatedBy: "Sources/App/Box.swift:7  in Box.init(size:)").count == 2, "\(output)")
    }

    /// A line whose merged uses hold a reference before a call keeps only the reference's `uncalled` flag unless the merge takes it together with the rest: the row must carry "referenced, not called" only when none of its sites calls.
    @Test
    func aLineWithAReferenceThenACallIsNotMarkedAsUncalled() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "Gizmo", targets: [.target(name: "GizmoCore")])
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(Self.shell, to: "Sources/GizmoCore/Shell.swift", in: root)
        try TestSources.write(
            """
            struct Uses {
                func merged() -> String? {
                    let pick = Depot.restock(from:); return pick("south") ?? Depot.restock(from: "north")
                }
            }
            """,
            to: "Sources/GizmoCore/Uses.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "buildable fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Depot.restock(from:)", freshness: freshness)

        #expect(output.contains("semantic: fresh"), "\(output)")
        #expect(output.split(separator: "\n").contains("    :3  merged()  | let pick = Depot.restock(from:); return pick(\"south\") ?? Depot.restock(from: \"north\")"), "\(output)")
        #expect(!output.contains(":3  merged() — referenced"), "\(output)")
    }
}
