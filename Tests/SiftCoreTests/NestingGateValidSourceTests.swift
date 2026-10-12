//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers what the nesting checks must let through: valid Swift whose `<`, `[` and regex brackets look like nesting is indexed for its declarations, and a repository holding a file nested past what a small thread survives still answers.
@Suite(.temporaryDirectories)
struct NestingGateValidSourceTests {
    /// Valid Swift each declaring `crateData`, keyed by a name for its file.
    private static let valid: [String: String] = [
        "Expect": "@Test func crateData() {\n" + (0 ..< 13).map { "    #expect(Version(v: \($0)) < Version(v: \($0 + 1)))\n" }.joined() + "}",
        "Shifts": "struct Flags {\n    static let crateData: [UInt] = [" + (0 ..< 7).map { "1 << \($0)" }.joined(separator: ", ") + "]\n}",
        "Ranges": "func crateData() {\n    XCTAssertEqual(splits(), [\n" + (0 ..< 13).map { "        \($0)..<\($0 + 1),\n" }.joined() + "    ])\n}",
        "Switch": "func crateData(_ value: Int) -> Int {\n    switch value {\n" + (0 ..< 13).map { "    case _ where value < \($0): return \($0)\n" }.joined() + "    default: return 0\n    }\n}",
        "Regex": "enum Patterns {\n" + (0 ..< 50).map { "    static let open\($0) = #/\\(/#\n" }.joined() + "    static let crateData = 1\n}",
        "Compare": "func crateData(_ i: Int, _ n: Int) {\n" + (0 ..< 300).map { _ in "    if i<n { use(i) }\n" }.joined() + "}",
        "Comparisons": "func crateData(a: Int, b: Int) -> [Bool] {\n    return [\n" + String(repeating: "        a<b,\n", count: 300) + "    ]\n}",
        "Masks": "func crateData(mask: UInt, n: UInt) -> [UInt] {\n    [\n" + String(repeating: "        mask<<n,\n", count: 600) + "    ]\n}",
        "Bounds": "func crateData(a: Int, b: Int) -> [Bool] {\n    [\n" + String(repeating: "        a<=b,\n", count: 600) + "    ]\n}",
        "Keywords": """
        func crateData(_ text: String) throws -> Regex<Substring> {
            let pick = { (flag: Bool) in /[[[[[[[[[[[a]]]]]]]]]]]/ }
            switch text {
            case /[[[[[[[[[[[b]]]]]]]]]]]/: return pick(true)
            default: break
            }
            if text.isEmpty { throw /[[[[[[[[[[[c]]]]]]]]]]]/ }
            return /[[[[[[[[[[[d]]]]]]]]]]]/
        }
        """,
    ]

    private static func makeRepo(files: [String: String]) async throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        for (path, contents) in files {
            try TestSources.write(contents + "\n", to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "nesting fixture")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        return engine
    }

    @Test
    func validSwiftWithComparisonsShiftsRangesAndRegexBracketsIsIndexedForItsDeclarations() async throws {
        let engine = try await Self.makeRepo(files: Dictionary(uniqueKeysWithValues: Self.valid.map { ("Sources/App/Valid\($0.key).swift", $0.value) }))

        let inventory = try engine.store.fileInventory()
        for (name, source) in Self.valid {
            #expect(NestingGate.admits(source), "Valid\(name).swift")
            #expect(inventory["Sources/App/Valid\(name).swift"]?.parseErrorCount == 0, "Valid\(name).swift")
            let digest = try engine.digest(target: "Sources/App/Valid\(name).swift", options: DigestOptions())
            #expect(digest.contains("crateData"), "Valid\(name).swift")
        }
    }

    @Test
    func whereAnswersInARepositoryHoldingAFileNestedPastWhatASmallThreadSurvives() async throws {
        let engine = try await Self.makeRepo(files: [
            "Sources/App/Plain.swift": "enum Outer { struct Inner {} }\nfunc use(_ value: Inner) {}\nlet bare: Inner? = nil",
            "Sources/App/Probe.swift": "@Observable final class Model {}\nlet x = " + String(repeating: #""\("#, count: 300) + "1" + String(repeating: #")""#, count: 300),
        ])

        let answer = try await engine.lookup(symbol: "Inner", freshness: engine.ensureFresh())

        #expect(answer.contains("Sources/App/Plain.swift:1"))
    }
}
