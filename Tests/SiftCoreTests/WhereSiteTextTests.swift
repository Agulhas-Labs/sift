//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Every site a `where` answer lists by name carries the text of its source line, so the answer can be judged without reading the files it names.
@Suite(.temporaryDirectories)
struct WhereSiteTextTests {
    /// The call written on the fourth line of the callers' file, longer than a row prints.
    private static let longLine = "    func long() { relay(" + (1 ... 60).map(String.init).joined(separator: " + ") + ") }"

    /// Lines in one file writing `Gauge`: past the per-file cap on line numbers, within the block's cap on lines listed with their text.
    private static let fewGauges = WhereRenderer.lineListCap + 5

    /// A repository holding `relay(_:)`, its calls in `Sources/App/Uses.swift`, and `Gauge` written once on each of `gauges` lines.
    private static func makeRepo(gauges: Int) throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("func relay(_ value: Int) {}\nstruct Gauge {}\n", to: "Sources/App/Relay.swift", in: root)
        let uses = [
            "struct Hub {",
            "    func run() { relay(1); relay(2) }",
            "    func spaced() {    relay(3)\t\t}",
            longLine,
            "}",
        ]
        try TestSources.write(uses.joined(separator: "\n") + "\n", to: "Sources/App/Uses.swift", in: root)
        let lines = (1 ... gauges).map { "let gauge\($0) = Gauge()" }
        try TestSources.write(lines.joined(separator: "\n") + "\n", to: "Sources/App/Gauges.swift", in: root)
        try TestSources.commitAll(in: root, message: "fixture")
        return root
    }

    /// The answer `where` gives for `symbol` in `directory`, with no index store.
    private static func answer(_ symbol: String, in directory: URL) async throws -> String {
        let engine = try SiftEngine(directory: directory)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh())
    }

    /// A call site's row ends with its line trimmed, whitespace runs collapsed, and two calls on one line fold onto one row with their count.
    @Test
    func callSiteRowsCarryTheirTrimmedSourceLine() async throws {
        let output = try await Self.answer("relay", in: Self.makeRepo(gauges: 1))

        #expect(output.contains("\n  Sources/App/Uses.swift:\n    :2 (×2)  in Hub.run()  | func run() { relay(1); relay(2) }\n    :3  in Hub.spaced()  | func spaced() { relay(3) }\n"), "\(output)")
    }

    /// A line longer than a row prints is cut at 140 characters and marked with an ellipsis.
    @Test
    func aLongLineIsCutWithAnEllipsis() async throws {
        let output = try await Self.answer("relay", in: Self.makeRepo(gauges: 1))
        let trimmed = Self.longLine.trimmingCharacters(in: .whitespaces)
        let cut = String(trimmed.prefix(140)).trimmingCharacters(in: .whitespaces) + "…"

        #expect(trimmed.count > 140)
        #expect(output.split(separator: "\n").map(String.init).contains("    :4  in Hub.long()  | \(cut)"), "\(output)")
    }

    /// A type written on few enough lines lists each with its text, every line of the file kept, with no per-file cap.
    @Test
    func aTypeUsedOnFewLinesListsEachWithItsText() async throws {
        let output = try await Self.answer("Gauge", in: Self.makeRepo(gauges: Self.fewGauges))

        #expect(output.contains("\n  Sources/App/Gauges.swift (\(Self.fewGauges)):\n    :1  | let gauge1 = Gauge()\n"), "\(output)")
        for line in 1 ... Self.fewGauges {
            #expect(output.contains("\n    :\(line)  | let gauge\(line) = Gauge()"), "line \(line) missing:\n\(output)")
        }
        #expect(!output.contains("more"), "\(output)")
        #expect(!output.contains("note:"), "\(output)")
    }

    /// Past forty lines, a type's uses keep the compact form, line numbers after each file.
    @Test
    func aTypeUsedOnManyLinesKeepsTheCompactForm() async throws {
        let output = try await Self.answer("Gauge", in: Self.makeRepo(gauges: 41))

        #expect(output.contains("\n  Sources/App/Gauges.swift (41): 1, 2, 3, "), "\(output)")
        #expect(!output.contains("  | let gauge"), "\(output)")
    }

    /// A sweep paged by file in a worktree lists a type's few uses with their text too.
    @Test
    func aPagedSweepListsATypesUsesWithTheirText() async throws {
        let worktree = try TestSources.makeWorktree(of: Self.makeRepo(gauges: 2), named: "agent-3a4b5c6d")
        let output = try await Self.answer("Gauge", in: worktree)

        #expect(output.contains("\n  Sources/App/Gauges.swift (2):\n    :1  | let gauge1 = Gauge()\n    :2  | let gauge2 = Gauge()"), "\(output)")
    }

    /// The rows with text read back as inside the name-matched block: no site leaks out as a line the answer resolved.
    @Test
    func rowsWithTextStayInsideTheBlock() async throws {
        let root = try Self.makeRepo(gauges: 2)
        for symbol in ["relay", "Gauge"] {
            let output = try await Self.answer(symbol, in: root)
            let outside = NameMatchedSites.linesOutside(answer: output)

            #expect(output.contains("  | "), "\(output)")
            #expect(!outside.contains { $0.contains("  | ") || $0.contains("Uses.swift") || $0.contains("Gauges.swift") }, "\(outside)")
        }
    }
}
