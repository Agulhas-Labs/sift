//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The files view of the `--refs` sweep (`where X --files`): the set of files is the one the sweep names, each row says what the file holds, and a page is cut and continued as the sweep's are.
@Suite(.temporaryDirectories, .serialized)
struct WhereRefsFilesTests {
    /// A built package: `Gizmo` declared in its own file, extended in another, used in a third, named in a doc comment, a Markdown note, and a Markdown file called for it.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-refs-files") { root in
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
            try TestSources.write("public struct Gizmo: Sendable {\n    public init() {}\n}\n", to: "Sources/Lib/Gizmo.swift", in: root)
            try TestSources.write("extension Gizmo {\n    public func spin() {}\n}\n", to: "Sources/Lib/Spin.swift", in: root)
            try TestSources.write("public func make() -> Gizmo {\n    Gizmo()\n}\n", to: "Sources/Lib/Make.swift", in: root)
            try TestSources.write("/// Nothing here calls a Gizmo.\npublic let note = 1\n", to: "Sources/Lib/Note.swift", in: root)
            try TestSources.write("# Notes\n\nThe Gizmo is documented here.\n", to: "Docs/Notes.md", in: root)
            try TestSources.write("# Overview\n", to: "Docs/Gizmo.md", in: root)
            try TestSources.commitAll(in: root, message: "refs files fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// A built package whose paths hold a space and a comma, whose `plain()` is called from a file nothing else names it in, whose `shared` two types each declare, and whose `Gadget` has more extensions than a declarations list shows.
    private static func spacedFixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-refs-files-spaced") { root in
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
            try TestSources.write("public struct Gadget {\n    public init() {}\n}\n", to: "Sources/Lib/Gadget.swift", in: root)
            try TestSources.write("public func plain() -> Gadget {\n    Gadget()\n}\n", to: "Sources/Lib/My Dir/Plain.swift", in: root)
            try TestSources.write("public func caller() {\n    _ = plain()\n}\n", to: "Sources/Lib/Caller.swift", in: root)
            try TestSources.write("public struct Alpha {\n    public static let shared = 1\n}\n\npublic struct Beta {\n    public static let shared = 2\n}\n", to: "Sources/Lib/Owners.swift", in: root)
            try TestSources.write("public func total() -> Int {\n    Alpha.shared + Beta.shared\n}\n", to: "Sources/Lib/Total.swift", in: root)
            for index in 1 ... Self.extensionCount {
                try TestSources.write("extension Gadget {\n    func part\(index)() {}\n}\n", to: "Sources/Lib/Parts/Part\(index).swift", in: root)
            }
            try TestSources.write("# Notes\n\nThe Gadget is documented here.\n", to: "Docs/Gadget Notes.md", in: root)
            try TestSources.write("# Old\n", to: "Docs/Gadget, Old.md", in: root)
            try TestSources.commitAll(in: root, message: "spaced refs files fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// A built package: a `Clamp` property wrapper written on a parameter in more files than ``WhereRenderer/listCap`` lists, each also writing `Character`, which the package only extends, and one file writing `Character` on more lines than ``WhereRenderer/lineListCap`` lists.
    private static func namedFixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-refs-files-named") { root in
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
                "@propertyWrapper public struct Clamp {\n    public var wrappedValue: Int\n    public init(wrappedValue: Int) { self.wrappedValue = wrappedValue }\n}\n\nextension Character {\n    public var isKnown: Bool { self == \"!\" }\n}\n",
                to: "Sources/Lib/Clamp.swift",
                in: root
            )
            for index in 1 ... Self.extensionCount {
                try TestSources.write("public func use\(index)(@Clamp _ x: Int) -> Character {\n    Character(\"a\")\n}\n", to: "Sources/Lib/Uses/Use\(index).swift", in: root)
            }
            let marks = (1 ... Self.manyLines).map { "public let mark\($0): Character = \"a\"" }
            try TestSources.write(marks.joined(separator: "\n") + "\n", to: "Sources/Lib/Many.swift", in: root)
            try TestSources.commitAll(in: root, message: "name-matched refs files fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// More lines writing `Character` in one file than ``WhereRenderer/lineListCap`` lists.
    private static var manyLines: Int {
        WhereRenderer.lineListCap + 5
    }

    /// A committed repo with no build, holding `files`.
    private static func unbuilt(_ files: [String: String]) throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        for (path, text) in files {
            try TestSources.write(text, to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "seed")
        return try SiftEngine(directory: root)
    }

    /// More extensions than ``WhereRenderer/listCap`` lists under `declarations`.
    private static var extensionCount: Int {
        WhereRenderer.listCap + 5
    }

    /// The paths a full `--refs` answer names: the declaration rows, the file rows of its blocks, and the `file names:` entries.
    private static func paths(inRefs answer: String) -> Set<String> {
        var found: Set<String> = []
        for line in answer.components(separatedBy: "\n") {
            if line.hasPrefix("  file names: ") {
                found.formUnion(line.dropFirst("  file names: ".count).components(separatedBy: ", ").map { $0.replacingOccurrences(of: " (a lead)", with: "") })
            } else if line.hasPrefix("  "), !line.hasPrefix("   "), let path = line.dropFirst(2).components(separatedBy: " (").first, line.contains(" ("), path.contains(".") {
                found.insert(path)
            } else if line.hasPrefix("  "), let place = line.components(separatedBy: " — ").last, place.contains(".swift:") {
                found.insert(String(place.prefix { $0 != ":" }))
            }
        }
        return found
    }

    /// The paths of a files view's rows.
    private static func paths(inFiles answer: String) -> Set<String> {
        let rows = answer.components(separatedBy: "\n").drop { !$0.hasPrefix("files naming ") }.dropFirst()
        return Set(rows.compactMap(path(ofRow:)))
    }

    /// The path of a files-view row, `  <path> (<counts>)` and a stale file's mark after it: all before the row's last ` (` once the mark is dropped, so a path holding a space or a comma is read whole.
    private static func path(ofRow row: String) -> String? {
        guard row.hasPrefix("  "), !row.hasPrefix("   ") else { return nil }
        var body = Substring(row.dropFirst(2))
        for mark in [OccurrenceState.modifiedSinceBuild, .deleted].compactMap(\.marker) where body.hasSuffix(mark) {
            body = body.dropLast(mark.count)
        }
        guard body.hasSuffix(")"), let open = body.range(of: " (", options: .backwards) else { return nil }
        return String(body[..<open.lowerBound])
    }

    private static func row(_ path: String, in answer: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        try #require(answer.components(separatedBy: "\n").first { Self.path(ofRow: $0) == path }, "no row for \(path) in\n\(answer)", sourceLocation: sourceLocation)
    }

    /// The files view names exactly the paths the full sweep names: the declaration, the extension, the use, the doc comment, the Markdown note and the file called for the type.
    @Test
    func theFilesAreTheOnesTheSweepNames() async throws {
        try await Self.fixture().withEngine { engine in
            let refs = try await engine.lookup(symbol: "Gizmo", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
            let files = try await engine.lookup(symbol: "Gizmo", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true, filesOnly: true))

            let expected: Set = ["Sources/Lib/Gizmo.swift", "Sources/Lib/Spin.swift", "Sources/Lib/Make.swift", "Sources/Lib/Note.swift", "Docs/Notes.md", "Docs/Gizmo.md"]
            #expect(Self.paths(inRefs: refs) == expected, "\(refs)")
            #expect(Self.paths(inFiles: files) == expected, "\(files)\n---\n\(refs)")
            #expect(files.count < refs.count, "\(files)")
        }
    }

    /// Each row says what its file holds: the code lines, `declares` for a declaration or an extension, `not code N`, and `file name` for a file held only by its name.
    @Test
    func rowsCarryTheirCountsAndMarkers() async throws {
        try await Self.fixture().withEngine { engine in
            let files = try await engine.lookup(symbol: "Gizmo", freshness: engine.ensureFresh(), options: WhereOptions(filesOnly: true))

            #expect(files.contains("files naming Lib.Gizmo (6 files: "), "\(files)")
            #expect(try Self.row("Sources/Lib/Gizmo.swift", in: files).contains("declares"), "\(files)")
            #expect(try Self.row("Sources/Lib/Spin.swift", in: files).contains("declares"), "\(files)")
            #expect(try Self.row("Sources/Lib/Make.swift", in: files) == "  Sources/Lib/Make.swift (2)", "\(files)")
            #expect(try Self.row("Sources/Lib/Note.swift", in: files) == "  Sources/Lib/Note.swift (not code 1)", "\(files)")
            #expect(try Self.row("Docs/Notes.md", in: files) == "  Docs/Notes.md (not code 1)", "\(files)")
            #expect(try Self.row("Docs/Gizmo.md", in: files) == "  Docs/Gizmo.md (file name)", "\(files)")
            #expect(!files.contains("declarations ("), "\(files)")
            #expect(!files.contains("used by"), "\(files)")
            #expect(!files.contains("    :"), "\(files)")
        }
    }

    /// The sweep's own answer comes back unchanged where it is not a sweep: `--syntactic` asks for no store.
    @Test
    func aSyntacticAnswerIsTheRefsAnswer() async throws {
        try await Self.fixture().withEngine { engine in
            let refs = try await engine.lookup(symbol: "Gizmo", freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: false, includeReferences: true))
            let files = try await engine.lookup(symbol: "Gizmo", freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: false, includeReferences: true, filesOnly: true))

            #expect(files == refs)
        }
    }

