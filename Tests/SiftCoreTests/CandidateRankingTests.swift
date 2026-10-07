//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the "nearest symbols" fallback both `digest` and `where` fall through to on a miss: a candidate declared under the qualifier's own type must outrank every other candidate, or a crowd of same-named methods elsewhere buries the one member the caller actually meant.
@Suite(.temporaryDirectories)
struct CandidateRankingTests {
    /// A manifest declaring the one target `App`, so the fixture's module is a name a query can write in front of a path rather than one guessed from the directory.
    private static func writeManifest(in root: URL) throws {
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "App", targets: [.target(name: "App")])
            """,
            to: "Package.swift",
            in: root
        )
    }

    /// `Engine` declares `start(mode:)`; twelve unrelated types each declare a plain `start()`, enough to fill the candidate page on name order alone and push `start(mode:)` off the end of it.
    private static func fixture() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try writeManifest(in: root)
        try TestSources.write(
            """
            struct Engine {
                func start(mode: String) -> Bool {
                    guard !mode.isEmpty else { return false }
                    return true
                }
            }
            """,
            to: "Sources/App/Engine.swift",
            in: root
        )
        try TestSources.write(
            """
            struct BayCard { func start() {} }
            struct BayFloor { func start() {} }
            struct BayGeometry { func start() {} }
            struct BaySnapshot { func start() {} }
            struct ChuteTap { func start() {} }
            struct CrateClassifier { func start() {} }
            struct CrateSet { func start() {} }
            struct FlaggedCard { func start() {} }
            struct InboundCard { func start() {} }
            struct ParcelGateway { func start() {} }
            struct QueueSubscriber { func start() {} }
            struct RateSampler { func start() {} }
            """,
            to: "Sources/App/Distractors.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        return root
    }

    /// The first line of a "nearest symbols:" block, or `nil` when the answer carries none.
    private static func firstCandidateLine(of output: String) -> Substring? {
        guard let marker = output.range(of: "nearest symbols:") else { return nil }
        return output[marker.upperBound...]
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
    }

    @Test
    func whereRanksTheQualifiersOwnTypeAheadOfEveryOtherCandidate() async throws {
        let engine = try SiftEngine(directory: Self.fixture())
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Engine.start(mod:)", freshness: freshness)

        #expect(output.contains("no exact match; nearest symbols:"))
        // The bug this pins: with twelve other `start()` symbols outranking it on name alone, `start(mode:)`
        // was cut off the page entirely rather than merely buried in it.
        let firstLine = Self.firstCandidateLine(of: output)
        #expect(firstLine?.contains("start(mode:)") == true)
        #expect(firstLine?.contains("Engine") == true)
    }

    @Test
    func digestRanksTheQualifiersOwnTypeAheadOfEveryOtherCandidate() async throws {
        let root = try Self.fixture()
        let engine = try SiftEngine(directory: root)
        try await engine.ensureFresh()

        let output = try engine.digest(target: "Engine.start(mod:)", options: DigestOptions())

        #expect(output.contains("nearest symbols:"))
        let firstLine = Self.firstCandidateLine(of: output)
        #expect(firstLine?.contains("start(mode:)") == true)
        #expect(firstLine?.contains("Engine") == true)
    }

    // MARK: Nested shapes — checking only the last qualifier missed both of these

    /// `Settings.DetailData.load(id:)` is declared in `extension Settings.DetailData`.
    ///
    /// The extension's parent row is stored under the *whole* dotted extended-type name, `"Settings.DetailData"` — not `"DetailData"`. Twelve unrelated `load()`s, enough to fill the candidate page on name order alone, must not bury it.
    private static func nestedExtensionFixture() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            struct Settings {
                struct DetailData {
                    let title = ""
                }
            }

            extension Settings.DetailData {
                func load(id: Int) -> Bool { true }
            }
            """,
            to: "Sources/App/Settings.swift",
            in: root
        )
        try TestSources.write(
            """
            struct BayCard { func load() {} }
            struct BayFloor { func load() {} }
            struct BayGeometry { func load() {} }
            struct BaySnapshot { func load() {} }
            struct ChuteTap { func load() {} }
            struct CrateClassifier { func load() {} }
            struct CrateSet { func load() {} }
            struct FlaggedCard { func load() {} }
            struct InboundCard { func load() {} }
            struct ParcelGateway { func load() {} }
            struct QueueSubscriber { func load() {} }
            struct RateSampler { func load() {} }
            """,
            to: "Sources/App/Distractors.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        return root
    }

    @Test
    func aMemberDeclaredInADottedExtensionOutranksEveryOtherCandidate() async throws {
        let engine = try SiftEngine(directory: Self.nestedExtensionFixture())
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Settings.DetailData.load(i:)", freshness: freshness)

        #expect(output.contains("no exact match; nearest symbols:"))
        let firstLine = Self.firstCandidateLine(of: output)
        #expect(firstLine?.contains("load(id:)") == true)
    }

    @Test
    func digestAlsoOutranksADottedExtensionsMemberAheadOfEveryOtherCandidate() async throws {
        let root = try Self.nestedExtensionFixture()
        let engine = try SiftEngine(directory: root)
        try await engine.ensureFresh()

        let output = try engine.digest(target: "Settings.DetailData.load(i:)", options: DigestOptions())

        #expect(output.contains("nearest symbols:"))
        let firstLine = Self.firstCandidateLine(of: output)
        #expect(firstLine?.contains("load(id:)") == true)
    }

    /// `Aa.DetailData` and eleven other types each declare their own nested `DetailData`, so every one of them shares `DetailData`'s bare name as its parent.
    ///
    /// Checking only that name, with no grandparent check, cannot tell `Aa.DetailData` apart from `Ab.DetailData`, and the tie falls to name order, where `load()` (every distractor) sorts ahead of `load(id:)` (the real target).
    private static func sameParentNameFixture() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            struct Aa {
                struct DetailData {
                    func load(id: Int) -> Bool { true }
                }
            }
            """,
            to: "Sources/App/Aa.swift",
            in: root
        )
        let letters = ["Ab", "Ac", "Ad", "Ae", "Af", "Ag", "Ah", "Ai", "Aj", "Ak", "Al", "Am"]
        for letter in letters {
            try TestSources.write(
                "struct \(letter) {\n    struct DetailData {\n        func load() {}\n    }\n}\n",
                to: "Sources/App/\(letter).swift",
                in: root
            )
        }
        try TestSources.commitAll(in: root, message: "fixture")
        return root
    }

    @Test
    func theGrandparentBreaksATieBetweenIdenticallyNamedNestedTypes() async throws {
        let engine = try SiftEngine(directory: Self.sameParentNameFixture())
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Aa.DetailData.load(i:)", freshness: freshness)

        #expect(output.contains("no exact match; nearest symbols:"))
        let firstLine = Self.firstCandidateLine(of: output)
        #expect(firstLine?.contains("load(id:)") == true)
    }

    @Test
    func digestAlsoBreaksATieBetweenIdenticallyNamedNestedTypesOnTheGrandparent() async throws {
        let engine = try SiftEngine(directory: Self.sameParentNameFixture())
        try await engine.ensureFresh()

        let output = try engine.digest(target: "Aa.DetailData.load(i:)", options: DigestOptions())

        #expect(output.contains("nearest symbols:"))
        let firstLine = Self.firstCandidateLine(of: output)
        #expect(firstLine?.contains("load(id:)") == true)
        #expect(firstLine?.contains("Sources/App/Aa.swift") == true)
    }

    // MARK: Every shape name resolution accepts — ranking must judge a path by the same rule

    /// The first candidate `where` and `digest` each give for `target`, from one freshly indexed fixture.
    private static func firstCandidates(
        for target: String,
        in root: URL,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> (where: Substring?, digest: Substring?) {
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()
        let looked = try await engine.lookup(symbol: target, freshness: freshness)
        let digested = try engine.digest(target: target, options: DigestOptions())
        #expect(looked.contains("no exact match; nearest symbols:"), sourceLocation: sourceLocation)
        #expect(digested.contains("nearest symbols:"), sourceLocation: sourceLocation)
        return (firstCandidateLine(of: looked), firstCandidateLine(of: digested))
    }

    /// `Module.Type.member`: resolution tries the module as the outermost element, so a path that opens with one names the same type as the path without it.
    @Test
    func aModuleWrittenInFrontRanksTheTypesOwnCandidateFirstOnBothTools() async throws {
        let first = try await Self.firstCandidates(for: "App.Engine.start(mod:)", in: Self.fixture())

        #expect(first.where?.contains("start(mode:)") == true)
        #expect(first.digest?.contains("start(mode:)") == true)
    }

    /// `Type.member` for a member of `extension Outer.Type`: resolution matches a *suffix* of the enclosing chain, so the bare type name answers for the extension's whole dotted path.
    @Test
    func aSuffixOfADottedExtensionsPathRanksItsMemberFirstOnBothTools() async throws {
        let first = try await Self.firstCandidates(for: "DetailData.load(i:)", in: Self.nestedExtensionFixture())

        #expect(first.where?.contains("load(id:)") == true)
        #expect(first.digest?.contains("load(id:)") == true)
    }

    /// `Row` is declared inside `extension Settings.DetailData`, so its own parent row is named `"Settings.DetailData"`; twelve other `Row`s each declare a plain `draw()`.
    private static func typeInADottedExtensionFixture() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            struct Settings {
                struct DetailData {}
            }

            extension Settings.DetailData {
                struct Row {
                    func draw(x: Int) -> Bool { x > 0 }
                }
            }
            """,
            to: "Sources/App/Settings.swift",
            in: root
        )
        for letter in ["Ab", "Ac", "Ad", "Ae", "Af", "Ag", "Ah", "Ai", "Aj", "Ak", "Al", "Am"] {
            try TestSources.write(
                "struct \(letter) {\n    struct Row {\n        func draw() {}\n    }\n}\n",
                to: "Sources/App/\(letter).swift",
                in: root
            )
        }
        try TestSources.commitAll(in: root, message: "fixture")
        return root
    }

    @Test
    func aTypeNestedInADottedExtensionRanksItsMemberFirstOnBothTools() async throws {
        let first = try await Self.firstCandidates(for: "Settings.DetailData.Row.draw(y:)", in: Self.typeInADottedExtensionFixture())

        #expect(first.where?.contains("draw(x:)") == true)
        #expect(first.digest?.contains("draw(x:)") == true)
    }

    /// `Aa.Bb.Cc` declares `mark(x:)`; twelve others declare their own `Bb.Cc` with a plain `mark()`, so the last two components tie for all thirteen and only the third one back tells them apart.
    private static func deepChainFixture() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            "enum Aa {\n    enum Bb {\n        struct Cc {\n            func mark(x: Int) -> Bool { x > 0 }\n        }\n    }\n}\n",
            to: "Sources/App/Aa.swift",
            in: root
        )
        for letter in ["Ab", "Ac", "Ad", "Ae", "Af", "Ag", "Ah", "Ai", "Aj", "Ak", "Al", "Am"] {
            try TestSources.write(
                "enum \(letter) {\n    enum Bb {\n        struct Cc {\n            func mark() {}\n        }\n    }\n}\n",
                to: "Sources/App/\(letter).swift",
                in: root
            )
        }
        try TestSources.commitAll(in: root, message: "fixture")
        return root
    }

    @Test
    func everyLevelOfADeepChainIsCheckedOnBothTools() async throws {
        let first = try await Self.firstCandidates(for: "Aa.Bb.Cc.mark(y:)", in: Self.deepChainFixture())

        #expect(first.where?.contains("mark(x:)") == true)
        #expect(first.digest?.contains("mark(x:)") == true)
    }

    /// A top-level `start(mode:)` in module `App`, behind twelve members named `start()`.
    private static func topLevelFixture() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try writeManifest(in: root)
        try TestSources.write(
            "func start(mode: String) -> Bool { !mode.isEmpty }\n",
            to: "Sources/App/Start.swift",
            in: root
        )
        try TestSources.write(
            """
            struct BayCard { func start() {} }
            struct BayFloor { func start() {} }
            struct BayGeometry { func start() {} }
            struct BaySnapshot { func start() {} }
            struct ChuteTap { func start() {} }
            struct CrateClassifier { func start() {} }
            struct CrateSet { func start() {} }
            struct FlaggedCard { func start() {} }
            struct InboundCard { func start() {} }
            struct ParcelGateway { func start() {} }
            struct QueueSubscriber { func start() {} }
            struct RateSampler { func start() {} }
            """,
            to: "Sources/App/Distractors.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        return root
    }

    /// `Module.member`: the module is the whole path, and a top-level declaration answers to it with no container row between them.
    @Test
    func aModuleAloneRanksItsTopLevelCandidateFirstOnBothTools() async throws {
        let first = try await Self.firstCandidates(for: "App.start(mod:)", in: Self.topLevelFixture())

        #expect(first.where?.contains("start(mode:)") == true)
        #expect(first.digest?.contains("start(mode:)") == true)
    }

    // MARK: A top-level candidate must not sink below every unrelated member

    /// `Outer.Engine.start(mode:)` is the owned candidate; a top-level `start()` is unrelated to the qualifier chain but shares its bare name, and twelve unrelated `starty()` members (a different name, so they never tie with the top-level one) are enough to fill the rest of the page.
    ///
    /// `s.parent_id IN (owners)` is SQL NULL for a top-level row (`parent_id` is NULL), not 0 — and `ORDER BY … DESC` sorts NULL after an explicit 0, so the top-level candidate sank below every one of the twelve unrelated members instead of tying with them on name. Ties keep the existing name/path/line order (Docs/Design.md), so `start()` — a lone name at rank 0 — must sort ahead of the alphabetically-later `starty…` crowd once it is no longer wrongly ranked last of all.
    private static func topLevelAmongOwnedFixture() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try writeManifest(in: root)
        try TestSources.write(
            """
            struct Outer {
                struct Engine {
                    func start(mode: String) -> Bool { !mode.isEmpty }
                }
            }
            """,
            to: "Sources/App/Outer.swift",
            in: root
        )
        try TestSources.write(
            "func start() -> Bool { true }\n",
            to: "Sources/App/Start.swift",
            in: root
        )
        try TestSources.write(
            """
            struct BayCard { func starty() {} }
            struct BayFloor { func starty() {} }
            struct BayGeometry { func starty() {} }
            struct BaySnapshot { func starty() {} }
            struct ChuteTap { func starty() {} }
            struct CrateClassifier { func starty() {} }
            struct CrateSet { func starty() {} }
            struct FlaggedCard { func starty() {} }
            struct InboundCard { func starty() {} }
            struct ParcelGateway { func starty() {} }
            struct QueueSubscriber { func starty() {} }
            struct RateSampler { func starty() {} }
            """,
            to: "Sources/App/Distractors.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        return root
    }

    @Test
    func whereRanksTheTopLevelCandidateWithTheCrowdRatherThanBelowIt() async throws {
        let engine = try SiftEngine(directory: Self.topLevelAmongOwnedFixture())
        let freshness = try await engine.ensureFresh()

        let output = try await engine.lookup(symbol: "Outer.Engine.start(mod:)", freshness: freshness)

        #expect(output.contains("no exact match; nearest symbols:"))
        let firstLine = Self.firstCandidateLine(of: output)
        #expect(firstLine?.contains("Outer.swift") == true)
        // The bug this pins: the top-level `start()` was pushed off the twelve-line page entirely by the
        // unrelated `starty()` crowd. Fixed, it ties with them at rank 0 and outranks them on name.
        #expect(output.contains("Start.swift"))
    }

    @Test
    func digestAlsoRanksTheTopLevelCandidateWithTheCrowdRatherThanBelowIt() async throws {
        let root = try Self.topLevelAmongOwnedFixture()
        let engine = try SiftEngine(directory: root)
        try await engine.ensureFresh()

        let output = try engine.digest(target: "Outer.Engine.start(mod:)", options: DigestOptions())

        #expect(output.contains("nearest symbols:"))
        let firstLine = Self.firstCandidateLine(of: output)
        #expect(firstLine?.contains("Outer.swift") == true)
        #expect(output.contains("Start.swift"))
    }
}
