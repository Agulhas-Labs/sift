//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// A function's `--refs` answer lists each reference line once: `references to` is folded against `callers of`, counting the lines listed above and listing only the rest, on every page (Docs/Design.md §2, *The callers/references fold*).
@Suite(.temporaryDirectories)
struct CallersReferencesFoldTests {
    /// Three callers, one of them also handing the function on unapplied on the same line, and a fourth function that only hands it on: every line is a call site above, so `references to` is its heading alone.
    @Test
    func aReferenceAlreadyListedAsACallSiteIsCountedAndNotListedAgain() async throws {
        let root = try Self.package([
            "Sources/App/Ledger.swift": "public struct Ledger {\n    public init() {}\n    public func settle(_ amount: Int) -> Int { amount }\n}\n",
            "Sources/App/Teller.swift": "func open(_ ledger: Ledger) -> Int {\n    ledger.settle(1)\n}\n\nfunc close(_ ledger: Ledger) -> Int {\n    ledger.settle(2)\n}\n",
            "Sources/App/Audit.swift": "func review(_ ledger: Ledger) -> Int {\n    ledger.settle(3) + [4].map(ledger.settle)[0]\n}\n\nfunc batch(_ ledger: Ledger, _ amounts: [Int]) -> [Int] {\n    amounts.map(ledger.settle)\n}\n",
        ])

        let answer = try await Self.refs("Ledger.settle", in: root)
        let callers = Self.siteLines(in: answer, under: "callers of App.Ledger.settle(_:)")
        let references = Self.siteLines(in: answer, under: "references to App.Ledger.settle(_:)")

        #expect(callers.sorted() == ["Sources/App/Audit.swift:2", "Sources/App/Audit.swift:6", "Sources/App/Teller.swift:2", "Sources/App/Teller.swift:6"])
        #expect(references.isEmpty)
        #expect(answer.contains("references to App.Ledger.settle(_:) (4 in 2 files, 4 of them the call sites above):"))
        // The line that both calls and hands the function on is listed, once, with its text, which shows both.
        #expect(answer.components(separatedBy: "ledger.settle(3) + [4].map(ledger.settle)[0]").count == 2)
        #expect(answer.contains("batch(_:_:) — referenced, not called"))
    }

    /// Two overloads called on one line: each declaration's references fold against its own callers, never another's.
    @Test
    func eachOverloadFoldsAgainstItsOwnCallers() async throws {
        let root = try Self.package([
            "Sources/App/Ledger.swift": "public struct Ledger {\n    public init() {}\n    public func settle(_ amount: Int) -> Int { amount }\n    public func settle(_ note: String) -> Int { 0 }\n}\n",
            "Sources/App/Teller.swift": "func open(_ ledger: Ledger) -> Int {\n    ledger.settle(1) + ledger.settle(\"memo\")\n}\n\nfunc close(_ ledger: Ledger) -> Int {\n    ledger.settle(2)\n}\n",
        ])

        let answer = try await Self.refs("Ledger.settle", in: root)

        #expect(answer.contains("references to App.Ledger.settle(_:) (2 in 1 file, 2 of them the call sites above):"))
        #expect(answer.contains("references to App.Ledger.settle(_:) (1 in 1 file, 1 of them the call sites above):"))
        #expect(Self.siteLines(in: answer, under: "references to").isEmpty)
    }

    /// Forty-five callers each calling twice: `callers of` folds each caller to its first line and lists forty of them, so the other fifty lines are listed under `references to`, paged in files, and the two pages and the callers together hold all ninety lines, each once.
    @Test
    func theLinesCallersOnlyCountedAreListedAndPagingReachesEveryOne() async throws {
        let count = 45
        var files = ["Sources/App/Ledger.swift": "public struct Ledger {\n    public init() {}\n    public func settle(_ amount: Int) -> Int { amount }\n}\n"]
        for index in 1 ... count {
            files["Sources/App/Till\(index).swift"] = "func till\(index)(_ ledger: Ledger) -> Int {\n    let first = ledger.settle(\(index))\n    return first + ledger.settle(0)\n}\n"
        }
        let root = try Self.package(files)
        let every = Set((1 ... count).flatMap { ["Sources/App/Till\($0).swift:2", "Sources/App/Till\($0).swift:3"] })

        let first = try await Self.refs("Ledger.settle", in: root)
        let second = try await Self.refs("Ledger.settle", in: root, offset: WhereRenderer.listCap)
        let callers = Self.siteLines(in: first, under: "callers of")
        let pageOne = Self.siteLines(in: first, under: "references to")
        let pageTwo = Self.siteLines(in: second, under: "references to")

        #expect(callers.count == WhereRenderer.listCap)
        #expect(Self.siteLines(in: second, under: "callers of").sorted() == callers.sorted())
        #expect(first.contains("references to App.Ledger.settle(_:) (90 in 45 files, 40 of them the call sites above):"))
        #expect(first.contains("pass offset 40 to continue"))
        let listed = callers + pageOne + pageTwo
        #expect(listed.count == every.count)
        #expect(Set(listed) == every)
        // A caller listed by its first line leaves its second to `references to`.
        #expect(Set(callers).isDisjoint(with: pageOne + pageTwo))
        #expect(pageOne.contains { $0.hasSuffix(":3") })
    }