    /// Past the cap a page ends in the sweep's own truncation marker, and the offset it names continues the list.
    @Test
    func aPagePastTheCapIsContinuedByOffset() {
        let collector = WhereFilesCollector()
        for index in 1 ... 5 {
            collector.recordCode(path: "Sources/F\(index).swift", lines: 1 ... index)
        }

        let first = collector.lines(query: "X", kept: [], offset: 0, cap: 2)
        let second = collector.lines(query: "X", kept: [], offset: 2, cap: 2)
        let past = collector.lines(query: "X", kept: [], offset: 9, cap: 2)

        #expect(first.suffix(3) == ["  Sources/F1.swift (1)", "  Sources/F2.swift (2)", "  truncated: 3 more files — pass offset 2 to continue"])
        #expect(second.suffix(4) == ["  (…2 files skipped)", "  Sources/F3.swift (3)", "  Sources/F4.swift (4)", "  truncated: 1 more file — pass offset 4 to continue"])
        #expect(past.last == "  offset 9 is past the last of 5 files — drop offset to see them")
        #expect(WhereFilesCollector.filesListCap == 100)
    }

    /// The heading keeps what the sweep's says of drift and of lines left out, and a line two sections list is counted once.
    @Test
    func theHeadingKeepsTheSweepsCaveats() {
        let collector = WhereFilesCollector()
        collector.recordCode(path: "A.swift", lines: [1, 2, 3])
        collector.recordCode(path: "A.swift", lines: [3, 4], state: .modifiedSinceBuild)
        collector.recordReferenceDetails(siblings: [], generatedLines: 1, heading: "references to Lib.X (4 in 1 file):")

        let lines = collector.lines(query: "X", kept: [], offset: 0)

        #expect(lines.contains("files naming X (1 file: 1 with code sites, 0 with not-code mentions, 1 file changed since last build, 1 more line a macro generated, not listed):"), "\(lines)")
        #expect(lines.last == "  A.swift (4)  (file changed since last build)", "\(lines)")
    }

