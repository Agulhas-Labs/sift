//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins the store's site rows carrying the text of their line where a block lists few enough of them, and only from a file the build saw as it stands.
@Suite(.temporaryDirectories, .serialized)
struct WhereStoreSiteTextTests {
    /// A built package with a function called twice from one caller, another called past the text cap, a type used on 35 lines of one file and another on 45.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-store-site-text") { root in
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
                public func helper() -> Int { 1 }

                public func tick() {}

                public func pulse() {}

                public struct Widget: Sendable {
                    public init() {}
                }

                public struct Gadget: Sendable {
                    public init() {}
                }
                """,
                to: "Sources/Lib/Helper.swift",
                in: root
            )
            try TestSources.write(
                """
                public func drill() -> Int {
                    let first = helper()
                    let second = helper()
                    return first + second
                }
                """,
                to: "Sources/Lib/Drill.swift",
                in: root
            )
            try TestSources.write("public func pace() {\n    pulse()\n}\n", to: "Sources/Lib/Pace.swift", in: root)
            try TestSources.write("public func step() {\n    pulse()\n    pulse()\n}\n", to: "Sources/Lib/Step.swift", in: root)
            let ticks = Array(repeating: "    tick()", count: 45).joined(separator: "\n")
            try TestSources.write("public func burst() {\n\(ticks)\n}\n", to: "Sources/Lib/Burst.swift", in: root)
            try TestSources.write((1 ... 35).map { "public let item\($0) = Widget()" }.joined(separator: "\n") + "\n", to: "Sources/Lib/Many.swift", in: root)
            try TestSources.write((1 ... 45).map { "public let piece\($0) = Gadget()" }.joined(separator: "\n") + "\n", to: "Sources/Lib/Lots.swift", in: root)
            try TestSources.commitAll(in: root, message: "store site text fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// A caller's two calls, folded into one row in the compact form, are listed one row per line with the line's text, the caller kept on each.
    @Test
    func callersAtOrUnderTheCapCarryTheirText() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "helper", freshness: engine.ensureFresh())

            #expect(Self.rowsUnder("callers of Lib.helper() (2):", in: output) == [
                "Sources/Lib/Drill.swift (2):",
                "  :2  drill()  | let first = helper()",
                "  :3  drill()  | let second = helper()",
            ], "\(output)")
            #expect(!output.contains("sites)"), "\(output)")
        }
    }

    /// A caller of more sites than the cap keeps the compact form: one folded row, no text.
    @Test
    func callersAboveTheCapKeepTheCompactForm() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "tick", freshness: engine.ensureFresh())

            #expect(Self.rowsUnder("callers of Lib.tick() (45):", in: output) == ["burst() — Sources/Lib/Burst.swift:2 (45 sites)"], "\(output)")
        }
    }

    /// A type used on 35 lines of one file lists every one of them with its text, past the per-file cap of the compact form, with nothing counted as hidden.
    @Test
    func usageAtOrUnderTheCapListsEveryLineWithItsText() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Widget", freshness: engine.ensureFresh())

            #expect(output.contains("used by Lib.Widget: 35 references in 1 file — "), "\(output)")
            let expected = ["Sources/Lib/Many.swift (35):"] + (1 ... 35).map { "  :\($0)  | public let item\($0) = Widget()" }
            #expect(Self.rowsUnder("used by Lib.Widget:", in: output) == expected, "\(output)")
            #expect(!output.contains("more"), "\(output)")
            #expect(!output.contains("past the per-file cap"), "\(output)")
        }
    }

    /// A type used on 45 lines keeps today's compact row, its per-file cap and the note counting what it hid.
    @Test
    func usageAboveTheCapKeepsTheCompactForm() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Gadget", freshness: engine.ensureFresh())

            let listed = (1 ... 30).map(String.init).joined(separator: ", ")

            #expect(Self.rowsUnder("used by Lib.Gadget:", in: output) == [
                "Sources/Lib/Lots.swift (45): \(listed), +15 more",
                "note: 15 lines past the per-file cap in the files above — grep those files before sweeping",
            ], "\(output)")
        }
    }

    /// Every reference the sweep counts is a row of its own, and the answer is read back as locating each of them.
    @Test
    func everyStoreReferenceIsARowAndLocated() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Widget", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))

            let heading = try #require(output.components(separatedBy: "\n").first { $0.hasPrefix("references to Lib.Widget (") })
            let count = try #require(Int(heading.dropFirst("references to Lib.Widget (".count).prefix { $0.isNumber }))
            let rows = Self.rowsUnder(heading, in: output).filter { $0.hasPrefix("  :") }
            #expect(rows.count == count, "\(output)")
            #expect(rows.allSatisfy { $0.contains("  | ") }, "\(output)")
            let located = ExactAnswer.locations(inWhereAnswer: output)
            for line in 1 ... 35 {
                #expect(located.contains(ExactAnswer.Location(path: "Sources/Lib/Many.swift", line: line)), "\(line): \(output)")
            }
        }
    }

    /// A page of the sweep past its first file lists the rest with their text, under the same total.
    @Test
    func aLaterPageOfTheSweepKeepsItsText() async throws {
        try await Self.fixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()
            let whole = try await engine.lookup(symbol: "pulse", freshness: freshness, options: WhereOptions(includeReferences: true))
            let paged = try await engine.lookup(symbol: "pulse", freshness: freshness, options: WhereOptions(includeReferences: true, offset: 1))

            #expect(Self.rowsUnder("references to Lib.pulse() (3 in 2 files):", in: whole) == [
                "Sources/Lib/Pace.swift (1):",
                "  :2  | pulse()",
                "Sources/Lib/Step.swift (2):",
                "  :2  | pulse()",
                "  :3  | pulse()",
            ], "\(whole)")
            #expect(Self.rowsUnder("references to Lib.pulse() (3 in 2 files):", in: paged) == [
                "(…1 file skipped)",
                "Sources/Lib/Step.swift (2):",
                "  :2  | pulse()",
                "  :3  | pulse()",
            ], "\(paged)")
        }
    }

    /// Without the store, the answer is the name-matched block alone, exactly as it was before store rows carried text.
    @Test
    func withoutTheStoreNothingChanges() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "helper", freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: false))

            #expect(output.hasSuffix("""
            declarations (1):
              Lib.helper() — func — public func helper() -> Int — Sources/Lib/Helper.swift:1

