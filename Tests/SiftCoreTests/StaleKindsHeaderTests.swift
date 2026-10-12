//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The stale header counts distinct cited files by kind, in the order changed, deleted, new, naming the file only where it counts one; section headings count their marked rows in the same order, and a partial build's skipped module is named in a note.
@Suite(.temporaryDirectories)
struct StaleKindsHeaderTests {
    /// Every singular, plural and mixed form, the parts in the order changed, deleted, new.
    @Test
    func everyFormRendersInOrder() {
        let forms: [(StaleFiles, String)] = [
            (StaleFiles(changed: 1, path: "Sources/A.swift"), "1 file changed: Sources/A.swift"),
            (StaleFiles(deleted: 1, path: "Sources/A.swift"), "1 file deleted: Sources/A.swift"),
            (StaleFiles(new: 1, path: "Sources/A.swift"), "1 new file: Sources/A.swift"),
            (StaleFiles(changed: 3), "3 files changed"),
            (StaleFiles(deleted: 2), "2 files deleted"),
            (StaleFiles(new: 2), "2 new files"),
            (StaleFiles(changed: 1, deleted: 1, new: 2), "4 files: 1 changed, 1 deleted, 2 new"),
            (StaleFiles(changed: 2, new: 1), "3 files: 2 changed, 1 new"),
            (StaleFiles(deleted: 1, new: 1), "2 files: 1 deleted, 1 new"),
        ]
        for (files, detail) in forms {
            #expect(SemanticAxis.stale(files).rendered == "stale since last build (\(detail))")
        }
    }

    /// The fold names a path where one file is counted and never where two are, whichever kinds they are.
    @Test
    func theFoldNamesOnePathAndNeverTwo() {
        let one = StaleFiles(["Sources/A.swift": .new])
        let two = StaleFiles(["Sources/A.swift": .changed, "Sources/B.swift": .deleted])

        #expect(one.rendered == "1 new file: Sources/A.swift")
        #expect(two.rendered == "2 files: 1 changed, 1 deleted")
        #expect(StaleFiles(changed: 2, path: "Sources/A.swift").path == nil)
        #expect(StaleFiles(changed: 1, path: "Sources/A.swift").addingChanged(["Sources/B.swift"]).rendered == "2 files changed")
    }

    /// A file found under two kinds, as two stores citing it can find it, is counted once, under the worse kind.
    @Test
    func aFileFoundUnderTwoKindsIsCountedOnceUnderTheWorse() {
        let refusal = SemanticRefusal(path: "Sources/A.swift", reason: .newSinceBuild, symbol: "a()", kind: .function)

        let counted = SemanticAxis.countedFiles(refusals: [refusal], occurrences: [], listedByName: ["Sources/A.swift": .changed, "Sources/B.swift": .deleted])

        #expect(counted == ["Sources/A.swift": .changed, "Sources/B.swift": .deleted])
        #expect(SemanticAxis.of(refusals: [refusal], occurrences: [], listedByName: ["Sources/A.swift": .changed]).rendered == "stale since last build (1 file changed: Sources/A.swift)")
    }

    /// The design's one-changed-file header, from a caller edited since a full build, with its marked row after the current one under a heading counting it, and no note.
    @Test
    func oneChangedCallerIsNamedAndItsRowSortsLast() async throws {
        let root = try await Self.builtPackage()
        try TestSources.write("func record() {\n    Model().load()\n    Model().load()\n}\n", to: "Sources/App/RecordListView.swift", in: root)

        let output = try await Self.lookup("Model.load", in: root)

        #expect(output.contains("semantic: stale since last build (1 file changed: Sources/App/RecordListView.swift)"), "\(output)")
        let heading = try #require(output.split(separator: "\n").firstIndex { $0.hasPrefix("callers of") })
        let rows = output.split(separator: "\n").dropFirst(heading)
        #expect(rows.first?.hasSuffix("(3, 1 file changed since last build):") == true, "\(output)")
        let marked = try #require(rows.firstIndex { $0.contains("RecordListView.swift") })
        let current = try #require(rows.firstIndex { $0.contains("Sources/Other.swift") })
        #expect(current < marked, "\(output)")
        #expect(!output.contains("not compiled by the last build"), "\(output)")
    }

    /// The design's one-deleted-file header, from a caller deleted since the build.
    @Test
    func oneDeletedCallerIsNamed() async throws {
        let root = try await Self.builtPackage()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/A.swift"))

        let output = try await Self.lookup("Model.load", in: root)

        #expect(output.contains("semantic: stale since last build (1 file deleted: Sources/A.swift)"), "\(output)")
    }

