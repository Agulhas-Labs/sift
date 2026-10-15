//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A type whose extensions outnumber the declarations semantic relations are resolved for, in files that sort before the type's own, keeps its references, pinned on a real build.
@Suite(.temporaryDirectories, .serialized)
struct WhereManyExtensionsRefsTests {
    /// How many extensions of `Gizmo` the fixture writes, each in a file sorting before `Z_Gizmo.swift`.
    static var extensionCount: Int {
        8
    }

    /// How many overloads of `Depot.stack` the fixture writes.
    static var overloadCount: Int {
        7
    }

    /// The parameter types of `Crate.load(_:)`'s overloads, which differ in nothing else.
    static var loadedTypes: [String] {
        ["Int", "String", "Double", "Bool", "Float", "Character", "[Int]"]
    }

    /// A library whose `Gizmo` is declared in the last file and extended in eight before it, a `Depot` with more overloads of one method than the cap, a `Crate` and a `Hoard` whose overloads share one qualified name, the second more than one answer resolves, an extension of Foundation's `Date` beside five functions of that name, a `Gadget` extended five times and declared in a second library too, and a test target using them.
    static func writePackage(in root: URL) throws {
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Gizmo",
                platforms: [.macOS(.v14)],
                targets: [
                    .target(name: "GizmoCore"),
                    .target(name: "OrchardApp"),
                    .testTarget(name: "GizmoTests", dependencies: ["GizmoCore"]),
                ]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("public struct Gizmo {\n    public init() {}\n}\n", to: "Sources/GizmoCore/Z_Gizmo.swift", in: root)
        for index in 1 ... extensionCount {
            try TestSources.write("extension Gizmo {\n    func spin\(index)() {}\n}\n", to: "Sources/GizmoCore/A\(index).swift", in: root)
        }
        let overloads = (0 ..< overloadCount).map { "    public func stack(a\($0): Int) {}" }.joined(separator: "\n")
        try TestSources.write("public struct Depot {\n    public init() {}\n\(overloads)\n}\n", to: "Sources/GizmoCore/Depot.swift", in: root)
        try writeSameNameOverloads(in: root)
        try writeDateAndGadget(in: root)
        try TestSources.write(
            """
            import GizmoCore
            import Testing

            @Test func makeGizmo() {
                _ = Gizmo()
                Depot().stack(a6: 1)
                Crate().load(1)
                Crate().load("one")
                _ = Gadget()
            }

            func Date(a1: Int) {}
            func Date(a2: Int) {}
            func Date(a3: Int) {}
            func Date(a4: Int) {}
            func Date(a5: Int) {}
            """,
            to: "Tests/GizmoTests/GizmoTests.swift",
            in: root
        )
    }

    /// A `Crate` whose `load(_:)` overloads differ only in parameter type, and a `Hoard` with one more `keep(_:)` overload than one answer resolves.
    static func writeSameNameOverloads(in root: URL) throws {
        let loads = loadedTypes.map { "    public func load(_ value: \($0)) {}" }.joined(separator: "\n")
        try TestSources.write("public struct Crate {\n    public init() {}\n\(loads)\n}\n", to: "Sources/GizmoCore/Crate.swift", in: root)
        let kept = (1 ... WhereRenderer.listCap + 1).map { "public struct Kept\($0) {}" }.joined(separator: "\n")
        let keeps = (1 ... WhereRenderer.listCap + 1).map { "    func keep(_ value: Kept\($0)) {}" }.joined(separator: "\n")
        try TestSources.write("\(kept)\nstruct Hoard {\n\(keeps)\n}\n", to: "Sources/GizmoCore/Hoard.swift", in: root)
    }

    /// An extension of Foundation's `Date`, which no file declares, and a line writing it; and a `Gadget` declared in each library and extended five times in the first, in files sorting before its own.
    static func writeDateAndGadget(in root: URL) throws {
        try TestSources.write("import Foundation\n\nextension Date {\n    var stamp: Int { 0 }\n}\n", to: "Sources/GizmoCore/Stamp.swift", in: root)
        try TestSources.write("import Foundation\n\npublic func started() -> Date {\n    Date()\n}\n", to: "Sources/GizmoCore/Started.swift", in: root)
        try TestSources.write("public struct Gadget {\n    public init() {}\n}\n", to: "Sources/GizmoCore/Z_Gadget.swift", in: root)
        for index in 1 ... 5 {
            try TestSources.write("extension Gadget {\n    func turn\(index)() {}\n}\n", to: "Sources/GizmoCore/B\(index).swift", in: root)
        }
        try TestSources.write("public struct Gadget {\n    public init() {}\n}\n", to: "Sources/OrchardApp/Gadget.swift", in: root)
        try writeLateCalendarExtension(in: root)
    }

