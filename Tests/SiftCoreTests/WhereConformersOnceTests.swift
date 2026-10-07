//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins a protocol's conformers listed once under a store, marked direct or indirect, and its usage rows never repeating them.
@Suite(.temporaryDirectories, .serialized)
struct WhereConformersOnceTests {
    /// A built package whose protocol has conformers written directly, through a typealias, through a refining protocol and through a superclass, plus one outside every target.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-conformers-once") { root in
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
                """
                public protocol Greeter {
                    func salute()
                }
                """,
                to: "Sources/Lib/Greeter.swift",
                in: root
            )
            try TestSources.write(
                """
                public struct Soldier: Greeter {
                    public init() {}
                    public func salute() {}
                }

                public typealias Alias = Greeter

                public struct Cadet: Alias {
                    public func salute() {}
                }

                public protocol Officer: Greeter {}

                public struct Major: Officer {
                    public func salute() {}
                }

                open class Sergeant: Greeter {
                    open func salute() {}
                }

                public final class Recruit: Sergeant {}

                extension Int: Greeter {
                    public func salute() {}
                }

                public struct Medic: Greeter & Sendable {
                    public func salute() {}
                }
                """,
                to: "Sources/Lib/Ranks.swift",
                in: root
            )
            try TestSources.write(
                """
                public func drill(greeter: Greeter) {
                    greeter.salute()
                }

                public func parade(_ first: Greeter, _ second: Greeter) {}
                """,
                to: "Sources/Lib/Drill.swift",
                in: root
            )
            try TestSources.write(
                """
                struct Late: Greeter {
                    func salute() {}
                }
                """,
                to: "Extras/Late.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "conformers fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// Every conformer is listed once, in one block whose heading totals the direct and indirect ones, a composition included.
    @Test
    func eachConformerIsListedOnceAndMarked() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Greeter", freshness: engine.ensureFresh())

            #expect(output.components(separatedBy: "conformers of Greeter (").count == 2, "\(output)")
            #expect(output.contains("conformers of Greeter (9: 6 direct, 0 indirect, 2 inherited, 1 through a typealias — direct is every inheritance clause in this tree's source that writes the name, so a grep for the name finds the same lines; through a typealias is a clause writing a typealias of it; indirect is from the index store; inherited is reached through a listed protocol or class, so a grep for the name does not find it):"), "\(output)")
            #expect(!output.contains("includes indirect"), "\(output)")
            #expect(!output.contains("by written name"), "\(output)")
            #expect(output.contains("  Lib.Cadet — struct — Sources/Lib/Ranks.swift:8-10 — through typealias Lib.Alias\n"), "\(output)")
            for name in ["Extras.Late", "Lib.Soldier", "Lib.Officer", "Lib.Sergeant", "Lib.Int", "Lib.Medic"] {
                #expect(output.components(separatedBy: "  \(name) — ").count == 2, "\(name): \(output)")
            }
            #expect(output.contains("  Lib.Soldier — struct — Sources/Lib/Ranks.swift:1-4 — direct\n"), "\(output)")
            #expect(output.contains("  Lib.Int — extension — Sources/Lib/Ranks.swift:24-26 — direct\n"), "\(output)")
            #expect(output.contains("  Lib.Medic — struct — Sources/Lib/Ranks.swift:28-30 — direct\n"), "\(output)")
            #expect(output.hasSuffix("  Lib.Recruit — class — Sources/Lib/Ranks.swift:22 — inherited through Sergeant"), "\(output)")
        }
    }

    /// A conformer only the scan by written name finds, in a file no target builds, is listed as direct and says the store does not have it.
    @Test
    func aConformerTheStoreLacksSaysSo() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Greeter", freshness: engine.ensureFresh())

            #expect(output.contains("  Extras.Late — struct — Extras/Late.swift:1-3 — direct; the index store does not have it\n"), "\(output)")
        }
    }

    /// The usage heading counts the conformance lines among its references and its rows list only the rest.
    @Test
    func usageCountsConformancesAndListsOnlyTheRest() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Greeter", freshness: engine.ensureFresh())

            #expect(output.contains("used by Lib.Greeter: 8 references in 2 files, 5 of them the conformances listed below — 8 production · 0 tests"), "\(output)")
            #expect(output.contains("  Sources/Lib/Drill.swift (2):\n    :1  | public func drill(greeter: Greeter) {\n    :5  | public func parade(_ first: Greeter, _ second: Greeter) {}\n"), "\(output)")
            #expect(output.contains("  Sources/Lib/Ranks.swift (1): — written as Lib.Alias\n    :8  | public struct Cadet: Alias {\n"), "\(output)")
        }
    }

    /// Every reference the sweep lists is either a row of the usage block or a line inside a listed conformer's declaration.
    @Test
    func everyReferenceIsListedOrAConformerLine() async throws {
        try await Self.fixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()
            let plain = try await engine.lookup(symbol: "Greeter", freshness: freshness)
            let swept = try await engine.lookup(symbol: "Greeter", freshness: freshness, options: WhereOptions(includeReferences: true))

            let all = Self.fileLines(under: "references to Lib.Greeter (", in: swept)
            let listed = Self.fileLines(under: "used by Lib.Greeter:", in: plain)
            let spans = Self.conformerSpans(in: plain)
            #expect(all.values.map(\.count).reduce(0, +) == 8, "\(swept)")
            var unlisted: [String] = []
            for (path, lines) in all {
                for line in lines where !(listed[path]?.contains(line) ?? false) && !spans.contains(where: { $0.path == path && $0.lines.contains(line) }) {
                    unlisted.append("\(path):\(line)")
                }
            }
            // The typealias declaration is the one line the usage block counts apart, in its heading, rather than lists.
            #expect(unlisted == ["Sources/Lib/Ranks.swift:6"], "\(plain)")
            #expect(plain.contains("1 more line declaring a typealias of it"), "\(plain)")
        }
    }

    /// A conformance the store recorded whose clause no longer names the protocol is indirect, and its line, in a file edited since the build, stays in the usage rows.
    @Test
    func aStoreOnlyConformerIsIndirectAndItsEditedLineStaysListed() async throws {
        let root = try TestSources.makeTempRepo()
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
        try TestSources.write("public protocol Greeter {}\n", to: "Sources/Lib/Greeter.swift", in: root)
        try TestSources.write("public struct Soldier: Greeter {}\n", to: "Sources/Lib/Ranks.swift", in: root)
        try TestSources.commitAll(in: root, message: "indirect fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write("public struct Soldier: Officer {}\n\npublic protocol Officer: Greeter {}\n", to: "Sources/Lib/Ranks.swift", in: root)

        let output = try await engine.lookup(symbol: "Greeter", freshness: engine.ensureFresh())

        #expect(output.contains("conformers of Greeter (2: 1 direct, 1 indirect — direct is every inheritance clause in this tree's source that writes the name, so a grep for the name finds the same lines; a typealias to it is not followed; indirect is from the index store, 1 file changed since last build):"), "\(output)")
        #expect(output.contains("  Lib.Officer — protocol — Sources/Lib/Ranks.swift:3 — direct; the index store does not have it\n"), "\(output)")
        #expect(output.contains("  Lib.Soldier — struct — Sources/Lib/Ranks.swift:1 — indirect  (file changed since last build)"), "\(output)")
        #expect(output.contains("  Sources/Lib/Ranks.swift (1):  (file changed since last build)\n    :1"), "\(output)")
        #expect(!output.contains("of them the conformance"), "\(output)")
    }

    /// Without the store, a protocol keeps the block the scan by written name prints, with no marks but on the rows reached through a listed protocol or class and the one written through its own typealias.
    @Test
    func withoutTheStoreTheWrittenNameBlockIsUnchanged() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Greeter", freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: false))

            let block = """
            conformers of Greeter (9, by written name, 1 through a typealias, 2 inherited — through a typealias is a clause writing a typealias of it; inherited is reached through a listed protocol or class, so a grep for the name does not find it):
              Extras.Late — struct — Extras/Late.swift:1-3
              Lib.Soldier — struct — Sources/Lib/Ranks.swift:1-4
              Lib.Officer — protocol — Sources/Lib/Ranks.swift:12
              Lib.Sergeant — class — Sources/Lib/Ranks.swift:18-20
              Lib.Int — extension — Sources/Lib/Ranks.swift:24-26
              Lib.Medic — struct — Sources/Lib/Ranks.swift:28-30
              Lib.Cadet — struct — Sources/Lib/Ranks.swift:8-10 — through typealias Lib.Alias
              Lib.Major — struct — Sources/Lib/Ranks.swift:14-16 — inherited through Officer
              Lib.Recruit — class — Sources/Lib/Ranks.swift:22 — inherited through Sergeant
            """

            #expect(output.hasSuffix(block), "\(output)")
            #expect(!output.contains("direct"), "\(output)")
        }
    }

    /// A class keeps both conformer blocks under the store, unmerged.
    @Test
    func aClassKeepsItsTwoBlocks() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Sergeant", freshness: engine.ensureFresh())

            #expect(output.contains("conformers of Sergeant (1, direct subclasses from the store):\n  Sources/Lib/Ranks.swift (1):\n    :22  Recruit  | public final class Recruit: Sergeant {}"), "\(output)")
            #expect(output.contains("conformers of Sergeant (1, by written name):\n  Lib.Recruit — class — Sources/Lib/Ranks.swift:22"), "\(output)")
            #expect(!output.contains("of them the conformance"), "\(output)")
        }
    }
}