    /// Forty-two callers, one past the cap twice over: the two callers `callers of` only counts are listed under `references to` with their text, and a page past the first file keeps it.
    @Test
    func aLaterPageOfTheRestKeepsItsText() async throws {
        var files = ["Sources/App/Ledger.swift": "public struct Ledger {\n    public init() {}\n    public func settle(_ amount: Int) -> Int { amount }\n}\n"]
        for index in 1 ... WhereRenderer.listCap + 2 {
            files["Sources/App/Till\(index).swift"] = "func till\(index)(_ ledger: Ledger) -> Int {\n    ledger.settle(\(index))\n}\n"
        }
        let root = try Self.package(files)

        let first = try await Self.refs("Ledger.settle", in: root)
        let second = try await Self.refs("Ledger.settle", in: root, offset: 1)
        let rest = Self.siteLines(in: first, under: "references to")

        #expect(first.contains("references to App.Ledger.settle(_:) (42 in 42 files, 40 of them the call sites above):"))
        #expect(rest.count == 2)
        #expect(Set(rest).isDisjoint(with: Self.siteLines(in: first, under: "callers of")))
        #expect(Self.siteLines(in: second, under: "references to") == Array(rest.sorted().dropFirst()))
        #expect(second.contains("(…1 file skipped)"))
        #expect(second.contains("    :2  till27(_:)  | ledger.settle("))
    }

    /// A package of `files` with a built index store, its tree indexed.
    private static func package(_ files: [String: String]) throws -> URL {
        let root = try MCPTestRepo.make(declaring: "Alpha")
        try MCPTestRepo.add(files.merging([
            "Package.swift": "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\")])\n",
        ]) { own, _ in own }, to: root)
        try MCPTestRepo.build(root)
        return root
    }

    /// `where <symbol> --refs` at `offset`, asked again until the store has finished loading, failing after two minutes rather than asserting on a warming answer.
    private static func refs(_ symbol: String, in root: URL, offset: Int = 0) async throws -> String {
        let engine = try SiftEngine(directory: root)
        let giveUp = Date().addingTimeInterval(120)
        while true {
            let freshness = try await engine.ensureFresh()
            let answer = try await engine.lookup(symbol: symbol, freshness: freshness, options: WhereOptions(includeReferences: true, offset: offset))
            if !answer.contains("semantic: " + SemanticAxis.warming.rendered) {
                return answer
            }
            struct StillWarming: Error {}
            guard Date() < giveUp else { throw StillWarming() }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Every `path:line` the section headed by `heading` lists, in the order listed, read from each of the three row shapes: a file heading with `:line` rows under it, `path (N): line, line`, and a caller folded to `name — path:line`.
    private static func siteLines(in answer: String, under heading: String) -> [String] {
        var sites: [String] = []
        var inSection = false
        var file: String?
        for line in answer.components(separatedBy: "\n") {
            if !line.hasPrefix(" ") {
                inSection = line.hasPrefix(heading)
                file = nil
                continue
            }
            guard inSection else { continue }
            if let row = line.firstMatch(of: #/^ {4}:(\d+)/#), let file {
                sites.append("\(file):\(row.1)")
            } else if let header = line.firstMatch(of: #/^ {2}(\S+\.swift) \(\d+\):(.*)$/#) {
                file = String(header.1)
                let listed = header.2.prefix { $0 == " " || $0 == "," || $0.isNumber }
                sites += listed.split(separator: ",").map { "\(header.1):\($0.trimmingCharacters(in: .whitespaces))" }
            } else if let folded = line.firstMatch(of: #/^ {2}\S.* — (\S+\.swift):(\d+)/#) {
                sites.append("\(folded.1):\(folded.2)")
            }
        }
        return sites
    }
}
