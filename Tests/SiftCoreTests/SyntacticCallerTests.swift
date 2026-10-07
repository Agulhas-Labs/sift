//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the degraded caller answer: when semantics cannot answer, `where` serves name-matched call sites from the working tree instead of nothing.
///
/// The rule these all defend is that degrading must not blur the two claims. A semantic caller is resolved through a USR; these are spellings that agree. The block therefore has to say which name it matched and what a name cannot promise — and it must never move the header's semantic axis, which still reports the refusal honestly.
@Suite(.temporaryDirectories)
struct SyntacticCallerTests {
    private static func makeRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            struct Helper {
                func assertEventually() {}
                func unused() {}
            }
            """,
            to: "Sources/App/Helper.swift",
            in: root
        )
        try TestSources.write(
            """
            struct AlphaTests {
                let helper = Helper()
                func testOne() { helper.assertEventually() }
                func testTwo() {
                    helper.assertEventually()
                }
            }
            struct BetaTests {
                func testThree() { Helper().assertEventually() }
            }
            """,
            to: "Sources/App/Users.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        return root
    }

    @Test
    func baseNameStripsQualifiersAndArgumentLabels() {
        #expect(CallSiteScanner.baseName(of: "refresh(_:)") == "refresh")
        #expect(CallSiteScanner.baseName(of: "SummaryCache.refresh(_:to:)") == "refresh")
        #expect(CallSiteScanner.baseName(of: "Widget") == "Widget")
        #expect(CallSiteScanner.baseName(of: "init(from:)") == "init")
    }

    /// The whole point: a query that could only refuse now returns something the reader can act on.
    @Test
    func whereServesCallSitesWhenThereIsNoIndexStore() async throws {
        let root = try Self.makeRepo()
        let engine = try SiftEngine(directory: root)

        let freshness = try await engine.ensureFresh()
        let output = try await engine.lookup(symbol: "assertEventually()", freshness: freshness)

        #expect(output.contains("syntactic call sites"))
        #expect(output.contains("3 call sites in 1 file"))
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Users.swift:3  in AlphaTests.testOne()"))
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Users.swift:9  in BetaTests.testThree()"))
    }

    /// The fallback caveat is one short line, not the three-line paragraph it used to print on every answer — the full warning, with the dynamic-dispatch detail, lives in `sift help answers` instead.
    @Test
    func theFallbackCaveatIsOneLineAndOmitsDynamicDispatch() async throws {
        let root = try Self.makeRepo()
        let engine = try SiftEngine(directory: root)

        let freshness = try await engine.ensureFresh()
        let output = try await engine.lookup(symbol: "assertEventually()", freshness: freshness)

        let caveatLines = output.split(separator: "\n").filter { $0.hasPrefix(NameMatchedSites.headingOpening) }

        #expect(caveatLines.count == 1)
        #expect(caveatLines.first?.contains("over the working tree, never stale") == true)
        #expect(caveatLines.first?.contains("dynamically dispatched") == false)
    }

    /// Naming the enclosing declaration is what makes a call site actionable — a bare `file:line` list is what grep already gives.
    @Test
    func callSitesNameTheDeclarationTheySitIn() async throws {
        let root = try Self.makeRepo()
        let scanner = CallSiteScanner(
            repoRoot: root,
            enumerator: FileEnumerator(repoRoot: root, config: SiftConfig())
        )

        let found = await scanner.callSites(named: ["assertEventually": .call])

        #expect(found["assertEventually"]?.map(\.enclosing) == ["AlphaTests.testOne()", "AlphaTests.testTwo()", "BetaTests.testThree()"])
    }

    /// "Scanned and found none" is a real finding about the symbol, and has to read differently from "no scanner ran".
    @Test
    func aSymbolWithNoCallSitesSaysSoRatherThanStayingSilent() async throws {
        let root = try Self.makeRepo()
        let engine = try SiftEngine(directory: root)

        let freshness = try await engine.ensureFresh()
        let output = try await engine.lookup(symbol: "unused()", freshness: freshness)

        #expect(output.contains("no call spelled \"unused\" anywhere in the working tree"))
    }

    /// A property is read and written, never called, so its sites are the places its name is written as an expression — static or instance, bare, qualified or in a key path.
    ///
    /// Matched on calls alone, a property used throughout answered that no call was spelled anywhere, which reads as "nothing uses this".
    @Test
    func aPropertysSitesAreItsUsesRatherThanItsCalls() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            struct Limits {
                static let depth = 12
                let flag = true
                func lines(_ text: String) -> [Substring] {
                    Array(text.split(separator: " ").prefix(Self.depth))
                }
            }
            """,
            to: "Sources/App/Limits.swift",
            in: root
        )
        try TestSources.write(
            """
            struct Reader {
                let limits = Limits()
                func read() -> Int {
                    Limits.depth + (limits.flag ? 1 : 0)
                }
                func chosen() -> [Bool] { [limits].map(\\.flag) }
            }
            """,
            to: "Sources/App/Reader.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)

        let freshness = try await engine.ensureFresh()
        let depth = try await engine.lookup(symbol: "Limits.depth", freshness: freshness)
        let flag = try await engine.lookup(symbol: "Limits.flag", freshness: freshness)

        #expect(depth.contains("\"depth\" (2 uses in 2 files"))
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(depth).contains("Sources/App/Limits.swift:5  in Limits.lines(_:)"))
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(depth).contains("Sources/App/Reader.swift:4  in Reader.read()"))
        #expect(!depth.contains("no call spelled"))
        #expect(flag.contains("\"flag\" (2 uses in 1 file"))
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(flag).contains("Sources/App/Reader.swift:6  in Reader.chosen()"))
    }

    /// A function keeps to its calls: a name passed as a value is not a call site, and the property rule does not widen what a function's list means.
    @Test
    func aFunctionsSitesAreStillItsCalls() async throws {
        let root = try Self.makeRepo()
        try TestSources.write("let action = Helper().unused\n", to: "Sources/App/Handles.swift", in: root)
        try TestSources.commitAll(in: root, message: "a reference that is no call")
        let engine = try SiftEngine(directory: root)

        let freshness = try await engine.ensureFresh()
        let output = try await engine.lookup(symbol: "unused()", freshness: freshness)

        #expect(output.contains("no call spelled \"unused\" anywhere in the working tree"))
    }

    /// A property's uses under an unqualified query are every expression spelling its name, so a local variable or a parameter of that name in unrelated code is listed among them — and the block's disclaimer names both, beside the same-named members of unrelated types it already named.
    ///
    /// A qualified query drops them (`WhereUseReceiverTests`).
    @Test
    func aPropertysUsesTakeInSameNamedLocals() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Limits {\n    static let depth = 12\n}\n", to: "Sources/App/Limits.swift", in: root)
        try TestSources.write(
            """
            struct Unrelated {
                func g() -> Int {
                    let depth = 3
                    return depth
                }
                func h(depth: Int) -> Int { depth * 2 }
            }
            """,
            to: "Sources/App/Unrelated.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)

        let freshness = try await engine.ensureFresh()
        let output = try await engine.lookup(symbol: "depth", freshness: freshness)

        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Unrelated.swift:4  in Unrelated.g()"))
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(output).contains("Sources/App/Unrelated.swift:6  in Unrelated.h(depth:)"))
        #expect(output.contains("syntactic call sites — by written name"))
    }

    /// The one-line stand-in notice is identical whether the empty list it stands in for would have held a property's uses or a function's calls — the reading of what an empty list means now lives once in `sift help worktree-index`, not repeated per kind on every call.
    @Test
    func theNoticeIsIdenticalForAnEmptyPropertyListAndAnEmptyFunctionList() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            "struct Limits {\n    static let unread = 12\n    func unused() {}\n}\n",
            to: "Sources/App/Limits.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)

        let freshness = try await engine.ensureFresh()
        let property = try await engine.lookup(symbol: "Limits.unread", freshness: freshness)
        let function = try await engine.lookup(symbol: "Limits.unused()", freshness: freshness)

        #expect(property.contains("no use spelled \"unread\" anywhere in the working tree"))
        #expect(property.contains("callers/overrides: NOT ANSWERED from the index store; see the mode line above."))
        #expect(!property.contains("Read an empty list"))
        #expect(function.contains("callers/overrides: NOT ANSWERED from the index store; see the mode line above."))
        // The two notices are the same string — neither carries a per-kind reading of the empty list.
        let propertyNotice = try #require(property.split(separator: "\n").first { $0.hasPrefix("callers/overrides: NOT ANSWERED") })
        let functionNotice = try #require(function.split(separator: "\n").first { $0.hasPrefix("callers/overrides: NOT ANSWERED") })
        #expect(propertyNotice == functionNotice)
    }

    /// One scan serves every unanswered name in the query; a per-symbol scan would multiply a whole-repo parse by the declaration cap.
    @Test
    func oneScanAnswersEveryRequestedName() async throws {
        let root = try Self.makeRepo()
        let scanner = CallSiteScanner(
            repoRoot: root,
            enumerator: FileEnumerator(repoRoot: root, config: SiftConfig())
        )

        let found = await scanner.callSites(named: ["assertEventually": .call, "Helper": .call])

        #expect(found["assertEventually"]?.count == 3)
        #expect(found["Helper"]?.count == 2)
    }

    /// The fallback must not launder a refusal into a fresh-looking answer: the header keeps saying there is no store.
    @Test
    func theFallbackNeverImprovesTheSemanticAxis() async throws {
        let root = try Self.makeRepo()
        let engine = try SiftEngine(directory: root)

        let freshness = try await engine.ensureFresh()
        let output = try await engine.lookup(symbol: "assertEventually()", freshness: freshness)

        #expect(output.contains("semantic: none (no index store — see note)"))
        #expect(output.contains("syntactic call sites — by written name over the working tree, never stale"))
    }

    /// A renderer with no scanner wired emits nothing at all, which is what keeps "unscanned" and "scanned, empty" distinguishable.
    @Test
    func noScannerMeansNoBlock() async throws {
        let store = try TestSources.makeStore()
        let parsed = try TestSources.parsed("struct Helper { func work() {} }", path: "Sources/App/Helper.swift")
        try store.replaceFiles([parsed]) { _ in ("App", false) }
        let renderer = WhereRenderer(store: store)

        let output = try await renderer.render(query: "work()", semantic: .inactive(note: "test run")).body

        #expect(!output.contains("syntactic call sites"))
        #expect(!output.contains("no call spelled"))
    }

    /// A subscript is used as `x[…]`, which spells no name, so with no store nothing name-matched can stand in for its reads and writes — and the answer says that, rather than that no call spelled "subscript" was found, which reads as dead code of something used on the next line.
    @Test
    func aSubscriptClaimsNoNameMatchedSitesItCannotHave() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            "struct Shelf {\n    subscript(slot: Int) -> Int { slot }\n}\n\nfunc restock() -> Int {\n    Shelf()[1]\n}\n",
            to: "Sources/App/Shelf.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)

        let freshness = try await engine.ensureFresh()
        let output = try await engine.lookup(symbol: "Shelf.subscript", freshness: freshness)

        #expect(output.contains("no name to match for "))
        #expect(output.contains("no name to match for subscript(_:): a subscript is used as x[…], which spells no name, so its reads and writes come from the index store alone"))
        #expect(!output.contains("spelled \"subscript\""))
    }

    /// With no store, a subscript's answer has no name-matched list, so it disclaims none: the header saying a name is not a symbol, and the notice saying how to read an empty list, would describe a match that never ran — as `sift diff` already declines to in the same case.
    @Test
    func aSubscriptAloneDisclaimsNoNameMatchedListItNeverScanned() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            "struct Shelf {\n    subscript(slot: Int) -> Int { slot }\n}\n\nfunc restock() -> Int {\n    Shelf()[1]\n}\n",
            to: "Sources/App/Shelf.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)

        let freshness = try await engine.ensureFresh()
        let output = try await engine.lookup(symbol: "Shelf.subscript", freshness: freshness)

        #expect(!output.contains(NameMatchedSites.headingOpening))
        #expect(!output.contains("Read an empty list"))
        #expect(output.contains("callers/overrides: NOT ANSWERED from the index store (a subscript has no name-matched fallback either); see the mode line above."))
    }

    /// An enum case is named — `.fast`, `case .fast:` — rather than called, so with no store what stands for its uses is every expression spelling its name; and a case nothing spells says no *use* was found, never that no call was.
    @Test
    func anEnumCasesSitesAreItsUsesRatherThanItsCalls() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            enum Mode {
                case fast, slow, idle
            }

            func pick(_ mode: Mode) -> Int {
                switch mode {
                case .fast: return 1
                default: return 0
                }
            }

            func make() -> Mode {
                Mode.slow
            }
            """,
            to: "Sources/App/Mode.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        let engine = try SiftEngine(directory: root)
        let freshness = try await engine.ensureFresh()

        let fast = try await engine.lookup(symbol: "Mode.fast", freshness: freshness)
        let slow = try await engine.lookup(symbol: "Mode.slow", freshness: freshness)
        let idle = try await engine.lookup(symbol: "Mode.idle", freshness: freshness)

        #expect(fast.contains("syntactic call sites — by written name"))
        #expect(fast.contains("\"fast\" (1 use in 1 file"))
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(fast).contains("Sources/App/Mode.swift:7  in pick(_:)"))
        #expect(WhereAnswerRepetitionTests.sitesOnePerLine(slow).contains("Sources/App/Mode.swift:13  in make()"))
        #expect(idle.contains("no use spelled \"idle\" anywhere in the working tree"))
        #expect(!idle.contains("no call spelled"))
    }

    /// A call is credited to the declaration it is written in — a subscript's accessors, a `deinit`, an enum case's associated-value default — never to the type around it, which is where a list of enclosing declarations without those kinds put it.
    @Test
    func aCallInASubscriptADeinitOrACaseDefaultIsCreditedToThatDeclaration() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            func lookup(_ slot: Int) -> Int { slot }

            struct Shelf {
                subscript(slot: Int) -> Int {
                    get { lookup(slot) }
                    set(value) { _ = lookup(value) }
                }
            }

            final class Crate {
                deinit { _ = lookup(0) }
            }

            enum Mode {
                case value(Int = lookup(1))
            }
            """,
            to: "Sources/App/Lookup.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        let scanner = CallSiteScanner(
            repoRoot: root,
            enumerator: FileEnumerator(repoRoot: root, config: SiftConfig())
        )

        let found = await scanner.callSites(named: ["lookup": .call])

        #expect(found["lookup"]?.map(\.enclosing) == ["Shelf.subscript(_:)", "Shelf.subscript(_:)", "Crate.deinit", "Mode.value(_:)"])
    }
}