    /// A path holding a space keeps its row whole, a code file's and a Markdown file's alike, and a `file names:` path holding a comma is one row.
    @Test
    func pathsHoldingSpacesAndCommasAreRowsOfTheirOwn() async throws {
        try await Self.spacedFixture().withEngine { engine in
            let files = try await engine.lookup(symbol: "Gadget", freshness: engine.ensureFresh(), options: WhereOptions(filesOnly: true))

            #expect(try Self.row("Sources/Lib/My Dir/Plain.swift", in: files) == "  Sources/Lib/My Dir/Plain.swift (2)", "\(files)")
            #expect(try Self.row("Docs/Gadget Notes.md", in: files) == "  Docs/Gadget Notes.md (not code 1)", "\(files)")
            #expect(try Self.row("Docs/Gadget, Old.md", in: files) == "  Docs/Gadget, Old.md (file name)", "\(files)")
            #expect(!files.contains("  Sources/Lib/My ("), "\(files)")
        }
    }

    /// Every file declaring the query is marked `declares`, past the declarations list's cap too.
    @Test
    func everyExtensionFileDeclaresPastTheListCap() async throws {
        try await Self.spacedFixture().withEngine { engine in
            let files = try await engine.lookup(symbol: "Gadget", freshness: engine.ensureFresh(), options: WhereOptions(filesOnly: true))

            for index in 1 ... Self.extensionCount {
                #expect(try Self.row("Sources/Lib/Parts/Part\(index).swift", in: files).contains("declares"), "\(files)")
            }
            #expect(try Self.row("Sources/Lib/Gadget.swift", in: files).contains("declares"), "\(files)")
        }
    }

