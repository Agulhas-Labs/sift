//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// What `sift similar` promises: the nearest shapes by rarity-weighted callee overlap, and a refusal wherever a ranking would be noise.
struct SimilarSearchTests {
    /// Two file writers that share the calls an atomic write cannot do without, named nothing alike.
    private static let writers: [String: String] = [
        "Sources/DepotStore.swift": """
        struct DepotStore {
            func save(_ data: Data, to url: URL) throws {
                let temporary = url.appendingPathComponent(".tmp")
                try data.write(to: temporary)
                guard rename(temporary.path, url.path) == 0 else {
                    throw failure(String(cString: strerror(errno)))
                }
            }
        }
        """,
        "Sources/CatalogueStore.swift": """
        struct CatalogueStore {
            func flush(_ text: String, into url: URL) throws {
                let scratch = url.appendingPathComponent(".tmp")
                try Data(text.utf8).write(to: scratch)
                guard rename(scratch.path, url.path) == 0 else {
                    throw failure(String(cString: strerror(errno)))
                }
            }
        }
        """,
    ]

    /// Bodies built out of the calls every Swift file makes, so the rarity weighting has a population to measure against.
    private static let commonplace: [String: String] = [
        "Sources/ShelfIndex.swift": """
        struct ShelfIndex {
            func labels() -> [String] { rows.map(\\.name).sorted() }
            func widths() -> [Int] { rows.map(\\.width).sorted() }
            func names() -> [String] { rows.map(\\.name).sorted() }
            func spans() -> [Int] { rows.map(\\.span).sorted() }
        }
        """,
        "Sources/DepotCatalog.swift": """
        struct DepotCatalog {
            func tally() -> [Int] { entries.map(\\.count).sorted() }
            func weights() -> [Int] { entries.map(\\.weight).sorted() }
            func labels() -> [String] { entries.map(\\.label).sorted() }
        }
        """,
    ]

    private static func answer(_ target: String, over sources: [String: String]) -> SimilarAnswer {
        let fingerprints = sources
            .sorted { $0.key < $1.key }
            .flatMap { FingerprintScanner.fingerprints(in: $0.value, path: $0.key) }
        return SimilarSearch.answer(target: target, fingerprints: fingerprints, filesScanned: sources.count)
    }

    private static func hits(_ target: String, over sources: [String: String], sourceLocation: SourceLocation = #_sourceLocation) -> [SimilarHit] {
        guard case let .ranked(_, hits, _) = answer(target, over: sources).outcome else {
            Issue.record("expected a ranking, got \(answer(target, over: sources).outcome)", sourceLocation: sourceLocation)
            return []
        }
        return hits
    }

    /// The finding the tool exists for: two writers of the same durable-write shape, named nothing alike, found by the calls they share.
    @Test
    func nearDuplicateBodiesRankFirstWhateverTheyAreCalled() {
        let found = Self.hits("DepotStore.save(_:to:)", over: Self.writers.merging(Self.commonplace) { first, _ in first })

        #expect(found.first?.fingerprint.declaration.qualifiedName == "CatalogueStore.flush(_:into:)")
        #expect(found.first?.sharedCallees.contains("rename") == true)
    }

    /// The rarity weighting, stated as the property it is: two bodies whose only shared calls are the ones every body makes are not close, however large a fraction of each other they are.
    ///
    /// Without the weighting these two share two of their four calls — a plain overlap of 0.5, comfortably over the floor — and the answer fills with every `map`-and-`sorted` one-liner in the tree.
    @Test
    func sharingOnlyCommonCalleesStaysUnderTheFloor() {
        var sources = Self.commonplace
        sources["Sources/CrateData.swift"] = """
        struct CrateData {
            func stacked() -> [Int] { rows.map { stamp($0) }.sorted() }
            func packed() -> [Int] { rows.map { emboss($0) }.sorted() }
        }
        """

        let found = Self.hits("CrateData.stacked()", over: sources)

        #expect(found.isEmpty)
    }

