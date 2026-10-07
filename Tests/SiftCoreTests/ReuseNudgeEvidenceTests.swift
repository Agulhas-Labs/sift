//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// The reuse nudge wants the shared callees to weigh something, besides `similar`'s overlap fraction.
struct ReuseNudgeEvidenceTests {
    /// Fillers that make `map`, `joined` and `filter` as common in the scan as they are in a real module.
    private static let crowd = (1 ... 8).map { index in
        "    func crowd\(index)(_ names: [String]) -> String {\n        let kept = names.filter { !$0.isEmpty }\n        let shown = kept.map { $0 }\n        return shown.joined(separator: \"\(index)\")\n    }\n"
    }.joined()

    private static func nudges(addedTo path: String, in files: [String: String]) -> [ReuseNudge] {
        let fingerprints = files.sorted { $0.key < $1.key }.flatMap { FingerprintScanner.fingerprints(in: $0.value, path: $0.key) }
        return ReuseNudge.closest(addedTo: path, before: [], among: fingerprints)
    }

    /// The shape of the issue's string builder: a name list joined into a sentence, beside a query echo doing the same with its own calls.
    @Test func aStringBuilderSharingOnlyCollectionCallsDrawsNothing() {
        let builder = "struct Hedge {\n    func hedge(_ names: [String]) -> String {\n        let kept = names.filter { !$0.isEmpty }\n        let shown = kept.map { $0 }\n        return shown.joined(separator: \" or \")\n    }\n}\n"
        let echo = "struct Echo {\n    func echo(_ names: [String]) -> String {\n        let kept = names.filter { !$0.isEmpty }\n        let shown = kept.map { $0 }\n        return shown.joined(separator: \" \")\n    }\n}\n"
        let crowd = "struct Crowd {\n\(Self.crowd)}\n"

        let found = Self.nudges(addedTo: "Sources/A/Hedge.swift", in: ["Sources/A/Hedge.swift": builder, "Sources/A/Echo.swift": echo, "Sources/A/Crowd.swift": crowd])

        #expect(found.isEmpty)
    }

    /// A body that copies another's rarer calls is still named.
    @Test func aHelperCopyingAnotherHelpersRareCallsStillDrawsANudge() {
        let stock = "struct Depot {\n    func stock() -> Int {\n        let crates = load()\n        let weight = weigh(crates)\n        label(crates, weight)\n        return ship(crates)\n    }\n}\n"
        let restock = "struct Catalogue {\n    func restock() -> Int {\n        let crates = load()\n        let weight = weigh(crates)\n        label(crates, weight)\n        return ship(crates)\n    }\n}\n"
        let crowd = "struct Crowd {\n\(Self.crowd)}\n"

        let found = Self.nudges(addedTo: "Sources/A/Catalogue.swift", in: ["Sources/A/Catalogue.swift": restock, "Sources/A/Depot.swift": stock, "Sources/A/Crowd.swift": crowd])

        #expect(found.map(\.hit.fingerprint.declaration.qualifiedName) == ["Depot.stock()"])
    }

    /// Two tests' worth of lookup-and-expect boilerplate does not make a test resemble the helper beside it.
    @Test func aTestSharingOnlyTheLookupAndExpectCallsWithAHelperDrawsNothing() {
        let helper = "import Testing\n\nstruct WhereFixedTextBudgetTests {\n    static func assertBudget(_ symbol: String) async throws {\n        let engine = try SiftEngine(directory: root)\n        let freshness = try await engine.ensureFresh()\n        let answer = try await engine.lookup(symbol: symbol, freshness: freshness)\n        #expect(answer.contains(symbol))\n        #expect(answer.count < 10)\n    }\n}\n"
        let test = "import Testing\n\nstruct AliasSpanUsageWhereTests {\n    @Test func anAliasThatNamesTheTypeNowhereIsNotFoldedIn() async throws {\n        let engine = try SiftEngine(directory: root)\n        let freshness = try await engine.ensureFresh()\n        let answer = try await engine.lookup(symbol: \"Shelf\", freshness: freshness)\n        #expect(answer.contains(\"Shelf\"))\n        #expect(!answer.isEmpty)\n    }\n}\n"
        let crowd = (1 ... 8).map { "struct Other\($0) {\n    func probe() async throws {\n        let engine = try SiftEngine(directory: root)\n        let freshness = try await engine.ensureFresh()\n        let made = try await engine.lookup(symbol: \"x\", freshness: freshness)\n        #expect(made.contains(\"x\"))\n    }\n}\n" }.joined()

        let found = Self.nudges(addedTo: "Tests/A/AliasSpanUsageWhereTests.swift", in: ["Tests/A/AliasSpanUsageWhereTests.swift": test, "Tests/A/WhereFixedTextBudgetTests.swift": helper, "Tests/A/Others.swift": crowd])

        #expect(found.isEmpty)
    }
}
