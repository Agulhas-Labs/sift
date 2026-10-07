//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A `where` answer says each thing once: a declaration's signature in its `declarations` list, a refused file in one line, and each file of a name-matched block in one heading with its sites under it.
@Suite(.temporaryDirectories)
struct WhereAnswerRepetitionTests {
    /// An answer's name-matched rows as they were written before files were grouped and folded, `  path:line  in X` one site a line, so a test about which sites are listed reads the same whatever the grouping — a row folded onto several lines expands back into one reconstructed line per number, and a number carrying a `(×N)` count expands back into N reconstructed lines, one per site it stands for.
    ///
    /// The source text a row ends with, after its `  | ` bar, is dropped, since which sites are listed is the question.
    static func sitesOnePerLine(_ answer: String) -> String {
        var heading: (indent: Substring, path: Substring)?
        var lines: [String] = []
        for line in answer.split(separator: "\n", omittingEmptySubsequences: false) {
            if let match = line.wholeMatch(of: #/( +)(\S.*\.swift):/#) {
                heading = (match.output.1, match.output.2)
                continue
            }
            if let heading, let match = line.wholeMatch(of: #/ +((?::\d+(?: \(×\d+\))?(?:, )?)+)(  .*?)(?:  \| .*)?/#) {
                for entry in match.output.1.split(separator: ", ") {
                    if let counted = entry.wholeMatch(of: #/(:\d+) \(×(\d+)\)/#) {
                        let repeatCount = Int(counted.output.2) ?? 1
                        for _ in 0 ..< repeatCount {
                            lines.append("\(heading.indent)\(heading.path)\(counted.output.1)\(match.output.2)")
                        }
                    } else {
                        lines.append("\(heading.indent)\(heading.path)\(entry)\(match.output.2)")
                    }
                }
                continue
            }
            heading = nil
            lines.append(String(line))
        }
        return lines.joined(separator: "\n")
    }

    /// A type with two initializers, called three times in one file and once in another, asked with no store.
    private static func initializerAnswer() async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            "struct Box {\n    init() {}\n    init(width: Int, height: Int) {}\n}\n",
            to: "Sources/App/Box.swift",
            in: root
        )
        try TestSources.write(
            "func make() {\n    _ = Box()\n    _ = Box(width: 1, height: 2)\n    _ = Box()\n}\n",
            to: "Sources/App/Uses.swift",
            in: root
        )
        try TestSources.write("func other() {\n    _ = Box()\n}\n", to: "Sources/App/Other.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: "Box.init", freshness: engine.ensureFresh())
    }

    /// A refused answer prints each signature once, in the declarations list, and its refusal as one line naming none of them.
    @Test
    func aRefusedAnswerNamesEachDeclarationOnce() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write(
            """
            open class Base {
                public init() {}
                public init(width: Int, height: Int) {}
                open func greet() {}
            }

            public class Child: Base {
                override public func greet() {}
            }

            func sized() -> Base { Base(width: 1, height: 2) }
            """,
            to: "Sources/Lib/Base.swift",
            in: root
        )

        let output = try await engine.lookup(symbol: "Base.init", freshness: engine.ensureFresh())

        #expect(output.contains("declarations (2):"), "\(output)")
        #expect(output.components(separatedBy: "Lib.Base.init(width:height:)").count == 2, "\(output)")
        #expect(output.components(separatedBy: "Lib.Base.init()").count == 2, "\(output)")
        let refused = output.split(separator: "\n").filter { $0.hasPrefix("semantic REFUSED") }
        #expect(refused == ["semantic REFUSED — changed since the last build; rebuild with `sift run -- swift build`, then retry"], "\(output)")
        #expect(output.contains("in 2 files — for both):"), "\(output)")
    }

    /// Each file of a name-matched block is named once, indented under the name, with its sites indented under it by line.
    @Test
    func nameMatchedSitesAreGroupedUnderTheirFile() async throws {
        let output = try await Self.initializerAnswer()

        #expect(output.contains("\"Box.init\" (4 call sites in 2 files — for both):\n  Sources/App/Other.swift:\n    :2  in other()  | _ = Box()\n  Sources/App/Uses.swift:\n    :2  in make()  | _ = Box()\n    :3  in make()  | _ = Box(width: 1, height: 2)\n    :4  in make()  | _ = Box()"), "\(output)")
        #expect(output.components(separatedBy: "Uses.swift").count == 2, "\(output)")
        #expect(!output.contains("init(width:height:)):"), "\(output)")
    }

    /// Grouping keeps every heading and row inside the block, so a file only the block names is never read back as one the answer located.
    @Test
    func groupedRowsStayOutsideWhatTheAnswerLocated() async throws {
        let output = try await Self.initializerAnswer()

        let outside = NameMatchedSites.linesOutside(answer: output).joined(separator: "\n")

        #expect(outside.contains("Sources/App/Box.swift:2"), "\(outside)")
        #expect(!outside.contains("Uses.swift"), "\(outside)")
        #expect(!outside.contains("Other.swift"), "\(outside)")
        #expect(ExactAnswer.locations(inWhereAnswer: output).allSatisfy { $0.path == "Sources/App/Box.swift" })
    }

    /// The places a name is written with no call are grouped too, and indented so the block runs through them.
    @Test
    func aNameWrittenWithNoCallStaysInsideTheBlock() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("enum Greeter {\n    static func greeting() -> String { \"hi\" }\n}\n", to: "Sources/App/Greeter.swift", in: root)
        try TestSources.write("func hand() {\n    let f = Greeter.greeting\n    _ = f\n}\n", to: "Sources/App/Hand.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)

        let output = try await engine.lookup(symbol: "Greeter.greeting", freshness: engine.ensureFresh())
        let outside = NameMatchedSites.linesOutside(answer: output).joined(separator: "\n")

        #expect(output.contains("Sources/App/Hand.swift:\n"), "\(output)")
        #expect(!outside.contains("Hand.swift"), "\(outside)")
    }

    /// A block names what it stands for as briefly as stays unambiguous: nothing for the one declaration listed, `both` or `all N` for every one, and otherwise the shortest tail of each qualified name no other declaration ends with.
    @Test
    func aShortNameStaysUnambiguous() {
        let rows = [Self.row(1, "run()"), Self.row(2, "run()"), Self.row(3, "stop()")]
        let qualified: [Int64: String] = [1: "App.Alpha.run()", 2: "App.Beta.run()", 3: "App.Alpha.stop()"]
        let names = DeclarationShortNames(rows) { qualified[$0.id] ?? "" }

        #expect(names.name(of: rows[0]) == "Alpha.run()")
        #expect(names.name(of: rows[1]) == "Beta.run()")
        #expect(names.name(of: rows[2]) == "stop()")
        #expect(names.owners([rows[0], rows[2]]) == "Alpha.run(), stop()")
        #expect(names.owners(rows) == "all 3 declarations")
        #expect(DeclarationShortNames(Array(rows.prefix(2))) { qualified[$0.id] ?? "" }.owners(Array(rows.prefix(2))) == "both")
        #expect(DeclarationShortNames([rows[2]]) { qualified[$0.id] ?? "" }.owners([rows[2]]) == nil)
    }

    private static func row(_ id: Int64, _ name: String) -> SymbolRow {
        SymbolRow(
            id: id, fileID: 1, path: "Sources/App/A.swift", module: "App", parentID: nil, kind: .function, name: name,
            line: 1, column: 1, endLine: 1, accessLevel: .internalLevel, isStatic: false, isStored: false,
            signature: "func \(name)", docSummary: nil, ifConfigCondition: nil, viewOutline: nil
        )
    }
}