    /// A target too thin to compare is answered as that, with the query that can find its neighbours — never with a ranking built on one piece of evidence.
    @Test
    func aTargetWithOneCallIsTooThinToCompare() {
        let sources = ["Sources/CrateSet.swift": """
        struct CrateSet {
            func labels() -> [String] { rows.sorted() }
        }
        """]

        guard case let .thin(subject) = Self.answer("CrateSet.labels()", over: sources).outcome else {
            Issue.record("expected a thin target")
            return
        }
        #expect(subject.callees == ["sorted"])
        let rendered = SimilarRenderer.render(answer: Self.answer("CrateSet.labels()", over: sources))
        #expect(rendered.contains("too thin to compare"))
        #expect(rendered.contains("search 'kind:func calls:sorted'"))
    }

    /// The floor sits at three calls, not two: a two-callee body shares only common ground with anything (`insert`, say), which is thin evidence dressed as a ranking, while a three-callee body still ranks.
    @Test
    func aTwoCalleeTargetIsTooThinButAThreeCalleeTargetRanks() {
        let sources: [String: String] = [
            "Sources/CrateSet.swift": """
            struct CrateSet {
                func labels() -> [String] { rows.insert(0); tidy() }
            }
            """,
            "Sources/CrateData.swift": """
            struct CrateData {
                func labels() -> [String] { rows.insert(0); tidy() }
            }
            """,
        ]

        guard case let .thin(subject) = Self.answer("CrateSet.labels()", over: sources).outcome else {
            Issue.record("expected a thin target")
            return
        }
        #expect(subject.callees == ["insert", "tidy"])
        let rendered = SimilarRenderer.render(answer: Self.answer("CrateSet.labels()", over: sources))
        #expect(rendered.contains("too thin to compare"))
        #expect(rendered.contains("3 is the floor"))

        var withThird = sources
        withThird["Sources/CrateSet.swift"] = """
        struct CrateSet {
            func labels() -> [String] { rows.insert(0); tidy(); sorted() }
        }
        """

        guard case .ranked = Self.answer("CrateSet.labels()", over: withThird).outcome else {
            Issue.record("expected a ranking once the target clears the floor")
            return
        }
    }

    /// A declaration is never its own closest match, which it would otherwise always be.
    @Test
    func theTargetIsNeverAmongItsOwnResults() {
        let found = Self.hits("DepotStore.save(_:to:)", over: Self.writers)

        #expect(!found.contains { $0.fingerprint.declaration.qualifiedName == "DepotStore.save(_:to:)" })
    }

    /// Two candidates that score identically come back in path order on every run: a second look at the same question must not read as a change in the codebase.
    @Test
    func equalScoresAreOrderedByPathThenLine() {
        var sources = Self.writers
        sources["Sources/AlphaKit/DepotOld.swift"] = sources["Sources/CatalogueStore.swift"].map {
            $0.replacingOccurrences(of: "CatalogueStore", with: "DepotOld")
        }

        let found = Self.hits("DepotStore.save(_:to:)", over: sources)

        #expect(found.map(\.fingerprint.declaration.path) == ["Sources/AlphaKit/DepotOld.swift", "Sources/CatalogueStore.swift"])
        #expect(found.map(\.score).first == found.map(\.score).last)
    }

    /// An overloaded target lists its labeled candidates rather than one of them being picked, as a digest of the same name does.
    @Test
    func anOverloadedTargetListsTheCandidates() {
        let sources = ["Sources/DepotStore.swift": """
        struct DepotStore {
            func save(_ data: Data) throws { try data.write(to: url) }
            func save(_ text: String) throws { try Data(text.utf8).write(to: url) }
        }
        """]

        guard case let .ambiguous(candidates) = Self.answer("DepotStore.save", over: sources).outcome else {
            Issue.record("expected an ambiguous target")
            return
        }
        #expect(candidates.map(\.declaration.qualifiedName) == ["DepotStore.save(_:)", "DepotStore.save(_:)"])
        let rendered = SimilarRenderer.render(answer: Self.answer("DepotStore.save", over: sources))
        #expect(rendered.contains("2 declaration(s) answer to it; name one"))
        #expect(rendered.contains("func save(_ text: String) throws"))
    }

    /// A labeled form picks one overload out of the same pair the short form listed.
    @Test
    func aLabeledFormResolvesOneOverload() {
        let found = Self.hits("DepotStore.save(_:to:)", over: Self.writers)

        #expect(!found.isEmpty)
    }