    /// The design's one-new-file header, from a declaration in a file no build has compiled: it is counted new, not changed.
    @Test
    func aDeclarationInANewFileIsCountedNew() async throws {
        let root = try await Self.builtPackage(callingFromA: false)
        try TestSources.write("func fresh() {\n    Model().load()\n}\n", to: "Sources/A.swift", in: root)

        let output = try await Self.lookup("fresh", in: root)

        #expect(output.contains("semantic: stale since last build (1 new file: Sources/A.swift)"), "\(output)")
    }

    /// The design's mixed header: a changed caller, a deleted one and two new files writing the call, the total first.
    @Test
    func severalKindsAreCountedWithTheirTotalFirst() async throws {
        let root = try await Self.builtPackage()
        try TestSources.write("func record() {\n    Model().load()\n    Model().load()\n}\n", to: "Sources/App/RecordListView.swift", in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/A.swift"))
        try TestSources.write("func later() {\n    Model().load()\n}\n", to: "Sources/New1.swift", in: root)
        try TestSources.write("func later2() {\n    Model().load()\n}\n", to: "Sources/New2.swift", in: root)

        let output = try await Self.lookup("Model.load", in: root)

        #expect(output.contains("semantic: stale since last build (4 files: 1 changed, 1 deleted, 2 new)"), "\(output)")
    }

    /// A new file writing the name only in a string is neither listed nor counted.
    @Test
    func aNameWrittenOnlyInAStringIsNeitherListedNorCounted() async throws {
        let root = try await Self.builtPackage()
        try TestSources.write("let label = \"Model().load()\"\n", to: "Sources/New1.swift", in: root)

        let output = try await Self.lookup("Model.load", in: root)

        #expect(output.contains("semantic: fresh"), "\(output)")
        #expect(!output.contains("New1.swift"), "\(output)")
    }

    /// A caller a later build of another target skipped is counted changed and its module named in the note; after a full build there is no note.
    @Test
    func theNotCompiledNoteFollowsAPartialBuildOnly() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        try TestSources.write(
            "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Fixture\", targets: [.target(name: \"Alpha\"), .target(name: \"Beta\", dependencies: [\"Alpha\"])])\n",
            to: "Package.swift",
            in: root
        )
        try TestSources.write("public struct Alpha {\n    public init() {}\n    public func ping() {}\n}\n", to: "Sources/Alpha/Alpha.swift", in: root)
        try TestSources.write("import Alpha\n\npublic func beta() {\n    Alpha().ping()\n}\n", to: "Sources/Beta/Beta.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        try await TestSources.swiftBuildSuspending(packageAt: root)
        try TestSources.write("import Alpha\n\npublic func beta() {\n    Alpha().ping()\n}\n// edited\n", to: "Sources/Beta/Beta.swift", in: root)

        let afterFull = try await Self.lookup("Alpha.ping", in: root)
        try TestSources.write("public struct Alpha {\n    public init() {}\n    public func ping() {}\n}\n// rebuilt\n", to: "Sources/Alpha/Alpha.swift", in: root)
        try await TestSources.swiftBuildSuspending(packageAt: root, arguments: ["--target", "Alpha"])
        let afterPartial = try await Self.lookup("Alpha.ping", in: root)

        #expect(afterFull.contains("semantic: stale since last build (1 file changed: Sources/Beta/Beta.swift)"), "\(afterFull)")
        #expect(!afterFull.contains("not compiled by the last build"), "\(afterFull)")
        #expect(afterPartial.contains("semantic: stale since last build (1 file changed: Sources/Beta/Beta.swift)"), "\(afterPartial)")
        #expect(afterPartial.contains("\nnot compiled by the last build: Beta — build it for current rows"), "\(afterPartial)")
    }
}

private extension StaleKindsHeaderTests {
    /// A one-target package whose `Model.load` is called from `Sources/Other.swift`, `Sources/App/RecordListView.swift` and, where asked, `Sources/A.swift`, built whole.
    static func builtPackage(callingFromA: Bool = true) async throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(".build/\n", to: ".gitignore", in: root)
        try TestSources.write(
            "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Fixture\", targets: [.target(name: \"App\", path: \"Sources\")])\n",
            to: "Package.swift",
            in: root
        )
        try TestSources.write("struct Model {\n    func load() {}\n}\n", to: "Sources/Model.swift", in: root)
        if callingFromA {
            try TestSources.write("func a() {\n    Model().load()\n}\n", to: "Sources/A.swift", in: root)
        }
        try TestSources.write("func other() {\n    Model().load()\n}\n", to: "Sources/Other.swift", in: root)
        try TestSources.write("func record() {\n    Model().load()\n}\n", to: "Sources/App/RecordListView.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        try await TestSources.swiftBuildSuspending(packageAt: root)
        return root
    }

    /// `where` for `symbol` in `root`, once the store has loaded.
    static func lookup(_ symbol: String, in root: URL) async throws -> String {
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.lookup(symbol: symbol, freshness: freshness)
    }
}