            syntactic call sites — by written name over the working tree, never stale — see sift help answers (call sites)

            "helper" (2 call sites in 1 file):
              Sources/Lib/Drill.swift:
                :2  in drill().first  | let first = helper()
                :3  in drill().second  | let second = helper()
            """), "\(output)")
        }
    }

    /// A file written since the build keeps its mark and prints its rows without text, since the line the store names may have moved.
    @Test
    func aFileModifiedSinceTheBuildPrintsNoText() async throws {
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
        try TestSources.write("public struct Spark {\n    public init() {}\n}\n\npublic func glow() {}\n", to: "Sources/Lib/Spark.swift", in: root)
        let use = "public func light() -> Spark {\n    glow()\n    return Spark()\n}\n"
        try TestSources.write(use, to: "Sources/Lib/Use.swift", in: root)
        try TestSources.commitAll(in: root, message: "stale fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write("// moved\n" + use, to: "Sources/Lib/Use.swift", in: root)

        let callers = try await engine.lookup(symbol: "glow", freshness: engine.ensureFresh())
        #expect(Self.rowsUnder("callers of Lib.glow() (1, 1 file changed since last build):", in: callers) == [
            "Sources/Lib/Use.swift (1):  (file changed since last build)",
            "  :2  light()",
        ], "\(callers)")
        let usage = try await engine.lookup(symbol: "Spark", freshness: engine.ensureFresh())
        #expect(Self.rowsUnder("used by Lib.Spark:", in: usage) == [
            "Sources/Lib/Use.swift (2):  (file changed since last build)",
            "  :1",
            "  :3",
        ], "\(usage)")
        #expect(!ExactAnswer.locations(inWhereAnswer: usage).contains { $0.path == "Sources/Lib/Use.swift" }, "\(usage)")
    }
}

extension WhereStoreSiteTextTests {
    /// The answer with each row listed under a `path (count):` heading spelled with its file, `    Sources/A.swift:12  caller  | text`, so a test can look for a location whole whichever form its block took.
    static func located(_ answer: String) -> String {
        var path: Substring?
        return answer.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let match = line.wholeMatch(of: #/ {2}(\S.*\.swift) \(\d+\):.*/#) {
                path = match.output.1
                return String(line)
            }
            if let path, line.hasPrefix("    :") {
                return "    \(path)" + line.dropFirst(4)
            }
            path = nil
            return String(line)
        }.joined(separator: "\n")
    }

    /// The indented rows directly under the first line starting with `heading`, their first two spaces taken off.
    static func rowsUnder(_ heading: String, in output: String) -> [String] {
        let lines = output.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix(heading) }) else { return [] }
        return lines[(start + 1)...].prefix { $0.hasPrefix("  ") }.map { String($0.dropFirst(2)) }
    }
}
