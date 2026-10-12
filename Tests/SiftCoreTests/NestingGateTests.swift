//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers ``NestingGate`` and ``ParseThread``: a file nested deeper than a small thread survives is parsed for its declarations on a large one, and only a run of `[` or generic arguments past their limits, which the parser takes exponential or quadratic time and unbounded stack on, are refused, as one parse error with no declarations.
@Suite(.temporaryDirectories)
struct NestingGateTests {
    /// One expression nested `depth` deep in each shape the parser recurses on, keyed by a name for its file.
    private static func nested(_ depth: Int) -> [String: String] {
        let generics = min(depth, NestingGate.maximumGenericDepth)
        return [
            "Interpolation": "let crateData = " + String(repeating: #""\("#, count: depth) + "1" + String(repeating: #")""#, count: depth),
            "Parens": "let crateData = " + String(repeating: "(", count: depth) + "1" + String(repeating: ")", count: depth),
            "Closures": "let crateData = " + String(repeating: "{ ", count: depth) + "1" + String(repeating: " }", count: depth),
            "Generics": "let crateData: " + String(repeating: "Array<", count: generics) + "Int" + String(repeating: ">", count: generics) + " = []",
            "Mixed": "let crateData = " + String(repeating: #""\({ [("#, count: depth / 4) + "1" + String(repeating: #")] })""#, count: depth / 4),
            "Listed": "let crateData = " + String(repeating: "[1, ", count: depth) + "1" + String(repeating: "]", count: depth),
        ]
    }

    private static func makeRepo(files: [String: String]) async throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Plain {\n    func hello() {}\n}\n", to: "Sources/App/Plain.swift", in: root)
        for (path, contents) in files {
            try TestSources.write(contents + "\n", to: path, in: root)
        }
        try TestSources.commitAll(in: root, message: "nesting fixture")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        return engine
    }

    @Test(arguments: [100, 1000, 10000])
    func aDeeplyNestedFileIsParsedForItsDeclarations(depth: Int) async throws {
        let deep = Self.nested(depth).merging(["Arrows": "struct Arrows { var crateData: " + String(repeating: "() -> ", count: depth / 5) + "Int }"]) { first, _ in first }
        let engine = try await Self.makeRepo(files: Dictionary(uniqueKeysWithValues: deep.map { ("Sources/App/Deep\($0.key).swift", $0.value) }))

        let inventory = try engine.store.fileInventory()
        for name in deep.keys {
            let digest = try engine.digest(target: "Sources/App/Deep\(name).swift", options: DigestOptions())
            #expect(digest.contains("crateData"), "Deep\(name).swift at \(depth)")
            #expect(inventory["Sources/App/Deep\(name).swift"]?.parseErrorCount != nil, "Deep\(name).swift at \(depth)")
        }
    }

    @Test
    func aRunOfSquareBracketsOrGenericsPastTheLimitIsRefusedAndOneAtItIsParsed() async throws {
        let chain = NestingGate.maximumTypeChain
        let generics = NestingGate.maximumGenericDepth
        let files = [
            "Sources/App/Within.swift": "let crateData = " + String(repeating: "[\n", count: chain) + "1" + String(repeating: "]", count: chain),
            "Sources/App/Angles.swift": "let crateData: " + String(repeating: "Array<\n", count: generics) + "Int" + String(repeating: ">", count: generics) + " = []",
            "Sources/App/Past.swift": "let crateData = " + String(repeating: "[", count: 20) + "1" + String(repeating: "]", count: 20),
            "Sources/App/Typed.swift": "let crateData: " + String(repeating: "[Array<", count: 20) + "Int" + String(repeating: ">]", count: 20) + " = []",
            "Sources/App/Regex.swift": "let r = #/\"/#; let crateData = " + String(repeating: "[", count: 20) + "1" + String(repeating: "]", count: 20),
            "Sources/App/Deeper.swift": "let crateData: " + String(repeating: "Array<\n", count: generics + 1) + "Int" + String(repeating: ">", count: generics + 1) + " = []",
            "Sources/App/Arrows.swift": "let crateData = " + String(repeating: "Array<() -> ", count: generics + 1) + "Int" + String(repeating: ">", count: generics + 1) + "()",
        ]
        let admitted: Set = ["Sources/App/Within.swift", "Sources/App/Angles.swift"]

        // Parsed, a run of 20 takes minutes and the generics overflow the stack, so the gate must refuse them before any parse is made: checked first, and required, so a file wrongly admitted is never handed to the parser here.
        for (path, source) in files {
            try #require(NestingGate.admits(source) == admitted.contains(path), "\(path)")
        }
        let engine = try await Self.makeRepo(files: files)

        let inventory = try engine.store.fileInventory()
        for path in admitted.sorted() {
            #expect(inventory[path]?.parseErrorCount == 0, "\(path)")
        }
        for path in files.keys where !admitted.contains(path) {
            #expect(inventory[path]?.parseErrorCount == 1, "\(path)")
        }

        #expect(FileParser.errors(inSource: files["Sources/App/Past.swift"] ?? "", path: "Past.swift") == [ParseErrorSite(line: 1, column: 1, message: NestingGate.message)])
    }

    @Test
    func aFileNestedPastTheParsersCapHasTheOneErrorTheCapRecords() {
        let source = "let early = )\nlet crateData = " + String(repeating: #""\("#, count: 400) + "1" + String(repeating: #")""#, count: 400)

        let errors = FileParser.errors(inSource: source, path: "Deep.swift")

        #expect(errors.map(\.message) == ["parsing has exceeded the maximum nesting level"])
        #expect(errors.first?.line == 2)
    }

    @Test
    func bracketsInCommentsStringTextAndRegexLiteralsDoNotCount() {
        let opens = String(repeating: "[", count: 100)
        let source = """
        // \(opens)
        /* \(opens) /* nested \(opens) */ \(opens) */
        let a = "\(opens)"
        let b = #"\(opens) \\( "# + "\\(1)"
        let c = #/\(opens)/#
        let d = (/\(opens)/)
        """

        #expect(NestingGate.admits(source))
    }

    @Test
    func aDeeplyNestedTypeSpellingIsReadOnAParseThread() async {
        let generics = String(repeating: "Array<", count: 200) + "Int" + String(repeating: ">", count: 200)

        // Each of these parses a type alone; on a concurrency thread's half-megabyte stack, the parse overflowed it.
        let read = await Task.detached {
            [DeclaredTypeName.last(ofPath: "App." + generics), DeclaredTypeName.path(ofSpelling: generics)]
        }.value

        #expect(read == ["Array", "Array"])
    }

    @Test
    func aParseThreadIsReusedByTheNextRunRatherThanStartedAgain() async {
        let key = "NestingGateTests.reused"

        // Each run marks its thread and says whether an earlier one had; tests running beside this one may take an idle thread between runs, so not every run finds a mark, but some must.
        let reused = await Task.detached {
            (0 ..< 50).filter { _ in
                ParseThread.run {
                    defer { Thread.current.threadDictionary[key] = true }
                    return Thread.current.threadDictionary[key] != nil
                }
            }.count
        }.value

        #expect(reused > 0)
    }

    @Test
    func aTypealiasOrSignatureNestingGenericsDeeplyIsLookedUpWithoutOverflowing() async throws {
        let generics = String(repeating: "Array<", count: 200) + "Int" + String(repeating: ">", count: 200)
        let engine = try await Self.makeRepo(files: [
            "Sources/App/Aliased.swift": "typealias Crate = \(generics)\nextension Crate {\n    func pack() {}\n}",
            "Sources/App/Signed.swift": "func takes(_ crate: \(generics)) {}\nextension \(generics) {\n    func seal() {}\n}\nlet made = Crate()",
        ])

        // Reading where each is declared or used parses the alias's right-hand side and the extended type's spelling.
        for symbol in ["Crate", "Array", "seal", "pack"] {
            let output = try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh())
            #expect(output.contains("Sources/App/"), "\(symbol)")
        }
    }

    /// One file per chain the parser recurses on once a link, `length` links long, keyed by a name for its file: prefix keywords, arrows (the declaration's own among them), `else if` arms (each holding chains of its own), and nested `#if`s `depth` deep.
    private static func chained(_ length: Int, depth: Int) -> [String: String] {
        let keywords = (0 ..< length).map { ["unsafe", "consume", "copy", "try", "await"][$0 % 5] }.joined(separator: " ")
        return [
            "Try": "func crateData() throws { " + String(repeating: "try ", count: length) + "f() }",
            "Marked": "func crateData() throws {\n" + String(repeating: "try?\n", count: length / 2) + String(repeating: "try! ", count: length - length / 2) + "f() }",
            "Await": "func crateData() async { " + String(repeating: "await ", count: length) + "f() }",
            "Keywords": "func crateData() async throws { _ = " + keywords + " x }",
            "Arrows": "func crateData() -> " + String(repeating: "() throws -> ", count: length - 1) + "Int {}",
            "Arms": "func crateData() { if a {} " + String(repeating: "else if (if c { 1 } else { 2 }) == 1 { if b {} } ", count: length) + "}",
            "Conditions": "func crateData() {}\n" + String(repeating: "#if A\n", count: depth) + String(repeating: "#endif\n", count: depth),
        ]
    }

    @Test
    func aChainOfKeywordsArrowsElseIfArmsOrConditionsAtTheLimitIsParsedAndOnePastItIsRefused() async throws {
        let within = Self.chained(NestingGate.maximumChain, depth: NestingGate.maximumConditionDepth)
        let past = Self.chained(NestingGate.maximumChain + 1, depth: NestingGate.maximumConditionDepth + 1)
        let files = Dictionary(uniqueKeysWithValues: within.map { ("Sources/App/Within\($0.key).swift", $0.value) } + past.map { ("Sources/App/Past\($0.key).swift", $0.value) })

        let engine = try await Self.makeRepo(files: files)

        let inventory = try engine.store.fileInventory()
        for (name, source) in within {
            #expect(NestingGate.admits(source), "Within\(name).swift")
            let digest = try engine.digest(target: "Sources/App/Within\(name).swift", options: DigestOptions())
            #expect(digest.contains("crateData"), "Within\(name).swift")
        }
        for (name, source) in past {
            #expect(!NestingGate.admits(source), "Past\(name).swift")
            #expect(inventory["Sources/App/Past\(name).swift"]?.parseErrorCount == 1, "Past\(name).swift")
        }
    }

    @Test
    func aChainOfAHundredThousandLinksIsRefusedRatherThanOverflowingTheParseThread() async throws {
        let chains = Self.chained(100_000, depth: 100_000).merging(["Types": "let crateData: " + String(repeating: "any ", count: 100_000) + "P"]) { first, _ in first }

        // Parsed, each of these overflows even a parse thread's stack, in a release build too, so the gate must refuse them before any parse is made: checked first, and required, so a file wrongly admitted is never handed to the parser here.
        for (name, source) in chains {
            try #require(!NestingGate.admits(source), "Long\(name).swift")
        }
        let engine = try await Self.makeRepo(files: Dictionary(uniqueKeysWithValues: chains.map { ("Sources/App/Long\($0.key).swift", $0.value) }))

        let inventory = try engine.store.fileInventory()
        for name in chains.keys {
            #expect(inventory["Sources/App/Long\(name).swift"]?.parseErrorCount == 1, "Long\(name).swift")
        }
    }
}