    /// A file whose only line is a call `callers of` lists, which the references block then does not list again, is one of the view's files.
    @Test
    func aFileOnlyCallingTheFunctionIsNamed() async throws {
        try await Self.spacedFixture().withEngine { engine in
            let files = try await engine.lookup(symbol: "plain", freshness: engine.ensureFresh(), options: WhereOptions(filesOnly: true))

            #expect(try Self.row("Sources/Lib/Caller.swift", in: files) == "  Sources/Lib/Caller.swift (1)", "\(files)")
            #expect(try Self.row("Sources/Lib/My Dir/Plain.swift", in: files).contains("declares"), "\(files)")
        }
    }

    /// A name several types declare is headed with every owner, and its declarations stay, since they are what narrows it.
    @Test
    func severalOwnersAreNamedInTheHeading() async throws {
        try await Self.spacedFixture().withEngine { engine in
            let files = try await engine.lookup(symbol: "shared", freshness: engine.ensureFresh(), options: WhereOptions(filesOnly: true))

            #expect(files.contains("files naming shared, 2 owners: Lib.Alpha.shared, Lib.Beta.shared (2 files: "), "\(files)")
            #expect(files.contains("declarations (2):"), "\(files)")
            #expect(try Self.row("Sources/Lib/Total.swift", in: files) == "  Sources/Lib/Total.swift (1)", "\(files)")
        }
    }