    /// A bracketed sugar spelling and its generic spelling name the same extension member, whichever one the extension itself was written under: naming it `Array<Int>.member` and naming it `[Int].member` are the same question.
    @Test
    func aSugaredAndAGenericSpellingResolveTheSameExtensionMember() {
        let sources = ["Sources/CrateSet.swift": """
        extension [Int] {
            func summed() -> Int { reduce(0, +) }
        }
        """]

        guard case let .thin(sugared) = Self.answer("[Int].summed()", over: sources).outcome,
              case let .thin(generic) = Self.answer("Array<Int>.summed()", over: sources).outcome
        else {
            Issue.record("expected both spellings to resolve")
            return
        }

        #expect(sugared.isSameDeclaration(as: generic))
    }

    /// A module-qualified target resolves the same declaration an unqualified one does: this scan has no build graph to check the qualifier against a real module name, so `SiftCore.DepotStore.save(_:to:)` is answered by retrying with the leading qualifier dropped, and finds what `DepotStore.save(_:to:)` finds.
    @Test
    func aModuleQualifiedTargetResolvesTheSameDeclarationAsUnqualified() {
        guard case let .ranked(unqualifiedSubject, _, _) = Self.answer("DepotStore.save(_:to:)", over: Self.writers).outcome,
              case let .ranked(qualifiedSubject, _, _) = Self.answer("SiftCore.DepotStore.save(_:to:)", over: Self.writers).outcome
        else {
            Issue.record("expected both targets to resolve to a ranking")
            return
        }

        #expect(qualifiedSubject.isSameDeclaration(as: unqualifiedSubject))
    }

    /// The retry without the leading qualifier runs only when the path as written named nothing: a nested member spelled in full is one declaration, never made ambiguous by a same-named nest under another type.
    @Test
    func aFullSpellingThatResolvesIsNeverWidenedByTheRetry() {
        let sources = [
            "Sources/DepotStore.swift": """
            struct DepotStore {
                struct CrateSet { func flush() { a() } }
            }
            """,
            "Sources/CatalogueStore.swift": """
            struct CatalogueStore {
                struct CrateSet { func flush() { b() } }
            }
            """,
        ]

        let outcome = Self.answer("DepotStore.CrateSet.flush()", over: sources).outcome

        guard case let .thin(subject) = outcome else {
            Issue.record("expected the one declaration the full spelling names, got \(outcome)")
            return
        }

        #expect(subject.declaration.path == "Sources/DepotStore.swift")
    }

    /// The `File.swift:12-40` form a `where` answer or a stack trace hands back resolves to the declaration covering those lines.
    @Test
    func aLineRangeResolvesToTheDeclarationCoveringIt() {
        guard case let .ranked(subject, _, _) = Self.answer("DepotStore.swift:2-8", over: Self.writers).outcome else {
            Issue.record("expected a ranking")
            return
        }

        #expect(subject.declaration.qualifiedName == "DepotStore.save(_:to:)")
    }

    /// A target nothing answers to says so, and says what a candidate is — never an empty ranking, which would read as "nothing to reuse".
    @Test
    func aTargetNothingAnswersToIsSaidAsThat() {
        let answer = Self.answer("DepotStore.missing", over: Self.writers)

        guard case .unresolved = answer.outcome else {
            Issue.record("expected an unresolved target")
            return
        }
        let rendered = SimilarRenderer.render(answer: answer)

        #expect(rendered.contains("no declaration with a body answers to it"))
        #expect(rendered.contains("computed vars that have one"))
    }

    /// The caveat says the two things that decide what a hit means: written names, and a lower bound.
    @Test
    func theCaveatNamesBothLimits() {
        #expect(SimilarRenderer.caveat.contains("written names"))
        #expect(SimilarRenderer.caveat.contains("lower bound, never a verdict"))
        #expect(SimilarRenderer.caveat.contains("digest Type.member"))
    }

    /// An empty ranking is worded as a shape finding, not as a verdict about the codebase.
    @Test
    func anEmptyRankingReportsItsDenominators() {
        var sources = Self.commonplace
        sources["Sources/CrateData.swift"] = """
        struct CrateData {
            func stacked() -> [Int] { rows.map { stamp($0) }.sorted() }
        }
        """

        let rendered = SimilarRenderer.render(answer: Self.answer("CrateData.stacked()", over: sources))

        #expect(rendered.contains("no declaration reached"))
        #expect(rendered.contains("with a body in 3 file(s)"))
    }

