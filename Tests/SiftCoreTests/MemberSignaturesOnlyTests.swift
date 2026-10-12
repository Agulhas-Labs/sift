//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// `signaturesOnly` on a `Type.member` target serves the declaration through its signature and no body.
@Suite(.temporaryDirectories)
struct MemberSignaturesOnlyTests {
    private static var source: String {
        """
        protocol Reading {
            func read(_ key: String) throws -> Int
        }

        struct Store {
            var count: Int {
                let hidden = 1
                return hidden + 1
            }

            @discardableResult
            func merge<Element>(
                _ items: [Element],
                using closure: () -> Int = { 0 }
            ) throws -> [Element]
                where Element: Hashable
            {
                let gizmo = items.count
                return items
            }
        }
        """
    }

    private static func engine() async throws -> SiftEngine {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(source, to: "Sources/Store.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()
        return engine
    }

    private static let signatures = DigestOptions(signaturesOnly: true)

    @Test
    func aMultiLineSignatureWithAWhereClauseIsServedWithoutItsBody() async throws {
        let answer = try await Self.engine().digest(target: "Store.merge", options: Self.signatures)

        #expect(answer.contains("Store.merge(_:using:) — func — Sources/Store.swift:"))
        #expect(answer.contains("@discardableResult"))
        #expect(answer.contains("using closure: () -> Int = { 0 }"))
        #expect(answer.contains("where Element: Hashable"))
        #expect(!answer.contains("gizmo"))
        #expect(!answer.contains("return items"))
    }

    @Test
    func aComputedPropertyStopsAtItsAccessorBlock() async throws {
        let answer = try await Self.engine().digest(target: "Store.count", options: Self.signatures)

        #expect(answer.contains("var count: Int"))
        #expect(!answer.contains("hidden"))
    }

    @Test
    func aBodilessProtocolRequirementIsServedWhole() async throws {
        let answer = try await Self.engine().digest(target: "Reading.read", options: Self.signatures)

        #expect(answer.contains("func read(_ key: String) throws -> Int"))
    }

    @Test
    func severalTargetsEachDropTheirBody() async throws {
        let answer = try await Self.engine().digest(targets: ["Store.merge", "Store.count"], options: Self.signatures)

        #expect(answer.contains("where Element: Hashable"))
        #expect(answer.contains("var count: Int"))
        #expect(!answer.contains("gizmo"))
        #expect(!answer.contains("hidden"))
    }

    @Test(arguments: [
        ["var name: String { get }"],
        ["var name: String { get set }"],
        ["var name: String { get async throws }"],
        ["subscript(i: Int) -> Int { get }"],
        ["var name: String { mutating get nonmutating set }"],
        ["var name: String { get throws(Failure) }"],
    ])
    func aProtocolRequirementKeepsItsAccessorClause(lines: [String]) {
        #expect(MemberSignature.lines(of: lines) == lines)
    }

    @Test
    func aStoredPropertyWithAClosureInitialiserIsServedWhole() {
        let handler = ["var handler: () -> Void = {", "    handle(1)", "}"]
        let cache = ["lazy var cache: [Int] = {", "    [1, 2]", "}()"]

        #expect(MemberSignature.lines(of: handler) == handler)
        #expect(MemberSignature.lines(of: cache) == cache)
    }

    @Test
    func aClosureInitialiserFollowedByObserversIsServedAsItsDeclarationAlone() {
        let afterDid = MemberSignature.lines(of: ["var handler: () -> Void = { record(\"x\") } {", "    didSet { log() }", "}"])
        let afterWill = MemberSignature.lines(of: ["var handler: () -> Void = { record(\"x\") } {", "    willSet { log() }", "}"])
        let multiLine = MemberSignature.lines(of: [
            "var handler: () -> Void = {",
            "    record(\"}\")",
            "    work()",
            "} {",
            "    didSet { log() }",
            "    willSet { log() }",
            "}",
        ])

        #expect(afterDid == ["var handler: () -> Void = { record(\"x\") }"])
        #expect(afterWill == ["var handler: () -> Void = { record(\"x\") }"])
        #expect(multiLine == ["var handler: () -> Void = {", "    record(\"}\")", "    work()", "}"])
    }

    @Test
    func aQuotedBraceInsideAStringInterpolationDoesNotHideTheObservers() {
        let observers = ["    didSet { log() }", "}"]
        let nested = ["var label: String = { \"\\(f(\"{\"))\" } {"] + observers
        let raw = ["var label: String = { #\"{ \\#(f(#\"}\"#))\"# } {"] + observers
        let multiLine = ["var label: String = {", "    \"\"\"", "    {\\(f(\"{\"))", "    \"\"\"", "} {"] + observers

        #expect(MemberSignature.lines(of: nested) == [String(nested[0].dropLast(2))])
        #expect(MemberSignature.lines(of: raw) == [String(raw[0].dropLast(2))])
        #expect(MemberSignature.lines(of: multiLine) == Array(multiLine.prefix(4)) + ["}"])
    }

    @Test
    func deeplyNestedInterpolationsAreScannedWithoutExhaustingTheStack() {
        let depth = 3000
        let nested = String(repeating: "\"\\(", count: depth) + "1" + String(repeating: ")\"", count: depth)
        let line = "var e: String = { \(nested) }() {"
        let lines = [line, "    didSet { n() }", "}"]

        #expect(MemberSignature.lines(of: lines) == [String(line.dropLast(2))])
    }

    @Test
    func anObservedPropertyWithAPlainInitialiserDropsItsObservers() {
        #expect(MemberSignature.lines(of: ["var count = 1 {", "    didSet { log() }", "}"]) == ["var count = 1"])
    }

    @Test
    func aComparisonOperatorIsNotAnInitialiser() {
        #expect(MemberSignature.lines(of: ["static func == (a: Int, b: Int) -> Bool {", "    a < b", "}"]) == ["static func == (a: Int, b: Int) -> Bool"])
    }

    @Test
    func aRawStringIsSkippedWhole() {
        let braceInside = MemberSignature.lines(of: [##"func f(_ a: String = #"a"{"#) {"##, "    body()", "}"])
        let backslashEnd = MemberSignature.lines(of: [##"func f(_ a: String = #"\"#) {"##, "    body()", "}"])
        let multiline = MemberSignature.lines(of: ["func f(_ a: String = \"\"\"", "    {\"x\"}", "    \"\"\") {", "    body()", "}"])

        #expect(braceInside == [##"func f(_ a: String = #"a"{"#)"##])
        #expect(backslashEnd == [##"func f(_ a: String = #"\"#)"##])
        #expect(multiline == ["func f(_ a: String = \"\"\"", "    {\"x\"}", "    \"\"\")"])
    }

    @Test
    func anEffectfulAccessorKeepsItsHeaderWithoutItsBody() {
        let effectful = MemberSignature.lines(of: ["var fetched: Int {", "    get async throws {", "        try await load()", "    }", "}"])
        let plain = MemberSignature.lines(of: ["var count: Int {", "    get { 1 }", "    set { stash() }", "}"])

        #expect(effectful == ["var fetched: Int { get async throws }"])
        #expect(plain == ["var count: Int"])
    }

    @Test
    func theOverloadBannerCountsTheLinesPrinted() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            struct Pair {
                func pick(_ a: Int) -> Int {
                    let one = a
                    let two = one
                    return two
                }

                func pick(_ a: String) -> String {
                    let one = a
                    let two = one
                    return two
                }
            }
            """,
            to: "Sources/Pair.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "seed")
        let engine = try SiftEngine(directory: root)
        _ = try await engine.ensureFresh()

        let answer = try engine.digest(target: "Pair.pick", options: Self.signatures)

        #expect(answer.contains("Pair.pick names 2 declarations, 2 lines together; each follows"))
        #expect(answer.contains("func pick(_ a: Int) -> Int"))
        #expect(answer.contains("func pick(_ a: String) -> String"))
        #expect(!answer.contains("let two"))
    }

    @Test
    func withoutTheFlagTheBodyIsStillServed() async throws {
        let answer = try await Self.engine().digest(target: "Store.merge", options: DigestOptions())

        #expect(answer.contains("gizmo"))
        #expect(answer.contains("return items"))
    }
}