    /// A type the package only extends is answered by the lines writing its name; past the file cap (`grep for the name`) and the per-file cap, every file is a row, counting its distinct lines.
    @Test
    func aWrittenNameTypeSweepPastItsCapsListsEveryFile() async throws {
        try await Self.namedFixture().withEngine { engine in
            let refs = try await engine.lookup(symbol: "Character", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
            let files = try await engine.lookup(symbol: "Character", freshness: engine.ensureFresh(), options: WhereOptions(filesOnly: true))

            #expect(refs.contains("grep for the name to list them"), "\(refs)")
            #expect(refs.contains("+\(Self.manyLines - WhereRenderer.lineListCap) more"), "\(refs)")
            for index in 1 ... Self.extensionCount {
                #expect(try Self.row("Sources/Lib/Uses/Use\(index).swift", in: files) == "  Sources/Lib/Uses/Use\(index).swift (2)", "\(files)")
            }
            #expect(try Self.row("Sources/Lib/Many.swift", in: files) == "  Sources/Lib/Many.swift (\(Self.manyLines))", "\(files)")
            #expect(files.contains("by written name"), "\(files)")
        }
    }

    /// A function's calls and unapplied mentions matched by name, with no store, are every one a file of the view, past the name-matched cap.
    @Test
    func aCallerFallbackPastItsCapListsEveryFile() async throws {
        var sources = ["Sources/App/Relay.swift": "func relay() {}\n"]
        for index in 1 ... 8 {
            sources["Sources/App/Call\(index).swift"] = "func call\(index)() {\n    relay()\n}\n"
        }
        for index in 1 ... 3 {
            sources["Sources/App/Handed\(index).swift"] = "let handed\(index) = relay\n"
        }
        let engine = try Self.unbuilt(sources)

        let files = try await engine.lookup(symbol: "relay()", freshness: engine.ensureFresh(), options: WhereOptions(nameMatchedSiteCap: 2, filesOnly: true))

        for index in 1 ... 8 {
            #expect(try Self.row("Sources/App/Call\(index).swift", in: files) == "  Sources/App/Call\(index).swift (1)", "\(files)")
        }
        for index in 1 ... 3 {
            #expect(try Self.row("Sources/App/Handed\(index).swift", in: files) == "  Sources/App/Handed\(index).swift (1)", "\(files)")
        }

        #expect(files.contains("by written name"), "\(files)")
    }

    /// A property wrapper's `@Clamp` sites on parameters, which the store records no call at, are files of its initializer's view, past the call site cap.
    @Test
    func aWrapperAttributeSiteIsAFileOfTheView() async throws {
        try await Self.namedFixture().withEngine { engine in
            let files = try await engine.lookup(symbol: "Clamp.init(wrappedValue:)", freshness: engine.ensureFresh(), options: WhereOptions(filesOnly: true))

            for index in 1 ... Self.extensionCount {
                #expect(try Self.row("Sources/Lib/Uses/Use\(index).swift", in: files) == "  Sources/Lib/Uses/Use\(index).swift (1)", "\(files)")
            }
        }
    }

    /// A type built through an initializer nobody declared is answered with where it is built, and each of those files is a row, its declaring file marked.
    @Test
    func anUndeclaredInitializersSitesAreFilesOfTheView() async throws {
        var sources = ["Sources/App/Box.swift": "struct Box {\n    let x: Int\n}\n"]
        for index in 1 ... 8 {
            sources["Sources/App/Make\(index).swift"] = "let box\(index) = Box(x: \(index))\n"
        }
        let engine = try Self.unbuilt(sources)

        let files = try await engine.lookup(symbol: "Box.init", freshness: engine.ensureFresh(), options: WhereOptions(filesOnly: true))

        for index in 1 ... 8 {
            #expect(try Self.row("Sources/App/Make\(index).swift", in: files) == "  Sources/App/Make\(index).swift (1)", "\(files)")
        }

        #expect(try Self.row("Sources/App/Box.swift", in: files).contains("declares"), "\(files)")
    }

    /// Two overloads of one function are one owner: the heading names it once and the declarations section goes, as it does for any one owner.
    @Test
    func overloadsOfOneFunctionAreOneOwner() async throws {
        let engine = try Self.unbuilt([
            "Sources/App/Relay.swift": "func relay() {}\nfunc relay(_ x: Int) {}\n",
            "Sources/App/Call.swift": "func call() {\n    relay()\n    relay(1)\n}\n",
        ])

        let files = try await engine.lookup(symbol: "relay", freshness: engine.ensureFresh(), options: WhereOptions(filesOnly: true))

        #expect(files.contains("files naming Sources.relay ("), "\(files)")
        #expect(!files.contains("owners:"), "\(files)")
        #expect(!files.contains("declarations (2):"), "\(files)")
    }

    /// Two types of one name that declare no initializer are two owners of `Plain.init`: both are named, and the declarations section stays.
    @Test
    func undeclaredInitializersOfTwoTypesAreTwoOwners() async throws {
        let engine = try Self.unbuilt([
            "Sources/App/Plain.swift": "struct Plain {}\n\nenum NS {\n    struct Plain {}\n}\n",
            "Sources/App/Make.swift": "let one = Plain()\nlet two = NS.Plain()\n",
        ])

        let files = try await engine.lookup(symbol: "Plain.init", freshness: engine.ensureFresh(), options: WhereOptions(filesOnly: true))

        #expect(files.contains("2 owners: "), "\(files)")
        #expect(files.contains("Sources.Plain.init"), "\(files)")
        #expect(files.contains("Sources.NS.Plain.init"), "\(files)")
        #expect(files.contains("declarations (2):"), "\(files)")
    }

    /// A written-name type sweep whose typealias chain runs past the fold cap says, in the heading, that its set is a lower bound, as its dropped verdict did.
    @Test
    func aWrittenNameFoldPastItsCapIsALowerBound() async throws {
        let depth = WhereRenderer.typealiasFoldCap + 4
        let chain = (1 ... depth).map { "typealias Link\($0) = \($0 == 1 ? "Gizmo" : "Link\($0 - 1)")" }.joined(separator: "\n")
        let engine = try Self.unbuilt([
            "Sources/App/Gizmo.swift": "struct Gizmo {}\n",
            "Sources/App/Chain.swift": chain + "\nlet last = Link\(depth)()\n",
        ])

        let files = try await engine.lookup(symbol: "Gizmo", freshness: engine.ensureFresh(), options: WhereOptions(filesOnly: true))

        #expect(files.contains("a lower bound: more typealiases than the \(WhereRenderer.typealiasFoldCap) followed"), "\(files)")
    }
}