extension WhereConformersOnceTests {
    /// The lines listed under the first line starting with `heading`, by path: from `path (count): line, line` rows, or from the `:line` rows under a `path (count):` heading.
    static func fileLines(under heading: String, in output: String) -> [String: Set<Int>] {
        var rows: [String: Set<Int>] = [:]
        var current: String?
        for row in rowsUnder(heading, in: output) {
            if let current, let match = row.wholeMatch(of: #/\s+:(\d+)(?: {2}.*)?/#), let number = Int(match.output.1) {
                rows[current, default: []].insert(number)
                continue
            }
            current = nil
            guard let open = row.range(of: " ("), let close = row.range(of: "):") else { continue }
            let path = String(row[..<open.lowerBound])
            let numbers = row[close.upperBound...].components(separatedBy: " — ").first ?? ""
            let listed = numbers.trimmingCharacters(in: .whitespaces).components(separatedBy: ", ").compactMap { Int($0) }
            if listed.isEmpty {
                current = path
            }
            rows[path, default: []].formUnion(listed)
        }
        return rows
    }

    /// The path and line span of each row in the conformers block.
    static func conformerSpans(in output: String) -> [(path: String, lines: ClosedRange<Int>)] {
        rowsUnder("conformers of Greeter (", in: output).compactMap { row in
            let fields = row.components(separatedBy: " — ")
            guard fields.count > 2 else { return nil }
            let place = fields[2].split(separator: ":")
            guard place.count == 2 else { return nil }
            let bounds = place[1].split(separator: "-").compactMap { Int($0) }
            guard let first = bounds.first, let last = bounds.last else { return nil }
            return (String(place[0]), first ... last)
        }
    }

    /// The indented rows directly under the first line starting with `heading`, indentation stripped.
    static func rowsUnder(_ heading: String, in output: String) -> [String] {
        let lines = output.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix(heading) }) else { return [] }
        return lines[(start + 1)...].prefix { $0.hasPrefix("  ") }.map { String($0.dropFirst(2)) }
    }
}
