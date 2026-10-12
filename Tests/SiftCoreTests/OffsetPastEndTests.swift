//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A paged answer whose offset skips every item says so in one line naming the count, rather than printing a header and an empty page that reads as an answer.
@Suite(.temporaryDirectories, .serialized)
struct OffsetPastEndTests {
    private static var pastEnd: String {
        "is past the last of"
    }

    private static func write(_ files: [String: String], into root: URL) throws {
        for (path, source) in files {
            try TestSources.write(source, to: path, in: root)
        }
    }

    // MARK: search

    private static func searched(offset: Int) async throws -> String {
        let root = try TemporaryDirectory.make("offset-past-end-search")
        let files = ["Sources/App/A.swift": "struct One {}\nstruct Two {}\n", "Sources/App/B.swift": "struct Three {}\n"]
        try write(files, into: root)
        let enumerator = FileEnumerator(repoRoot: root, config: SiftConfig(), gitListing: { files.keys.sorted() })
        let query = try StructuralQuery("kind:struct")
        let result = await StructuralSearch(repoRoot: root, enumerator: enumerator).run(query)
        return SearchRenderer.render(result: result, query: query, offset: offset)
    }

    @Test
    func searchNamesTheCountWhenTheOffsetIsPastTheEnd() async throws {
        let answer = try await Self.searched(offset: 5000)

        #expect(answer.contains("offset 5000 is past the last of 3 matches — drop offset to see them"))
        #expect(!answer.contains("matches skipped"))
        #expect(!answer.contains("Three"))
    }

    @Test
    func searchAtTheLastMatchStillShowsIt() async throws {
        let answer = try await Self.searched(offset: 2)

        #expect(!answer.contains(Self.pastEnd))
        #expect(answer.contains("(…2 matches skipped)"))
        #expect(answer.contains("Three"))
    }

    // MARK: where --refs, no store

    private static func noStoreRefs(offset: Int) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try write(["Sources/App/Point.swift": "struct Point {}\n", "Sources/App/A.swift": "func a(_ p: Point) {}\n", "Sources/App/B.swift": "func b(_ p: Point) {}\n"], into: root)
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        let options = WhereOptions(includeReferences: true, offset: offset)
        return try await engine.lookup(symbol: "Point", freshness: engine.ensureFresh(), options: options)
    }

    @Test
    func noStoreSweepNamesTheCountWhenTheOffsetIsPastTheEnd() async throws {
        let answer = try await Self.noStoreRefs(offset: 5000)

        #expect(answer.contains("offset 5000 is past the last of 2 files — drop offset to see them"))
        #expect(!answer.contains("file skipped)"))
        #expect(!answer.contains("files skipped)"))
    }

    @Test
    func noStoreSweepAtTheLastFileStillShowsIt() async throws {
        let first = try await Self.noStoreRefs(offset: 0)
        let count = first.components(separatedBy: "Sources/App/").count
        #expect(count > 1)
        let answer = try await Self.noStoreRefs(offset: 1)

        #expect(!answer.contains(Self.pastEnd))
        #expect(answer.contains("Sources/App/"))
    }

    // MARK: member body and cited range

    private static func renderer() throws -> DigestRenderer {
        let root = try TemporaryDirectory.make("offset-past-end-body")
        let body = (0 ..< 70).map { "        let value\($0) = \($0)" }.joined(separator: "\n")
        let store = try TestSources.makeStore()
        let parsed = try TestSources.parsed("struct Long {\n    func run() {\n\(body)\n    }\n}", path: "Sources/Alpha/Long.swift", in: root)
        try store.replaceFiles([parsed]) { _ in ("Alpha", false) }
        return try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
    }

    @Test
    func aMemberBodyOffsetPastTheEndNamesTheBodyLines() throws {
        let answer = try Self.renderer().render(target: "Long.run", options: DigestOptions(offset: 5000))

        #expect(answer.contains("offset 5000 is past the last of 72 body lines — drop offset to see them"))
        #expect(!answer.contains("skipped"))
    }

    @Test
    func aMemberBodyOffsetInsideTheBodyKeepsTheSkippedNoteAndTheRest() throws {
        let answer = try Self.renderer().render(target: "Long.run", options: DigestOptions(offset: 70))

        #expect(!answer.contains(Self.pastEnd))
        #expect(answer.contains("(…70 body lines skipped)"))
        #expect(answer.contains("let value69 = 69"))
    }

    @Test
    func aCitedRangeInsideAMemberWithAnOffsetPastItsEndNamesTheLines() throws {
        let answer = try Self.renderer().render(target: "Sources/Alpha/Long.swift:10-20", options: DigestOptions(offset: 5000))

        #expect(answer.contains("offset 5000 is past the last of 11 body lines — drop offset to see them"))
        #expect(!answer.contains("skipped"))
    }

    // MARK: where --refs, with a store

    private static func builtFixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "offset-past-end-refs") { root in
            try TestSources.write(
                """
                // swift-tools-version: 6.0
                import PackageDescription

                let package = Package(name: "Lib", targets: [.target(name: "Lib")])
                """,
                to: "Package.swift",
                in: root
            )
            try TestSources.write("public struct Marker { public init() {} }\n", to: "Sources/Lib/Marker.swift", in: root)
            try TestSources.write("func first(_ marker: Marker) {}\n", to: "Sources/Lib/First.swift", in: root)
            try TestSources.write("func second(_ marker: Marker) {}\n", to: "Sources/Lib/Second.swift", in: root)
            try TestSources.commitAll(in: root, message: "buildable fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    @Test
    func storeRefsNameTheCountWhenTheOffsetIsPastTheEnd() async throws {
        try await Self.builtFixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()

            let answer = try await engine.lookup(symbol: "Marker", freshness: freshness, options: WhereOptions(includeReferences: true, offset: 5000))

            #expect(answer.contains("offset 5000 is past the last of 2 files — drop offset to see them"))
            #expect(!answer.contains("files skipped)"))
        }
    }

    @Test
    func storeRefsAtTheLastFileStillShowItsLine() async throws {
        try await Self.builtFixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()

            let answer = try await engine.lookup(symbol: "Marker", freshness: freshness, options: WhereOptions(includeReferences: true, offset: 1))

            #expect(!answer.contains(Self.pastEnd))
            #expect(answer.contains("(…1 file skipped)"))
            #expect(answer.contains("Sources/Lib/Second.swift ("))
        }
    }
}