    /// Five functions named `Calendar` in the first module, and an extension of Foundation's `Calendar` in a file of the second, which sorts after them, with a line writing the name there.
    static func writeLateCalendarExtension(in root: URL) throws {
        let functions = (1 ... 5).map { "public func Calendar(a\($0): Int) {}" }.joined(separator: "\n")
        try TestSources.write("\(functions)\n", to: "Sources/GizmoCore/A9.swift", in: root)
        try TestSources.write("import Foundation\n\nextension Calendar {\n    var stamp: Int { 0 }\n}\n", to: "Sources/OrchardApp/Z9.swift", in: root)
        try TestSources.write("import Foundation\n\nfunc current() -> Calendar {\n    Calendar.current\n}\n", to: "Sources/OrchardApp/Current.swift", in: root)
        try TestSources.write("func fill() {\n    Hoard().keep(Kept\(WhereRenderer.listCap + 1)())\n}\n", to: "Sources/GizmoCore/Fill.swift", in: root)
    }

    /// Runs `body` with the engine over the package every test here shares, built once for the suite, and the freshness it reports.
    static func withBuiltEngine(_ body: (SiftEngine, Freshness) async throws -> Void) async throws {
        let fixture = try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "many-extensions-refs") { root in
            try writePackage(in: root)
            try TestSources.commitAll(in: root, message: "buildable fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        }
        try await fixture.withEngine { engine in
            try await engine.awaitSemanticStore()
            try await body(engine, engine.ensureFresh())
        }
    }

    /// Eight extensions sorting ahead of the struct took every place the cap gives, so the struct was never asked for its references: a test's use of the type left the answer, with no usage line, and the only trace was the cap's note.
    @Test
    func aTypeExtendedInFilesSortingBeforeItKeepsItsReferences() async throws {
        try await Self.withBuiltEngine { engine, freshness in
            let sweep = try await engine.lookup(symbol: "Gizmo", freshness: freshness, options: WhereOptions(includeReferences: true))
            let answer = try await engine.lookup(symbol: "Gizmo", freshness: freshness)

            #expect(sweep.contains("Sources/GizmoCore/A1.swift:1"))
            #expect(sweep.contains("references to GizmoCore.Gizmo"))
            #expect(sweep.contains("Tests/GizmoTests/GizmoTests.swift (1):\n    :5  makeGizmo()  | _ = Gizmo()"))
            #expect(sweep.contains("used by GizmoCore.Gizmo: 1 reference in 1 file — 0 production · 1 test"))
            #expect(answer.contains("used by GizmoCore.Gizmo: 1 reference in 1 file — 0 production · 1 test"))
            #expect(!sweep.contains("semantic relations resolved for the first"))
            #expect(!answer.contains("semantic relations resolved for the first"))
        }
    }

    /// A declaration past the cap is named in the cap's note, with how to have it resolved, and asking for it by that name resolves it.
    @Test
    func theCapNamesWhatItLeftOutAndHowToResolveIt() async throws {
        try await Self.withBuiltEngine { engine, freshness in
            let answer = try await engine.lookup(symbol: "Depot.stack", freshness: freshness)
            let named = try await engine.lookup(symbol: "Depot.stack(a6:)", freshness: freshness)

            #expect(answer.contains("(semantic relations resolved for the first 5 declarations only — not for GizmoCore.Depot.stack(a5:), GizmoCore.Depot.stack(a6:); ask `where` of one by its qualified name to resolve it)"))
            #expect(named.contains("callers of GizmoCore.Depot.stack(a6:)"))
        }
    }

    /// Overloads differing only in parameter type share one qualified name, so no query narrows to one: the cap resolves the whole set, and the calls of each are listed.
    @Test
    func anOverloadSetIsNeverSplitByTheCap() async throws {
        try await Self.withBuiltEngine { engine, freshness in
            let sweep = try await engine.lookup(symbol: "Crate.load", freshness: freshness, options: WhereOptions(includeReferences: true))

            #expect(sweep.contains(":7  makeGizmo()  | Crate().load(1)"))
            #expect(sweep.contains(":8  makeGizmo()  | Crate().load(\"one\")"))
            #expect(!sweep.contains("semantic relations resolved for the first"))
        }
    }

    /// A set larger than one answer resolves leaves some of it out, given by file and line, with no remedy that would only return the same answer.
    @Test
    func anOverloadSetPastTheCeilingIsGivenByFileAndLine() async throws {
        try await Self.withBuiltEngine { engine, freshness in
            let answer = try await engine.lookup(symbol: "Hoard.keep", freshness: freshness)
            let ceiling = WhereRenderer.listCap

            #expect(answer.contains("(semantic relations resolved for the first \(ceiling) declarations only — not for the overloads at Sources/GizmoCore/Hoard.swift:\(2 * ceiling + 3), past the \(ceiling) one answer resolves; they share a qualified name with the rest of their set, so no query narrows to them, but `--refs` lists their call sites by written name)"))
            #expect(!answer.contains("ask `where` of one by its qualified name"))
            #expect(!answer.contains("Hoard().keep(Kept\(ceiling + 1)())"))
        }
    }

    /// The call site of the overload past the ceiling is listed under `--refs`, by written name, and the note says where.
    @Test
    func anOverloadPastTheCeilingHasItsCallSitesListedByWrittenNameUnderRefs() async throws {
        try await Self.withBuiltEngine { engine, freshness in
            let sweep = try await engine.lookup(symbol: "Hoard.keep", freshness: freshness, options: WhereOptions(includeReferences: true))
            let ceiling = WhereRenderer.listCap

            #expect(sweep.contains("Hoard().keep(Kept\(ceiling + 1)())"))
            #expect(sweep.contains("their call sites are listed below by written name)"))
            // The block opens on its count line, so a reader partitioning the answer finds the site among those matched by written name.
            #expect(sweep.contains("\"keep\" (1 call site by written name in 1 file"))
            #expect(!NameMatchedSites.linesOutside(answer: sweep).contains { $0.contains("Hoard().keep(Kept\(ceiling + 1)())") })
        }
    }

    /// An extension of an undeclared type sorting after the functions that fill the places is still answered by the lines writing the name, and the note does not send the reader to a query that returns the same answer.
    @Test
    func anExtensionOfAnUndeclaredTypeSortingAfterTheFunctionsStillLoopsNowhere() async throws {
        try await Self.withBuiltEngine { engine, freshness in
            let answer = try await engine.lookup(symbol: "Calendar", freshness: freshness)

            #expect(answer.contains("Sources/OrchardApp/Z9.swift"))
            #expect(answer.contains("\"Calendar\" (3 uses by written name in 2 files)"))
            #expect(answer.contains("(for OrchardApp.Calendar)"))
            #expect(!answer.contains("semantic relations resolved for the first"))
        }
    }

    /// An extension of a type no file declares answers for itself, by the lines writing the name it extends, so five functions of that name do not push it out of the answer unnamed.
    @Test
    func anExtensionOfAnUndeclaredTypeKeepsItsPlace() async throws {
        try await Self.withBuiltEngine { engine, freshness in
            let answer = try await engine.lookup(symbol: "Date", freshness: freshness)

            #expect(answer.contains("for GizmoCore.Date"))
            #expect(answer.contains("(for GizmoCore.Date)"))
            #expect(!answer.contains("semantic relations resolved for the first"))
        }
    }

    /// Five extensions of a type two libraries declare no longer leave both declarations uncounted: the declarations counted are the ones the cap picks, not the first five listed.
    @Test
    func severalOwnersCountTheDeclarationsTheCapPicks() async throws {
        try await Self.withBuiltEngine { engine, freshness in
            let answer = try await engine.lookup(symbol: "Gadget", freshness: freshness)

            #expect(answer.contains("GizmoCore.Gadget — struct"))
            #expect(answer.contains("OrchardApp.Gadget — struct"))
            #expect(!answer.contains("uses not counted — past the first"))
        }
    }
}