    /// A stored property has no body to compare and is not a candidate; a computed one is.
    ///
    /// Neither does a protocol requirement whose accessor block has no accessor with a body (`{ get }`, on a var or a subscript) — the parser sees an accessor block there, but it carries nothing to compare — nor a stored property with only an observer (`didSet`): the storage stays stored, and an observer's own code is not the shape `similar` compares.
    @Test
    func onlyDeclarationsWithBodiesAreCandidates() {
        let source = """
        struct ShelfIndex {
            var stored = 0
            var computed: Int { rows.map(\\.count).reduce(0, +) }
            var explicit: Int { get { rows.count } }
            func method() -> Int { computed }
            var watched = 0 { didSet { stored = watched } }
        }
        protocol CrateClassifier {
            var total: Int { get }
            subscript(index: Int) -> Int { get }
            func requirement() -> Int
        }
        """

        let found = FingerprintScanner.fingerprints(in: source, path: "Sources/ShelfIndex.swift")

        // `explicit` writes its getter as an accessor block (`get { … }`) rather than the
        // implicit-getter shorthand `computed` uses; both have a body to compare.
        #expect(found.map(\.declaration.qualifiedName) == ["ShelfIndex.computed", "ShelfIndex.explicit", "ShelfIndex.method()"])
    }

    /// The skeleton is the sequence, not the set: the same two words written the other way round are a different shape.
    @Test
    func theSkeletonComparesOrderNotMembership() {
        let forwards: [DeclarationFingerprint.ControlToken] = [.guardToken, .throwToken, .guardToken, .throwToken]
        let backwards: [DeclarationFingerprint.ControlToken] = [.throwToken, .guardToken, .throwToken, .guardToken]

        #expect(SimilarityScore.skeletonSimilarity(forwards, forwards) == 1)
        #expect(SimilarityScore.skeletonSimilarity(forwards, backwards) < 1)
        #expect(SimilarityScore.skeletonSimilarity(forwards, []) == 0)
    }

    /// The floor gates on rarity-weighted callee overlap alone, not on the composite score: a candidate whose control-flow skeleton and written types both differ from the target's can clear the overlap floor and still score under it on the composite — and it is still listed.
    @Test
    func aCandidateBelowTheScoreFloorButAboveTheOverlapFloorIsStillListed() {
        let sources: [String: String] = [
            "Sources/DepotStore.swift": """
            struct DepotStore {
                func save(_ data: Data, to url: URL) throws {
                    if data.isEmpty { a() }
                    b()
                    other()
                }
            }
            """,
            "Sources/CatalogueStore.swift": """
            struct CatalogueStore {
                func flush(_ text: String, into url: URL) throws {
                    a()
                    c()
                }
            }
            """,
            "Sources/CrateData.swift": """
            struct CrateData {
                func helper() { b(); other() }
            }
            """,
            "Sources/CrateSet.swift": """
            struct CrateSet {
                func one() { c(); other() }
                func two() { c(); other() }
                func three() { c(); other() }
            }
            """,
            "Sources/ShelfIndex.swift": """
            struct ShelfIndex {
                func noise() { z(); z2() }
            }
            """,
        ]

        let found = Self.hits("DepotStore.save(_:to:)", over: sources)
        guard let hit = found.first(where: { $0.fingerprint.declaration.qualifiedName == "CatalogueStore.flush(_:into:)" }) else {
            Issue.record("expected CatalogueStore.flush(_:into:) among the hits")
            return
        }

        #expect(hit.calleeOverlap >= SimilarityScore.calleeFloor)
        #expect(hit.score < SimilarityScore.calleeFloor)
        // The number printed is the one the floor is on, never the composite, and the answer says which orders the list.
        let rendered = SimilarRenderer.render(answer: Self.answer("DepotStore.save(_:to:)", over: sources))
        #expect(rendered.contains("  0.35  Sources/CatalogueStore.swift"))
        #expect(rendered.contains("ordered by the full score"))
    }
}
