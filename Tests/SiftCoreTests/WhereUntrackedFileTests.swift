//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A file written since the build that the store cites nothing in — a new, untracked file above all — holds sites no store records, so a semantic `where` lists its lines that write the name, labelled as found by name in a changed file, and the header counts it as changed.
@Suite(.temporaryDirectories, .serialized)
struct WhereUntrackedFileTests {
    private static var heading: String {
        "new since last build, not in the store, mention the name: "
    }

    private static var writtenSince: String {
        "written since the build, by name: "
    }

    /// A committed package built with an index store, its repository checked to sit in its own temporary directory before anything is written to it.
    private static func makeBuiltRepo(adding extraFiles: [String: String] = [:], sourceLocation: SourceLocation = #_sourceLocation) async throws -> URL {
        let root = try TestSources.makeTempRepo()
        #expect(try TemporaryDirectory.entries(containing: root.lastPathComponent) == [root.lastPathComponent], sourceLocation: sourceLocation)
        #expect(try URL(fileURLWithPath: TestSources.runGit(["rev-parse", "--show-toplevel"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)).lastPathComponent == root.lastPathComponent, sourceLocation: sourceLocation)
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
            "public struct Gadget {\n    public var idle = 0\n    public init() {}\n}\n\npublic func compute() -> Int {\n    1\n}\n",
            to: "Sources/Lib/Compute.swift",
            in: root
        )
        try TestSources.write("public func first() -> Int {\n    compute()\n}\n", to: "Sources/Lib/First.swift", in: root)
        try TestSources.write("public func second() -> Int {\n    compute()\n}\n", to: "Sources/Lib/Second.swift", in: root)
        try TestSources.write("public func other() -> Int {\n    2\n}\n", to: "Sources/Lib/Other.swift", in: root)
        for (path, source) in extraFiles {
            try TestSources.write(source, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "buildable fixture")
        try await TestSources.swiftBuildSuspending(packageAt: root)
        return root
    }

