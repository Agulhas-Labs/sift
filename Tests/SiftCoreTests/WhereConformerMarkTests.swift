//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins that no mark or caption on a store-backed conformers list claims more than the store knows: a conformer in a deleted file is not called indirect, one through a typealias is listed and says so, and a class's list does not claim indirect conformers.
@Suite(.temporaryDirectories, .serialized)
struct WhereConformerMarkTests {
    private static var manifest: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Lib",
            targets: [.target(name: "Lib")]
        )
        """
    }

    /// A built package whose protocol has a conformer written directly and one written through a typealias, beside a class with a subclass.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-conformer-mark") { root in
            try TestSources.write(manifest, to: "Package.swift", in: root)
            try TestSources.write(
                """
                public protocol Greeter {}

                public typealias Salute = Greeter

                public struct Soldier: Greeter {}

                public struct Cadet: Salute {}

                public class Sergeant {}

                public final class Recruit: Sergeant {}
                """,
                to: "Sources/Lib/Ranks.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "conformer mark fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// A conformer in a file deleted since the build says so, and is not called indirect: nothing is known of how it conforms.
    @Test
    func aConformerInADeletedFileIsNotCalledIndirect() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.manifest, to: "Package.swift", in: root)
        try TestSources.write("public protocol Greeter {}\n", to: "Sources/Lib/Greeter.swift", in: root)
        try TestSources.write("public struct Soldier: Greeter {}\n", to: "Sources/Lib/Soldier.swift", in: root)
        try TestSources.write("public struct Medic: Greeter {}\n", to: "Sources/Lib/Medic.swift", in: root)
        try TestSources.commitAll(in: root, message: "deleted conformer fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Lib/Medic.swift"))

        let output = try await engine.lookup(symbol: "Greeter", freshness: engine.ensureFresh())

        #expect(output.contains("  Medic — Sources/Lib/Medic.swift:1  (file deleted since last build)\n") || output.hasSuffix("  Medic — Sources/Lib/Medic.swift:1  (file deleted since last build)"), "\(output)")
        #expect(!output.contains("indirect  (file deleted"), "\(output)")
        #expect(output.contains("(2: 1 direct, 0 indirect, 1 in a deleted file — "), "\(output)")
        #expect(output.contains("  Lib.Soldier — struct — Sources/Lib/Soldier.swift:1 — direct\n"), "\(output)")
        #expect(output.contains("Sources/Lib/Medic.swift (1):  (file deleted since last build)"), "\(output)")
    }

    /// A conformer written through a typealias of the protocol is listed, marked with the alias, and its line stays in the usage rows.
    @Test
    func aConformerThroughATypealiasIsListedAndMarked() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Greeter", freshness: engine.ensureFresh())

            #expect(output.contains("conformers of Greeter (2: 1 direct, 0 indirect, 1 through a typealias — "), "\(output)")
            #expect(output.contains("  Lib.Cadet — struct — Sources/Lib/Ranks.swift:7 — through typealias Lib.Salute"), "\(output)")
            #expect(output.contains("  Lib.Soldier — struct — Sources/Lib/Ranks.swift:5 — direct\n"), "\(output)")
            #expect(output.contains("    :7  | public struct Cadet: Salute {}"), "\(output)")
            #expect(ExactAnswer.locations(inWhereAnswer: output).contains { $0.path == "Sources/Lib/Ranks.swift" && $0.line == 7 }, "\(output)")
        }
    }

    /// The row a conformer through an alias ends on is read back to the line it names.
    @Test
    func theAliasMarkIsReadBackToItsLine() {
        let row = "  Lib.Cadet — struct — Sources/Lib/Ranks.swift:7 — through typealias Lib.Salute"

        #expect(ExactAnswer.locations(inWhereAnswer: row).map(\.line) == [7])
    }

    /// A class's list is headed by where it came from and claims nothing about indirect conformers, which the store records only as written clauses.
    @Test
    func aClassesListClaimsNoIndirectConformers() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Sergeant", freshness: engine.ensureFresh())

            #expect(output.contains("conformers of Sergeant (1, direct subclasses from the store):\n"), "\(output)")
            #expect(!output.contains("includes indirect"), "\(output)")
        }
    }

    /// A package of the shapes the alias fold met: an alias that only names the protocol, a declaration with an attribute line or a wrapped clause, and protocol, alias and conformer written on one line.
    private static func aliasEdgeFixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-conformer-alias-edge") { root in
            try TestSources.write(manifest, to: "Package.swift", in: root)
            try TestSources.write(
                """
                public protocol Mover {}

                open class Carrier<T> {}

                public typealias Carrying = Carrier<any Mover>

                public final class Porter: Carrying {}

                public typealias Moves = Mover

                @MainActor
                public final class Walker: Moves {}

                public struct Runner:
                    Moves {}
                """,
                to: "Sources/Lib/Movers.swift",
                in: root
            )
            try TestSources.write(
                "public protocol Pacer {}; public typealias Paces = Pacer; public struct Jogger: Paces {}\n",
                to: "Sources/Lib/Pacers.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "alias edge fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// An alias that merely names the protocol (`Carrier<any Mover>`) is not the protocol: its inheritor is not listed, and nothing is marked through it.
    @Test
    func anAliasThatOnlyNamesTheProtocolIsNotFollowed() async throws {
        try await Self.aliasEdgeFixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Mover", freshness: engine.ensureFresh())

            #expect(!output.contains("Porter —"), "\(output)")
            #expect(!output.contains("through typealias Lib.Carrying"), "\(output)")
        }
    }

    /// The alias reference may sit on an attribute line above the row, or on the line after the row's first.
    @Test
    func anAliasReferenceAnywhereInTheHeaderIsListed() async throws {
        try await Self.aliasEdgeFixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Mover", freshness: engine.ensureFresh())

            let rows = output.split(separator: "\n").filter { $0.contains("— through typealias Lib.Moves") }

            #expect(rows.contains { $0.contains("Lib.Walker — class") }, "\(output)")
            #expect(rows.contains { $0.contains("Lib.Runner — struct") }, "\(output)")
        }
    }

    /// A conformance the store records itself, through an alias, is marked through the alias and not indirect.
    @Test
    func aStoreRecordedConformanceThroughAnAliasIsNotCalledIndirect() async throws {
        try await Self.aliasEdgeFixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Pacer", freshness: engine.ensureFresh())

            #expect(output.contains("conformers of Pacer (1: 0 direct, 0 indirect, 1 through a typealias — "), "\(output)")
            #expect(output.contains("Lib.Jogger — struct — Sources/Lib/Pacers.swift:1 — through typealias Lib.Paces"), "\(output)")
            #expect(!output.contains("— indirect"), "\(output)")
        }
    }

    /// A package whose app module declares a protocol of the same name as a library alias of the library's protocol, beside an alias that only constrains its argument to it: each conformer's clause writes the app's protocol, and the library's alias is written only in a member, a nested type's clause or a where clause.
    private static func aliasMentionFixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-conformer-alias-mention") { root in
            try TestSources.write(
                """
                // swift-tools-version: 6.0
                import PackageDescription

                let package = Package(
                    name: "Lib",
                    targets: [.target(name: "Lib"), .target(name: "App", dependencies: ["Lib"])]
                )
                """,
                to: "Package.swift",
                in: root
            )
            try TestSources.write(
                """
                public protocol Beacon {}

                public typealias Lamp = Beacon

                open class Holder<T> {
                    public init() {}
                }

                public typealias Held<T> = Holder<T> where T: Beacon

                public struct Torch: Beacon {}

                public final class Grip: Held<Torch> {}
                """,
                to: "Sources/Lib/Beacons.swift",
                in: root
            )
            try TestSources.write(
                """
                import Lib

                public protocol Lamp {}

                public struct Big<
                    A: Hashable,
                    B: Sendable
                >: Lamp where A: Comparable {
                    public let x: Lib.Lamp? = nil
                }

                public struct Wide: Lamp {
                    public init(_ y: (any Lib.Lamp)?) {}
                }

                public enum Tall: Lamp {
                    case one(any Lib.Lamp)
                }

                public struct Outer: Lamp {
                    public struct Inner: Lib.Lamp {}
                }
                """,
                to: "Sources/App/Lamps.swift",
                in: root
            )
            try TestSources.write(
                """
                import Lib

                public typealias Dim<T> = Lamp where T: Lib.Lamp

                public struct Shade: Dim<Torch> {}
                """,
                to: "Sources/App/Shades.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "alias mention fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// A declaration whose clause writes another protocol of the alias's name is not a conformer through the alias because the alias is written in its first member or a nested type's clause; the nested type, whose own clause writes the alias, is.
    @Test
    func anAliasWrittenOutsideTheOwnClauseIsNotAConformance() async throws {
        try await Self.aliasMentionFixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Beacon", freshness: engine.ensureFresh())

            let listed = ["Big", "Wide", "Tall", "Outer"].filter { output.contains("App.\($0) — ") }

            #expect(listed.isEmpty, "\(listed): \(output)")
            #expect(output.contains("App.Outer.Inner — struct — Sources/App/Lamps.swift:21 — through typealias Lib.Lamp"), "\(output)")
        }
    }

    /// An alias that only constrains its generic argument to the protocol (`Held<T> = Holder<T> where T: Beacon`) does not stand for it, so its inheritor is not listed.
    @Test
    func anAliasWhoseWhereClauseNamesTheProtocolIsNotFollowed() async throws {
        try await Self.aliasMentionFixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Beacon", freshness: engine.ensureFresh())

            #expect(!output.contains("Grip —"), "\(output)")
            #expect(!output.contains("through typealias Lib.Held"), "\(output)")
            #expect(output.contains("  Lib.Torch — struct — Sources/Lib/Beacons.swift:11 — direct"), "\(output)")
        }
    }

    /// An alias whose underlying type is another protocol of an accepted alias's name (`Dim<T> = Lamp where T: Lib.Lamp`, that `Lamp` the app's own) does not stand for the protocol, so its inheritor is not listed.
    @Test
    func anAliasOfAnotherTypeOfTheAcceptedName() async throws {
        try await Self.aliasMentionFixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Beacon", freshness: engine.ensureFresh())

            #expect(!output.contains("Shade —"), "\(output)")
            #expect(!output.contains("through typealias App.Dim"), "\(output)")
        }
    }

    /// A conformer whose file changed since the build and no longer writes the clause the store recorded carries the stale-file label, not an indirect mark; one whose changed file still writes it keeps its mark.
    @Test
    func aConformerWhoseChangedFileDroppedTheClauseIsNotCalledIndirect() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.manifest, to: "Package.swift", in: root)
        try TestSources.write("public protocol Greeter {}\n", to: "Sources/Lib/Greeter.swift", in: root)
        try TestSources.write("public struct Soldier: Greeter {}\n", to: "Sources/Lib/Soldier.swift", in: root)
        try TestSources.write("public struct Medic: Greeter {}\n", to: "Sources/Lib/Medic.swift", in: root)
        try TestSources.write("public struct Nurse: Greeter {}\n", to: "Sources/Lib/Nurse.swift", in: root)
        try TestSources.commitAll(in: root, message: "changed conformer fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write("public struct Medic {}\n", to: "Sources/Lib/Medic.swift", in: root)
        try TestSources.write("// edited\npublic struct Nurse: Greeter {}\n", to: "Sources/Lib/Nurse.swift", in: root)

        let output = try await engine.lookup(symbol: "Greeter", freshness: engine.ensureFresh())

        #expect(output.contains("(3: 2 direct, 0 indirect, 1 in a changed file without its clause — "), "\(output)")
        #expect(output.contains("  Lib.Medic — struct — Sources/Lib/Medic.swift:1  (file changed since last build)\n") || output.hasSuffix("  Lib.Medic — struct — Sources/Lib/Medic.swift:1  (file changed since last build)"), "\(output)")
        #expect(!output.contains("indirect  (file changed"), "\(output)")
        #expect(output.contains("  Lib.Nurse — struct — Sources/Lib/Nurse.swift:2 — direct  (file changed since last build)"), "\(output)")
        #expect(output.contains("  Lib.Soldier — struct — Sources/Lib/Soldier.swift:1 — direct\n"), "\(output)")
    }

    /// A package whose app declares a protocol of the name of a library alias of the library's protocol, with a conformer to each in the app and one in a module that imports only the library.
    private static func resolvedElsewhereFixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-conformer-resolved-elsewhere") { root in
            try TestSources.write(
                """
                // swift-tools-version: 6.0
                import PackageDescription

                let package = Package(
                    name: "Lib",
                    targets: [
                        .target(name: "Lib"),
                        .target(name: "App", dependencies: ["Lib"]),
                        .target(name: "Use", dependencies: ["Lib"]),
                    ]
                )
                """,
                to: "Package.swift",
                in: root
            )
            try TestSources.write("public protocol Beacon {}\n\npublic typealias Lamp = Beacon\n", to: "Sources/Lib/Beacons.swift", in: root)
            try TestSources.write(
                """
                import Lib

                public protocol Lamp {}

                public struct Wide: Lamp {}

                public struct Inner: Lib.Lamp {}
                """,
                to: "Sources/App/Lamps.swift",
                in: root
            )
            try TestSources.write("import Lib\n\npublic struct Model: Lamp {}\n", to: "Sources/Use/Models.swift", in: root)
            try TestSources.commitAll(in: root, message: "resolved elsewhere fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// A clause that writes the protocol's name, which the store resolves to another declaration of that name, is not counted direct and says what the store resolved it to.
    @Test
    func aClauseTheStoreResolvesElsewhereIsNotCountedDirect() async throws {
        try await Self.resolvedElsewhereFixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "App.Lamp", freshness: engine.ensureFresh())

            #expect(output.contains("conformers of Lamp (3: 1 direct, 0 indirect, 2 resolved to another declaration — "), "\(output)")
            #expect(output.contains("  App.Wide — struct — Sources/App/Lamps.swift:5 — direct\n"), "\(output)")
            #expect(output.contains("  App.Inner — struct — Sources/App/Lamps.swift:7 — writes Lamp, which the index store resolves to Lib.Lamp"), "\(output)")
            #expect(output.contains("  Use.Model — struct — Sources/Use/Models.swift:3 — writes Lamp, which the index store resolves to Lib.Lamp"), "\(output)")
            #expect(!output.contains("the index store does not have it"), "\(output)")
        }
    }

    /// The row a clause resolved to another declaration ends on is read back to the line it names.
    @Test
    func theResolvedElsewhereMarkIsReadBackToItsLine() {
        let row = "  Use.Model — struct — Sources/Use/Models.swift:3 — writes Lamp, which the index store resolves to Lib.Lamp"

        #expect(ExactAnswer.locations(inWhereAnswer: row).map(\.line) == [3])
    }
}

extension WhereConformerMarkTests {
    /// A conformer only the store has, in a file changed since the build, keeps its mark wherever the edit moved its clause — down a line, down several, along its line, or below an edited type above it — and carries the stale-file label once its clause was removed.
    @Test
    func aMovedClauseKeepsItsMarkAndADroppedOneIsLabelled() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.manifest, to: "Package.swift", in: root)
        try TestSources.write("public protocol Marker {}\n\npublic typealias Badge = Marker & Sendable\n", to: "Sources/Lib/Marker.swift", in: root)
        try TestSources.write("public struct Pin: Badge {}\n", to: "Sources/Lib/Pin.swift", in: root)
        try TestSources.write("public struct Tag: Badge {}\n", to: "Sources/Lib/Tag.swift", in: root)
        try TestSources.write("public struct Seal: Badge {}\n", to: "Sources/Lib/Seal.swift", in: root)
        try TestSources.write("public struct Pole {}\n\npublic struct Flag: Badge {\n    public init() {}\n}\n", to: "Sources/Lib/Flag.swift", in: root)
        try TestSources.write("public struct Crest: Badge {}\n", to: "Sources/Lib/Crest.swift", in: root)
        try TestSources.commitAll(in: root, message: "moved clause fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write("// edited\npublic struct Pin: Badge {}\n", to: "Sources/Lib/Pin.swift", in: root)
        try TestSources.write("// one\n// two\n// three\npublic struct Tag: Badge {}\n", to: "Sources/Lib/Tag.swift", in: root)
        try TestSources.write("public struct Seal: Sendable, Badge {}\n", to: "Sources/Lib/Seal.swift", in: root)
        try TestSources.write(
            "public struct Pole {\n    public let size = 1\n}\n\npublic struct Flag: Badge {\n    public let size = 1\n    public init() {}\n}\n",
            to: "Sources/Lib/Flag.swift",
            in: root
        )
        try TestSources.write("// edited\npublic struct Crest {}\n", to: "Sources/Lib/Crest.swift", in: root)

        let output = try await engine.lookup(symbol: "Marker", freshness: engine.ensureFresh())

        #expect(output.contains("(5: 0 direct, 4 indirect, 1 in a changed file without its clause — "), "\(output)")
        #expect(output.contains("  Lib.Pin — struct — Sources/Lib/Pin.swift:2 — indirect  (file changed since last build)"), "\(output)")
        #expect(output.contains("  Lib.Tag — struct — Sources/Lib/Tag.swift:4 — indirect  (file changed since last build)"), "\(output)")
        #expect(output.contains("  Lib.Seal — struct — Sources/Lib/Seal.swift:1 — indirect  (file changed since last build)"), "\(output)")
        #expect(output.contains("  Lib.Flag — struct — Sources/Lib/Flag.swift:5-8 — indirect  (file changed since last build)"), "\(output)")
        #expect(output.contains("  Lib.Crest — struct — Sources/Lib/Crest.swift:2  (file changed since last build)"), "\(output)")
    }

    /// A package whose library has an alias of its protocol under the name of the app's protocol: the app has a type conforming to the app's protocol beside an extension of it writing the library's alias, and an unrelated type of the same name conforming to the app's protocol, while a module that imports only the library extends its own type of that name with the alias.
    private static func extendedTypeFixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-conformer-extended-type") { root in
            try TestSources.write(
                """
                // swift-tools-version: 6.0
                import PackageDescription

                let package = Package(
                    name: "Lib",
                    targets: [
                        .target(name: "Lib"),
                        .target(name: "App", dependencies: ["Lib"]),
                        .target(name: "Use", dependencies: ["Lib"]),
                    ]
                )
                """,
                to: "Package.swift",
                in: root
            )
            try TestSources.write("public protocol Beacon {}\n\npublic typealias Lamp = Beacon\n", to: "Sources/Lib/Beacons.swift", in: root)
            try TestSources.write(
                """
                import Lib

                public protocol Lamp {}

                public struct Gear: Lamp {}

                public struct Hub: Lamp {}

                extension Hub: Lib.Lamp {}
                """,
                to: "Sources/App/Lamps.swift",
                in: root
            )
            try TestSources.write("import Lib\n\npublic struct Gear {}\n\nextension Gear: Lamp {}\n", to: "Sources/Use/Gears.swift", in: root)
            try TestSources.commitAll(in: root, message: "extended type fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// An extension whose clause writes the name the store resolves to another declaration is marked so unless the type the store resolves it to extend conforms: another module's type of the same name that conforms does not speak for it.
    @Test
    func anExtensionIsVouchedForOnlyByTheTypeItExtends() async throws {
        try await Self.extendedTypeFixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "App.Lamp", freshness: engine.ensureFresh())

            let rows = output.split(separator: "\n")
            let gear = rows.first { $0.contains("Sources/Use/Gears.swift:5") }
            let hub = rows.first { $0.contains("Sources/App/Lamps.swift:9") }

            #expect(gear?.hasSuffix(" — writes Lamp, which the index store resolves to Lib.Lamp") == true, "\(output)")
            #expect(hub.map { !$0.contains("resolves to") } == true, "\(output)")
            #expect(output.contains("conformers of Lamp (4: 3 direct, 0 indirect, 1 resolved to another declaration — "), "\(output)")
        }
    }
}
