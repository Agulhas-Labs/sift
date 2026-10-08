//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A stored signature keeps one space where the source broke the line next to a bracket; every answer that prints it shows the bracket closed up again, without touching string literals or the spaces that mean something.
@Suite(.temporaryDirectories)
struct SignatureParenSpacingTests {
    static var source: String {
        """
        public enum Answerer {
            public static func answer(
                _ call: Int,
                from direction: String
            ) -> Int { call }

            public static func greet(_ text: String = "a ( b", other: Int = 1) -> Int { other }
        }
        """
    }

    /// The `where` row of a declaration whose list opens on its own line and closes on its own line has neither space.
    @Test
    func whereRowClosesUpABreakAfterOpenAndBeforeClose() async throws {
        let root = try Self.indexedRepo()
        let engine = try SiftEngine(directory: root)
        let located = try await engine.lookup(symbol: "Answerer.answer", freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: false))

        #expect(located.contains("answer(_ call: Int, from direction: String) -> Int"), "\(located)")
        #expect(!located.contains("( _"), "\(located)")
        #expect(!located.contains("String )"), "\(located)")
    }

    /// A string-literal default keeps its `( ` byte for byte.
    @Test
    func whereRowKeepsAStringLiteralDefault() async throws {
        let root = try Self.indexedRepo()
        let engine = try SiftEngine(directory: root)
        let located = try await engine.lookup(symbol: "Answerer.greet", freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: false))

        #expect(located.contains("text: String = \"a ( b\""), "\(located)")
    }

    /// The shared tidy takes the space just inside a bracket and nothing else.
    @Test
    func tidyingTouchesOnlyTheSpaceInsideABracket() {
        let tidy = SourceSlicer.tidyingBrackets(in:)

        #expect(tidy("f( _ a: Int, b: Int )") == "f(_ a: Int, b: Int)")
        #expect(tidy("f( a: [ Int ] )") == "f(a: [Int])")
        #expect(tidy("f(a: String = \"a ( b ) [ c\" )") == "f(a: String = \"a ( b ) [ c\")")
        #expect(tidy("f(a: String = #\"x ( y\"#, b: Int = 1 )") == "f(a: String = #\"x ( y\"#, b: Int = 1)")
        #expect(tidy("f(_ a: Int) -> (Int) -> ( )") == "f(_ a: Int) -> (Int) -> ()")
        #expect(tidy("f(_ a: Int) -> (Int, Int)") == "f(_ a: Int) -> (Int, Int)")
        #expect(tidy("f<T>(_ a: T) where T: Equatable") == "f<T>(_ a: T) where T: Equatable")
    }

    /// A diff's before and after of a changed signature close the brackets up too.
    @Test
    func diffBeforeAndAfterCloseUpABreak() async throws {
        let root = try Self.indexedRepo()
        let changed = Self.source.replacingOccurrences(of: ") -> Int { call }", with: ") -> String { \"\\(call)\" }")
        try TestSources.write(changed, to: "Sources/Lib/Answerer.swift", in: root)
        let output = try await DiffEngineTests.diff(root)

        #expect(output.contains("before: public static func answer(_ call: Int, from direction: String) -> Int"), "\(output)")
        #expect(output.contains("after:  public static func answer(_ call: Int, from direction: String) -> String"), "\(output)")
    }

    /// The shared cut tidies before it cuts.
    @Test
    func shownTidiesThenCuts() {
        #expect(SourceSlicer.shown("f( _ a: Int )") == "f(_ a: Int)")
    }

    /// A reformat that only moves the parameters onto their own lines says so, not that the bytes are another normalization.
    @Test
    func reformatOnlyDiffNamesWhitespace() async throws {
        let root = try TestSources.makeTempRepo()
        let flat = "public func answer(_ call: Int, label: String = \"( x )\") -> Int { call }\n"
        let broken = "public func answer(\n    _ call: Int,\n    label: String = \"( x )\"\n) -> Int { call }\n"
        try TestSources.write(flat, to: "Sources/Lib/Answerer.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try TestSources.write(broken, to: "Sources/Lib/Answerer.swift", in: root)
        try TestSources.commitAll(in: root, message: "reformat")
        let output = try await DiffEngineTests.diff(root, range: "HEAD~1..HEAD")

        #expect(output.contains("(only whitespace or line breaks changed)"), "\(output)")
        #expect(!output.contains("Unicode normalization"), "\(output)")
    }

    /// Two normalizations of the same text still get the normalization note.
    @Test
    func normalizationOnlyDiffKeepsItsNote() async throws {
        let root = try TestSources.makeTempRepo()
        let composed = "public func answer(label: String = \"caf\u{E9}\") -> Int { 1 }\n"
        let decomposed = "public func answer(label: String = \"cafe\u{301}\") -> Int { 1 }\n"
        try TestSources.write(composed, to: "Sources/Lib/Answerer.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try TestSources.write(decomposed, to: "Sources/Lib/Answerer.swift", in: root)
        try TestSources.commitAll(in: root, message: "renormalize")
        let output = try await DiffEngineTests.diff(root, range: "HEAD~1..HEAD")

        #expect(output.contains("another Unicode normalization"), "\(output)")
        #expect(!output.contains("only whitespace"), "\(output)")
    }

    /// A long signature wrapped by the digest closes a bracket inside a parameter type that the source broke across lines.
    @Test
    func longSignatureClosesAnInnerBracket() async throws {
        let root = try TestSources.makeTempRepo()
        // Enough body that the digest is smaller than the source and so is served as a digest.
        let body = (1 ... 20).map { "        let value\($0) = \($0) * 2" }.joined(separator: "\n")
        let filler = (1 ... 10).map { "    public static func filler\($0)() -> Int {\n\(body)\n        return value1\n    }\n" }.joined(separator: "\n")
        let long = """
        public enum Answerer {
        \(filler)
            public static func answer(
                _ first: [
                    Int
                ],
                second: String,
                third: String,
                fourth: String,
                fifteenth: String,
                fourteenth: String,
                thirteenth: String,
                twelfth: String,
                eleventh: String,
                tenth: String,
                fifth: String,
                sixth: String,
                seventh: String,
                eighth: String,
                ninth: String
            ) -> Int { 1 }
        }
        """
        try TestSources.write(long, to: "Sources/Lib/Answerer.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        let answer = try engine.digest(target: "Answerer", options: DigestOptions())

        #expect(answer.contains("_ first: [Int]"), "\(answer)")
        #expect(!answer.contains("[ Int"), "\(answer)")
    }

    /// A line asked for inside a long member with a long signature gets the declaration wrapped, with an inner bracket the source broke closed up.
    @Test
    func lineWindowDeclarationClosesAnInnerBracket() throws {
        let body = (1 ... 30).map { "        _ = \"line\($0)\"" }.joined(separator: "\n")
        let source = """
        struct Answerer {
            static func answer(
                _ first: [
                    Int
                ],
                second: String,
                third: String,
                fourth: String,
                fifth: String,
                sixth: String,
                seventh: String,
                eighth: String,
                ninth: String,
                tenth: String,
                eleventh: String,
                twelfth: String
            ) {
        \(body)
            }
        }
        """
        let store = try TestSources.makeStore()
        let root = try TestSources.makeTempDirectory()
        let parsed = try TestSources.parsed(source, path: "Sources/Gizmo/Answerer.swift", in: root)
        try store.replaceFiles([parsed]) { _ in ("Gizmo", false) }
        let renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: root)
        let output = try renderer.render(target: "Sources/Gizmo/Answerer.swift:30", options: DigestOptions())

        #expect(output.contains("_ first: [Int]"), "\(output)")
        #expect(!output.contains("[ Int"), "\(output)")
    }

    /// A regex literal's contents are never tidied: the space inside `#/( a)/#` is part of the pattern.
    @Test
    func tidyingKeepsRegexLiteralContents() {
        let tidy = SourceSlicer.tidyingBrackets(in:)

        #expect(tidy("f(a: Regex<Substring> = #/( a)/#, b: Int = 1 )") == "f(a: Regex<Substring> = #/( a)/#, b: Int = 1)")
        #expect(tidy("f(a: Regex<Substring> = ##/( a/#)/##)") == "f(a: Regex<Substring> = ##/( a/#)/##)")
        #expect(tidy("f(a: Regex<Substring> = #/(\\/ a)/#, b: [ Int ])") == "f(a: Regex<Substring> = #/(\\/ a)/#, b: [Int])")
        #expect(SourceSlicer.collapsingWhitespace(in: "f(a: R = #/( a   b)/#)") == "f(a: R = #/( a   b)/#)")
    }

    /// Changing a regex default's inner space changes the pattern, so the diff shows both lines and does not call it whitespace.
    @Test
    func regexDefaultChangeIsNotCalledWhitespace() async throws {
        let root = try TestSources.makeTempRepo()
        let before = "public func answer(a: Regex<Substring> = #/( a)/#) -> Int { 1 }\n"
        let after = "public func answer(a: Regex<Substring> = #/(a)/#) -> Int { 1 }\n"
        try TestSources.write(before, to: "Sources/Lib/Answerer.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try TestSources.write(after, to: "Sources/Lib/Answerer.swift", in: root)
        try TestSources.commitAll(in: root, message: "change")
        let output = try await DiffEngineTests.diff(root, range: "HEAD~1..HEAD")

        #expect(output.contains("before: public func answer(a: Regex<Substring> = #/( a)/#)"), "\(output)")
        #expect(output.contains("after:  public func answer(a: Regex<Substring> = #/(a)/#)"), "\(output)")
        #expect(!output.contains("only whitespace"), "\(output)")
        #expect(!output.contains("Unicode normalization"), "\(output)")
    }

    /// A signature that changed both in its line breaks and in its normalization gets both notes, whitespace first.
    @Test
    func spacingAndNormalizationBothGetNotes() async throws {
        let root = try TestSources.makeTempRepo()
        let flat = "public func answer(_ call: Int, label: String = \"caf\u{E9}\") -> Int { call }\n"
        let broken = "public func answer(\n    _ call: Int,\n    label: String = \"cafe\u{301}\"\n) -> Int { call }\n"
        try TestSources.write(flat, to: "Sources/Lib/Answerer.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try TestSources.write(broken, to: "Sources/Lib/Answerer.swift", in: root)
        try TestSources.commitAll(in: root, message: "both")
        let output = try await DiffEngineTests.diff(root, range: "HEAD~1..HEAD")

        let spacing = output.range(of: "(only whitespace or line breaks changed)")
        let bytes = output.range(of: "another Unicode normalization")
        #expect(spacing != nil && bytes != nil, "\(output)")
        if let spacing, let bytes {
            #expect(spacing.lowerBound < bytes.lowerBound, "\(output)")
        }
    }

    /// An extension's where-clause prints without the space a broken line left.
    @Test
    func extensionContextClosesBrackets() {
        let row = SymbolRow(
            id: 1, fileID: 1, path: "A.swift", module: "M", parentID: nil, kind: .extensionKind,
            name: "Array", line: 1, column: 1, endLine: 2, accessLevel: .internalLevel,
            isStatic: false, isStored: false, signature: "extension Array where Element: Collection, Element.Index == ( Int )",
            docSummary: nil, ifConfigCondition: nil, viewOutline: nil
        )

        #expect(extensionContext(row) == " where Element: Collection, Element.Index == (Int)")
    }

    private static func indexedRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(source, to: "Sources/Lib/Answerer.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        return root
    }
}