    /// The new file's call is listed by written name under the function and under its `--refs` sweep, the type it alone uses is listed beside the zero-use verdict, and the header counts the file; a property the file never names gets no line, and its header stays fresh.
    @Test
    func anUntrackedFileWrittenSinceTheBuildIsListedByNameAndCounted() async throws {
        let root = try await Self.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write("public func added() -> Int {\n    _ = Gadget()\n    return compute()\n}\n", to: "Sources/Lib/Depot.swift", in: root)
        #expect(try TestSources.runGit(["status", "--porcelain", "Sources"], in: root).contains("?? Sources/Lib/Depot.swift"))

        let callers = try await engine.lookup(symbol: "compute", freshness: engine.ensureFresh())
        let sweep = try await engine.lookup(symbol: "compute", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
        let type = try await engine.lookup(symbol: "Gadget", freshness: engine.ensureFresh())
        let property = try await engine.lookup(symbol: "Gadget.idle", freshness: engine.ensureFresh())

        for answer in [callers, sweep] {
            #expect(answer.contains("semantic: stale since last build (1 new cited file: Sources/Lib/Depot.swift)"), "\(answer)")
            #expect(answer.contains("callers of Lib.compute() (2):"), "\(answer)")
            #expect(answer.split(separator: "\n").contains("\(Self.heading)Sources/Lib/Depot.swift:3"), "\(answer)")
        }
        #expect(type.contains("semantic: stale since last build (1 new cited file: Sources/Lib/Depot.swift)"), "\(type)")
        #expect(type.contains("no references to Lib.Gadget recorded in the store"), "\(type)")
        #expect(type.split(separator: "\n").contains("\(Self.heading)Sources/Lib/Depot.swift:2"), "\(type)")
        #expect(property.contains("semantic: fresh"), "\(property)")
        #expect(!property.contains(Self.heading), "\(property)")
    }

    /// A file edited since the build that the store holds is never listed for writing the name alone: a new call in a cited file goes under that file's mark, one in a file the answer cites nothing in goes on a line of its own, and the header counts each file once: the two changed ones and the new one.
    @Test
    func aNewCallInAStoredFileIsListedUnderItsMarkAndCounted() async throws {
        let root = try await Self.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write("public func added() -> Int {\n    compute()\n}\n", to: "Sources/Lib/Depot.swift", in: root)
        try TestSources.write("public func first() -> Int {\n    compute()\n}\n\npublic func again() -> Int {\n    compute()\n}\n", to: "Sources/Lib/First.swift", in: root)
        try TestSources.write("public func other() -> Int {\n    compute() + 2\n}\n", to: "Sources/Lib/Other.swift", in: root)

        let callers = try await engine.lookup(symbol: "compute", freshness: engine.ensureFresh())
        let rows = callers.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(callers.contains("semantic: stale since last build (3 cited files: 2 changed, 1 new)"), "\(callers)")
        let mark = try #require(rows.firstIndex(of: "  Sources/Lib/First.swift (1):  (file changed since last build)"), "\(callers)")
        #expect(rows.dropFirst(mark + 1).prefix(2).last == "    written since the build, by name: :6", "\(callers)")
        #expect(rows.contains("\(Self.heading)Sources/Lib/Depot.swift:2"), "\(callers)")
        #expect(rows.contains("changed since last build, written since the build, by name: Sources/Lib/Other.swift:2"), "\(callers)")
    }

    /// A member name written across files edited since the build, in another type's member, a string literal, a local, a loop's tuple pattern, an enum case's pattern and a tuple's label and its access, and in a file only touched, its bytes those the build read, in a closure's parameters, lists none of them and leaves the header fresh.
    @Test
    func aMemberNameCommonAcrossEditedFilesListsNoneOfThem() async throws {
        let root = try await Self.makeBuiltRepo(adding: [
            "Sources/Lib/Row.swift": "public struct Row {\n    public var path = \"\"\n    public init() {}\n}\n",
            "Sources/Lib/WidgetRow.swift": "public func crateData() -> String {\n    Row().path\n}\n",
            "Sources/Lib/Walk.swift": "import Foundation\n\npublic func walk(_ url: URL) -> String {\n    url.path\n}\n",
            "Sources/Lib/Note.swift": "public func note() -> String {\n    \"path\"\n}\n",
            "Sources/Lib/Local.swift": "public func local() -> Int {\n    let path = 1\n    return path\n}\n",
            "Sources/Lib/Zip.swift": "public func zipped() -> String {\n    var out = \"\"\n    for (path, count) in zip([\"a\"], [1]) {\n        out += path + String(count)\n    }\n    return out\n}\n",
            "Sources/Lib/Pair.swift": "public func pair() -> String {\n    let entry = (file: 1, path: \"x\")\n    return entry.path + String(entry.file)\n}\n",
            "Sources/Lib/Kind.swift": "public enum Kind {\n    case file(String)\n\n    public var name: String {\n        switch self {\n        case let .file(path): path\n        }\n    }\n}\n",
            "Sources/Lib/Touched.swift": "public func touched() -> [String] {\n    zip([\"a\"], [1]).map { path, count in path + String(count) }\n}\n",
        ])
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        for name in ["Walk", "Note", "Local", "Zip", "Pair", "Kind"] {
            let file = root.appendingPathComponent("Sources/Lib/\(name).swift")
            try (String(contentsOf: file, encoding: .utf8) + "\npublic func edited\(name)() {}\n").write(to: file, atomically: true, encoding: .utf8)
        }
        let touched = root.appendingPathComponent("Sources/Lib/Touched.swift")
        let built = try String(contentsOf: touched, encoding: .utf8)
        try (built + "// edited\n").write(to: touched, atomically: true, encoding: .utf8)
        _ = try await engine.ensureFresh()
        try built.write(to: touched, atomically: true, encoding: .utf8)

        let property = try await engine.lookup(symbol: "Row.path", freshness: engine.ensureFresh())

        #expect(property.contains("semantic: fresh"), "\(property)")
        #expect(property.contains("Sources/Lib/WidgetRow.swift"), "\(property)")
        #expect(!property.contains("changed since last build"), "\(property)")
        #expect(!property.contains(Self.writtenSince), "\(property)")
    }

    /// A line written above a cited call moves it down, so where a new call is written too, the lines holding more calls than the build recorded on them are given as where the one new call is, never as two written since the build.
    @Test
    func aCitedCallMovedDownIsNotListedAsWrittenSince() async throws {
        let root = try await Self.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write("// moved\npublic func first() -> Int {\n    compute()\n}\n\npublic func again() -> Int {\n    compute()\n}\n", to: "Sources/Lib/First.swift", in: root)

        let callers = try await engine.lookup(symbol: "compute", freshness: engine.ensureFresh())
        let rows = callers.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let mark = try #require(rows.firstIndex(of: "  Sources/Lib/First.swift (1):  (file changed since last build)"), "\(callers)")

        #expect(rows.dropFirst(mark + 1).prefix(2).last == "    \(Self.writtenSince)1 more than the build recorded, among :3, :7", "\(callers)")
    }

    /// A new file writing the name only in a string literal holds no site the store misses, so it is neither listed nor counted, and the header stays fresh.
    @Test
    func aNewFileWritingTheNameOnlyInAStringIsNotListed() async throws {
        let root = try await Self.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write("public func label() -> String {\n    \"compute\"\n}\n", to: "Sources/Lib/Depot.swift", in: root)

        let callers = try await engine.lookup(symbol: "compute", freshness: engine.ensureFresh())

        #expect(callers.contains("semantic: fresh"), "\(callers)")
        #expect(callers.contains("callers of Lib.compute() (2):"), "\(callers)")
        #expect(!callers.contains(Self.heading), "\(callers)")
    }

    /// An extension file edited since the build, whose line the answer folds into the type's own, and a refused file declaring an overload, which gained a call, are listed on no line of their own.
    @Test
    func anExtensionFileAndARefusedFileAreNotListedAgain() async throws {
        let root = try await Self.makeBuiltRepo(adding: [
            "Sources/Lib/CrateSet.swift": "extension Gadget {\n    public func spin() {}\n}\n",
            "Sources/Lib/Overload.swift": "public func compute(_ value: Int) -> Int {\n    value\n}\n",
        ])
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write("extension Gadget {\n    public func spin() {}\n\n    public func turn() {}\n}\n", to: "Sources/Lib/CrateSet.swift", in: root)
        try TestSources.write("public func compute(_ value: Int) -> Int {\n    value\n}\n\npublic func more() -> Int {\n    compute()\n}\n", to: "Sources/Lib/Overload.swift", in: root)

        let type = try await engine.lookup(symbol: "Gadget", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
        let function = try await engine.lookup(symbol: "compute", freshness: engine.ensureFresh())

        #expect(type.contains("Sources/Lib/CrateSet.swift"), "\(type)")
        #expect(function.contains("Sources/Lib/Overload.swift"), "\(function)")
        for answer in [type, function] {
            let labelled = answer.split(separator: "\n").filter { $0.contains(Self.heading) || $0.contains(Self.writtenSince) }
            #expect(labelled.isEmpty, "\(answer)")
        }
    }

    /// A bare name two unrelated types declare is answered with counts alone, so a new file calling one of them has its line listed after them and counted in the header, which no longer says fresh.
    @Test
    func aNewCallerOfOneOfSeveralOwnersIsListedAndCounted() async throws {
        let root = try await Self.makeBuiltRepo(adding: [
            "Sources/Lib/Owners.swift": "public struct Widget {\n    public init() {}\n    public func make() -> Int { 1 }\n}\n\npublic struct Gizmo {\n    public init() {}\n    public func make() -> Int { 2 }\n}\n",
        ])
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write("public func crateData() -> Int {\n    Gizmo().make()\n}\n", to: "Sources/Lib/GizmoTools.swift", in: root)

        let answer = try await engine.lookup(symbol: "make", freshness: engine.ensureFresh())

        #expect(answer.contains("under 2 owners"), "\(answer)")
        #expect(answer.contains("semantic: stale since last build (1 new cited file: Sources/Lib/GizmoTools.swift)"), "\(answer)")
        #expect(answer.split(separator: "\n").contains("\(Self.heading)Sources/Lib/GizmoTools.swift:2"), "\(answer)")
    }
}
