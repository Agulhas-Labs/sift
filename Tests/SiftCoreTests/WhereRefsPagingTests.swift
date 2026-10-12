//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A paged `where --refs` answer says the unbuilt-mentions line once, on its first page, and says how many macro-generated mentions the sweep set aside.
@Suite(.temporaryDirectories, .serialized)
struct WhereRefsPagingTests {
    /// How many files beyond the first page's cap write `Gizmo`.
    static var spill: Int {
        5
    }

    /// A library of more files naming `Gizmo` than one page lists, and a stray test file outside any built target that names it too.
    static func writePackage(in root: URL) throws {
        try TestSources.write(
            """
            // swift-tools-version:5.9
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [.target(name: "Lib"), .testTarget(name: "LibTests", dependencies: ["Lib"])]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("public struct Gizmo {\n    public init() {}\n}\n", to: "Sources/Lib/Gizmo.swift", in: root)
        for index in 0 ..< WhereRenderer.listCap + spill {
            try TestSources.write("func make\(index)() -> Gizmo {\n    Gizmo()\n}\n", to: "Sources/Lib/Maker\(String(format: "%03d", index)).swift", in: root)
        }
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func reads() {\n    _ = Gizmo()\n}\n", to: "Tests/LibTests/GadgetTests.swift", in: root)
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func strays() {\n    _ = Gizmo()\n}\n", to: "Fixtures/BetaTests.swift", in: root)
    }

    /// The first page carries the line naming the test file the build left out; the page after it does not.
    @Test
    func theUnbuiltMentionsLineIsOnTheFirstPageOnly() async throws {
        let fixture = try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-refs-paging") { root in
            try Self.writePackage(in: root)
            try TestSources.commitAll(in: root, message: "buildable fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        }
        try await fixture.withEngine { engine in
            let freshness = try await engine.ensureFresh()
            let first = try await engine.lookup(symbol: "Gizmo", freshness: freshness, options: WhereOptions(includeReferences: true))
            let second = try await engine.lookup(symbol: "Gizmo", freshness: freshness, options: WhereOptions(includeReferences: true, offset: WhereRenderer.listCap))

            #expect(first.contains("not in the build, mention the name: Fixtures/BetaTests.swift:5"), "\(first)")
            #expect(second.contains("files skipped"), "\(second)")
            #expect(!second.contains("not in the build, mention the name"), "\(second)")
        }
    }

    /// A file written since the build that the store holds no unit for is listed on the first page of a sweep, and a page after it does not repeat the line.
    @Test
    func theNewSinceLastBuildLineIsOnTheFirstPageOnly() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Lib\", targets: [.target(name: \"Lib\")])\n",
            to: "Package.swift",
            in: root
        )
        try TestSources.write("public struct Gizmo {\n    public init() {}\n}\n", to: "Sources/Lib/Gizmo.swift", in: root)
        try TestSources.write("func one() -> Gizmo {\n    Gizmo()\n}\n", to: "Sources/Lib/One.swift", in: root)
        try TestSources.write("func two() -> Gizmo {\n    Gizmo()\n}\n", to: "Sources/Lib/Two.swift", in: root)
        try TestSources.commitAll(in: root, message: "buildable fixture")
        try await TestSources.swiftBuildSuspending(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write("func late() -> Gizmo {\n    Gizmo()\n}\n", to: "Sources/Lib/Late.swift", in: root)
        let freshness = try await engine.ensureFresh()

        let first = try await engine.lookup(symbol: "Gizmo", freshness: freshness, options: WhereOptions(includeReferences: true))
        let second = try await engine.lookup(symbol: "Gizmo", freshness: freshness, options: WhereOptions(includeReferences: true, offset: 1))

        #expect(first.contains("new since last build, not in the store, mention the name: Sources/Lib/Late.swift:1"), "\(first)")
        #expect(second.contains("file skipped"), "\(second)")
        #expect(!second.contains("new since last build, not in the store"), "\(second)")
    }

    /// A file changed since the build is listed by name once, on the page its mark is on, and a page past the last repeats no line of it.
    @Test
    func aChangedFilesByNameLineIsNotRepeatedPastTheLastPage() async throws {
        let (engine, freshness) = try await Self.stalePagedSweep()

        let first = try await engine.lookup(symbol: "Gizmo", freshness: freshness, options: WhereOptions(includeReferences: true))
        let past = try await engine.lookup(symbol: "Gizmo", freshness: freshness, options: WhereOptions(includeReferences: true, offset: 2))

        #expect(first.contains("written since the build, by name: :4"), "\(first)")
        #expect(!past.contains("written since the build, by name"), "\(past)")
    }

    /// A page after the first that shows the changed file's mark places that file's by-name line under it, before the next file's heading.
    @Test
    func aLaterPageThatShowsAChangedFilesMarkPlacesItsByNameLineUnderIt() async throws {
        let (engine, freshness) = try await Self.stalePagedSweep(withASecondChangedFileAfterIt: true)

        let later = try await engine.lookup(symbol: "Gizmo", freshness: freshness, options: WhereOptions(includeReferences: true, offset: 1))

        let rows = later.components(separatedBy: "\n")
        let mark = try #require(rows.firstIndex { $0.contains("Sources/Lib/Two.swift") && $0.contains("(file changed since last build)") }, "\(later)")
        let byName = try #require(rows.firstIndex { $0.contains("written since the build, by name: :4") }, "\(later)")
        let next = try #require(rows.firstIndex { $0.contains("Sources/Lib/Zed.swift") && $0.contains("(file changed since last build)") }, "\(later)")

        #expect(byName > mark, "\(later)")
        #expect(byName < next, "\(later)")
        #expect(rows[mark + 1 ..< byName].allSatisfy { $0.hasPrefix("    ") }, "\(later)")
    }

    /// The not-code heading is printed only where this page lists a row under it.
    @Test
    func aPageWithNoNotCodeRowPrintsNoNotCodeHeading() async throws {
        let (engine, freshness) = try await Self.stalePagedSweep()

        let first = try await engine.lookup(symbol: "Gizmo", freshness: freshness, options: WhereOptions(includeReferences: true))
        let later = try await engine.lookup(symbol: "Gizmo", freshness: freshness, options: WhereOptions(includeReferences: true, offset: 1))

        #expect(first.contains("not code, by written name — 1 file name:"), "\(first)")
        #expect(!later.contains("not code, by written name"), "\(later)")
    }

    /// An engine over two files using `Gizmo`, built, then one rewritten with a use added and a third, untracked, written.
    private static func stalePagedSweep(withASecondChangedFileAfterIt: Bool = false) async throws -> (SiftEngine, Freshness) {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Lib\", targets: [.target(name: \"Lib\")])\n",
            to: "Package.swift",
            in: root
        )
        try TestSources.write("public struct Gizmo {\n    public init() {}\n}\n", to: "Sources/Lib/Gizmo.swift", in: root)
        try TestSources.write("func one() -> Gizmo {\n    Gizmo()\n}\n", to: "Sources/Lib/One.swift", in: root)
        try TestSources.write("func two() -> Gizmo {\n    Gizmo()\n}\n", to: "Sources/Lib/Two.swift", in: root)
        if withASecondChangedFileAfterIt {
            try TestSources.write("func zed() -> Gizmo {\n    Gizmo()\n}\n", to: "Sources/Lib/Zed.swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "buildable fixture")
        try await TestSources.swiftBuildSuspending(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write("func two() -> Gizmo {\n    Gizmo()\n}\nfunc later() -> Gizmo { Gizmo() }\n", to: "Sources/Lib/Two.swift", in: root)
        if withASecondChangedFileAfterIt {
            try TestSources.write("func zed() -> Gizmo {\n    Gizmo()\n}\nfunc extra() -> Gizmo { Gizmo() }\n", to: "Sources/Lib/Zed.swift", in: root)
        }
        try TestSources.write("func late() -> Gizmo {\n    Gizmo()\n}\n", to: "Sources/Lib/Late.swift", in: root)
        return try await (engine, engine.ensureFresh())
    }

    /// The macro-generated storage mention the sweep leaves out is counted in the heading; a sweep with none says nothing of it.
    @Test
    func theHeadingCountsTheGeneratedMentionsSetAside() async throws {
        let macro = try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "semantic-macro-storage") { root in
            try SemanticMacroStorageRefsTests.writePackage(in: root)
            try TestSources.commitAll(in: root, message: "buildable fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
        try await macro.withEngine { engine in
            let sweep = try await engine.lookup(symbol: "Feed", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
            #expect(sweep.contains("references to GizmoCore.Feed (3 in 1 file, 1 more line a macro generated, not listed):"), "\(sweep)")
        }
        let plain = try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-refs-paging") { root in
            try Self.writePackage(in: root)
            try TestSources.commitAll(in: root, message: "buildable fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        }
        try await plain.withEngine { engine in
            let sweep = try await engine.lookup(symbol: "Gizmo", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
            #expect(sweep.contains("references to Lib.Gizmo ("), "\(sweep)")
            #expect(!sweep.contains("macro generated"), "\(sweep)")
        }
    }
}
