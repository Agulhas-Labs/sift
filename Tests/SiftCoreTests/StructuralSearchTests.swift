//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers structural search: the query language, every predicate, and the honesty markers on the answer.
///
/// Matched against source strings rather than a repo wherever possible — the matcher is the part with the logic, and a per-case temp repo would buy nothing but seconds.
struct StructuralSearchTests {
    private static func matches(_ query: String, in source: String, path: String = "Sources/App/Fixture.swift") throws -> [StructuralMatch] {
        try StructuralMatcher.matches(in: source, path: path, query: StructuralQuery(query))
    }

    // MARK: The query language

    /// A rejection has to teach the language, because the alternative is an agent guessing field names one call at a time.
    @Test
    func unknownFieldNamesEveryValidField() {
        let error = describeFailure("kynd:func")

        #expect(error.contains("unknown field \"kynd\""))
        #expect(error.contains("kind"))
        #expect(error.contains("calls"))
        #expect(error.contains("has"))
    }

    @Test
    func unknownKindAndShapeAreRejectedAtParseTime() {
        // A typo that parsed would return a confident zero matches, which reads as "the codebase is clean".
        #expect(describeFailure("kind:funtion").contains("unknown kind"))
        #expect(describeFailure("has:forceUnrwap").contains("unknown shape"))
        #expect(describeFailure("effect:async2").contains("unknown effect"))
    }

    /// A misspelt grammar word is read as the one it spells, its negation kept.
    @Test
    func aMisspeltFieldKeepsItsNegation() throws {
        let healed = try StructuralQuery("!in:Tests kind:function")

        #expect(healed.source == "!path:Tests kind:func")
        #expect(healed.terms.first?.field == .path)
        #expect(healed.terms.first?.negated == true)
    }

    /// A bare term is a name lookup, not a syntax error.
    ///
    /// A bare word such as `search worktree` or `search statusline` must not fail as "not field:value" against declarations the index holds. The reading is visible in `source`, which the answer echoes.
    @Test
    func bareTermsAreReadAsNameLookups() throws {
        let query = try StructuralQuery("module resolver")

        #expect(query.source == "name:module name:resolver")
        #expect(try StructuralQuery("kind:struct !legacy").source == "kind:struct !name:legacy")
    }

    /// Bare queries tend to be lowercase words aimed at capitalized declarations, so `name:` matches case-insensitively.
    @Test
    func bareTermsFindCapitalizedDeclarationsCaseInsensitively() throws {
        let source = """
        struct ModuleResolver { func resolve() {} }
        struct WorktreeScan {}
        """

        #expect(try Self.matches("module resolver", in: source).map(\.qualifiedName) == ["ModuleResolver"])
        #expect(try Self.matches("worktree", in: source).map(\.qualifiedName) == ["WorktreeScan"])
        #expect(try Self.matches("kind:struct !worktree", in: source).map(\.qualifiedName) == ["ModuleResolver"])
    }

    /// A query that asks about a name carries the one thing root resolution needs, so it stops being the tool that cannot self-heal.
    ///
    /// Otherwise `search name:Logger` from a directory above the repos refuses while `digest Logger` resolves — the same question, answered two ways.
    @Test
    func aQueryOffersItsNameForRootResolution() throws {
        #expect(try StructuralQuery("name:Logger").probeName == "Logger")
        // A bare term is a name term, and the first name wins when there are several.
        #expect(try StructuralQuery("RecordDetail kind:struct").probeName == "RecordDetail")
        #expect(try StructuralQuery("name:Alpha name:Beta").probeName == "Alpha")
        // Shape alone names nothing to probe, and a negation names what the caller does *not* want.
        #expect(try StructuralQuery("kind:func effect:async").probeName == nil)
        #expect(try StructuralQuery("kind:struct !name:Legacy").probeName == nil)
        #expect(try StructuralQuery("!name:Legacy name:Beta").probeName == "Beta")
    }

    // MARK: The report's question

    /// The exact question a text search cannot answer.
    @Test
    func findsTestFunctionsWrappingACallInAnUnstructuredTask() throws {
        let source = """
        struct AlphaTests {
            @Test func wrapped() { Task { store.reload() } }
            @Test func direct() { store.reload() }
            func notATest() { Task { store.reload() } }
        }
        """

        let found = try Self.matches("kind:func attr:Test calls:Task", in: source)

        #expect(found.map(\.qualifiedName) == ["AlphaTests.wrapped()"])
    }

    /// The sharper form of the same question — a `Task` with nothing to await in it is the actual defect.
    @Test
    func negationFindsTheAwaitlessTaskOnly() throws {
        let source = """
        struct AlphaTests {
            @Test func pointless() { Task { store.reload() } }
            @Test func legitimate() { Task { await store.load() } }
        }
        """

        let found = try Self.matches("kind:func attr:Test calls:Task !has:await", in: source)

        #expect(found.map(\.qualifiedName) == ["AlphaTests.pointless()"])
    }

    // MARK: Predicates

    @Test
    func everyShapePredicateMatchesItsForm() throws {
        let source = """
        struct Shapes {
            func forcing(_ maybe: Int?) -> Int { maybe! }
            func forceTrying() throws -> Data { try! Data(contentsOf: url) }
            func forceCasting(_ any: Any) -> String { any as! String }
            func chaining(_ maybe: String?) -> Int? { maybe?.count }
            func closing() { [1].forEach { _ in } }
            func awaiting() async { await work() }
            func trying() throws { try work() }
        }
        """
        let expected = [
            "forceUnwrap": "Shapes.forcing(_:)",
            "forceTry": "Shapes.forceTrying()",
            "forceCast": "Shapes.forceCasting(_:)",
            "optionalChain": "Shapes.chaining(_:)",
            "closure": "Shapes.closing()",
            "await": "Shapes.awaiting()",
            "try": "Shapes.trying()",
        ]

        for (shape, owner) in expected {
            let found = try Self.matches("kind:func has:\(shape)", in: source)

            #expect(found.map(\.qualifiedName) == [owner], "has:\(shape)")
        }
    }

    /// `as!` inside an unfolded sequence expression is `UnresolvedAsExprSyntax`; matching only the folded node would make this predicate silently answer "clean".
    @Test
    func forceCastIsFoundInAnUnfoldedSequenceExpression() throws {
        let source = "struct S { func cast(_ any: Any) -> String { any as! String } }"

        let found = try Self.matches("kind:func has:forceCast", in: source)

        #expect(found.count == 1)
    }

    @Test
    func declarationPredicatesMatchWhatIsWritten() throws {
        let source = """
        @MainActor final class Screen: UIViewController, Loadable {
            static func make() -> Screen { Screen() }
            private func hidden() async throws {}
        }
        """

        try #expect(Self.matches("kind:class inherits:UIViewController", in: source).count == 1)
        try #expect(Self.matches("attr:MainActor", in: source).count == 1)
        try #expect(Self.matches("kind:func modifier:static", in: source).map(\.qualifiedName) == ["Screen.make()"])
        try #expect(Self.matches("kind:func effect:async effect:throws", in: source).map(\.qualifiedName) == ["Screen.hidden()"])
        try #expect(Self.matches("kind:func modifier:private name:hid", in: source).count == 1)
    }

    @Test
    func typealiasAssociatedtypeOperatorPrecedencegroupAndMacroAreAllFound() throws {
        // Every kind `SymbolKind` declares that lacked a `visit` override once answered "no declarations match" for a real repository — sift#defect. Each must be found, not just parsed.
        let source = """
        public typealias Handler = (String) -> Void

        protocol Fetching {
            associatedtype Value
        }

        infix operator <>: AdditionPrecedence

        precedencegroup TestFailure {
            associativity: left
        }

        @freestanding(expression) macro stringify(_ value: some Any)
        """

        try #expect(Self.matches("kind:typealias", in: source).map(\.qualifiedName) == ["Handler"])
        try #expect(Self.matches("kind:associatedtype", in: source).map(\.qualifiedName) == ["Fetching.Value"])
        try #expect(Self.matches("kind:operator", in: source).map(\.qualifiedName) == ["<>"])
        try #expect(Self.matches("kind:precedencegroup", in: source).map(\.qualifiedName) == ["TestFailure"])
        try #expect(Self.matches("kind:macro", in: source).map(\.qualifiedName) == ["stringify"])
    }

    @Test
    func everyStoredKindIsSearchableAndATypoKindIsRefusedNamingTheValidOnes() {
        // Every kind the store holds is one the matcher walks, so a kind a `where` or `digest` answer names can be searched for.
        let unwalked = SymbolKind.allCases.map(\.rawValue).filter { !StructuralMatcher.supportedKinds.contains($0) }
        #expect(unwalked.isEmpty)

        // A misspelled kind is refused, naming the kinds there are, rather than silently returning zero matches.
        let typoError = describeFailure("kind:funcs")
        #expect(typoError.contains("unknown kind \"funcs\""))
        #expect(typoError.contains("typealias"))
    }

    /// `uses:` is the superset — a type mentioned but never called is invisible to `calls:` and visible here.
    @Test
    func usesSeesMentionsThatCallsDoesNot() throws {
        let source = "struct S { func make() { let value: Formatter? = nil; _ = value } }"

        try #expect(Self.matches("kind:func calls:Formatter", in: source).isEmpty)
        try #expect(Self.matches("kind:func uses:Formatter", in: source).count == 1)
    }

    /// A body term on a container asks about everything the container holds — the documented reading, and the one that makes "which types touch Keychain" answerable.
    @Test
    func bodyTermsOnAContainerCoverItsMembers() throws {
        let source = """
        struct Outer {
            func inner() { Keychain.read() }
        }
        struct Untouched {
            func inner() {}
        }
        """

        let found = try Self.matches("kind:struct calls:read", in: source)

        #expect(found.map(\.qualifiedName) == ["Outer"])
    }

    /// A subscript is named the way `where`/`digest` name it from the store — `subscript(_:)`, or labeled where a parameter is written with one — not the bare word, which no store row carries.
    @Test
    func subscriptsAreNamedByTheirLabelsNotTheBareWord() throws {
        let source = """
        struct Cache {
            subscript(slot: Int) -> String? { nil }
            subscript(key key: String, default value: String) -> String { value }
        }
        """

        let found = try Self.matches("kind:subscript", in: source)

        #expect(found.map(\.qualifiedName) == ["Cache.subscript(_:)", "Cache.subscript(key:default:)"])
    }

    @Test
    func qualifiedNameCarriesTheEnclosingTypes() throws {
        let source = "struct Outer { struct Inner { func deep() {} } }"

        let found = try Self.matches("kind:func name:deep", in: source)

        #expect(found.map(\.qualifiedName) == ["Outer.Inner.deep()"])
    }

    @Test
    func pathTermsFilterBeforeTheFileIsParsed() throws {
        let query = try StructuralQuery("kind:func path:Tests")

        #expect(query.admitsPath("Tests/AppTests/FooTests.swift"))
        #expect(!query.admitsPath("Sources/App/Foo.swift"))
    }

    @Test
    func negatedPathTermsExcludeRatherThanRequire() throws {
        let query = try StructuralQuery("kind:func !path:Tests")

        #expect(!query.admitsPath("Tests/AppTests/FooTests.swift"))
        #expect(query.admitsPath("Sources/App/Foo.swift"))
    }

    /// A negated path term must not also fail every declaration in the files it *did* admit — the double-negative the declaration pass has to sidestep.
    @Test
    func negatedPathTermStillMatchesInsideAnAdmittedFile() throws {
        let source = "struct S { func work() {} }"

        let found = try Self.matches("kind:func !path:Tests", in: source, path: "Sources/App/S.swift")

        #expect(found.count == 1)
    }

    @Test
    func sigMatchesTheSignatureAsWritten() throws {
        let source = """
        struct API {
            func fetch(completion: @escaping (Int) -> Void) {}
            func fetch() async -> Int { 0 }
            func report() -> Bool { true }
        }
        """

        // Values are single tokens (terms split on whitespace), so a return type is matched by its
        // name alone — the slice is whitespace-collapsed either way.
        let completions = try Self.matches("kind:func sig:completion", in: source)
        let boolReturning = try Self.matches("kind:func sig:Bool", in: source)

        #expect(completions.map(\.qualifiedName) == ["API.fetch(completion:)"])
        #expect(boolReturning.map(\.qualifiedName) == ["API.report()"])
    }

    @Test
    func importsGatesTheWholeFileIncludingIfConfigBranches() throws {
        let importing = """
        import HealthKit
        #if os(iOS)
        import UIKit
        #endif
        import struct Foundation.URL

        struct Reader { func read() {} }
        """
        let bare = "struct Plain { func read() {} }"

        // The gate admits by exact module name — first component and full dotted path both count,
        // and an #if-wrapped import counts for both branches, same honesty rule as the indexer.
        try #expect(Self.matches("kind:func imports:HealthKit", in: importing).count == 1)
        try #expect(Self.matches("kind:func imports:UIKit", in: importing).count == 1)
        try #expect(Self.matches("kind:func imports:Foundation", in: importing).count == 1)
        try #expect(Self.matches("kind:func imports:Foundation.URL", in: importing).count == 1)
        try #expect(Self.matches("kind:func imports:Health", in: importing).isEmpty)
        try #expect(Self.matches("kind:func imports:HealthKit", in: bare).isEmpty)
        try #expect(Self.matches("kind:func !imports:HealthKit", in: bare).count == 1)
        try #expect(Self.matches("kind:func !imports:HealthKit", in: importing).isEmpty)
    }

    // MARK: Rendering

    @Test
    func emptyResultsReportTheDenominator() throws {
        let query = try StructuralQuery("kind:func name:missing")
        let rendered = SearchRenderer.render(result: StructuralSearch.Result(matches: [], filesScanned: 431), query: query)

        #expect(rendered.contains("no declarations match — scanned 431 file(s)"))
    }

    /// The name-vs-symbol caveat appears exactly when a term depends on it, so it stays informative rather than becoming boilerplate.
    @Test
    func theNameMatchingCaveatAppearsOnlyForNameMatchedTerms() throws {
        let match = StructuralMatch(path: "a.swift", line: 1, endLine: 2, kind: "func", qualifiedName: "S.f()", signature: "func f()")
        let withCalls = try SearchRenderer.render(result: StructuralSearch.Result(matches: [match], filesScanned: 1), query: StructuralQuery("calls:save"))
        let withoutCalls = try SearchRenderer.render(result: StructuralSearch.Result(matches: [match], filesScanned: 1), query: StructuralQuery("kind:func"))

        #expect(withCalls.contains("match written names, not resolved symbols"))
        #expect(!withoutCalls.contains("match written names"))
        #expect(withoutCalls.contains("never stale"))
    }

    /// `--count`'s whole point: the summary line survives, the per-match listing does not.
    @Test
    func countDropsTheListingButKeepsTheSummary() throws {
        let match = StructuralMatch(path: "a.swift", line: 1, endLine: 2, kind: "func", qualifiedName: "S.f()", signature: "func f()")
        let query = try StructuralQuery("kind:func")
        let rendered = SearchRenderer.renderCount(
            result: StructuralSearch.Result(matches: [match], filesScanned: 9),
            query: query,
            moduleFor: { _ in "App" }
        )

        #expect(rendered.contains("1 declaration(s) in 1 file(s) — scanned 9 file(s)"))
        #expect(!rendered.contains("a.swift:"))
        #expect(!rendered.contains(":1-2"))
    }

    /// The per-module breakdown a caller would otherwise build with `grep | sort | uniq -c` — sorted by count, descending, so the module carrying the most matches reads first.
    @Test
    func countBreaksDownByModuleWhenMoreThanOneIsPresent() throws {
        let matches = [
            StructuralMatch(path: "Tests/A/One.swift", line: 1, endLine: 2, kind: "func", qualifiedName: "A.one()", signature: "func one()"),
            StructuralMatch(path: "Tests/B/Two.swift", line: 1, endLine: 2, kind: "func", qualifiedName: "B.two()", signature: "func two()"),
            StructuralMatch(path: "Tests/B/Three.swift", line: 1, endLine: 2, kind: "func", qualifiedName: "B.three()", signature: "func three()"),
        ]
        let query = try StructuralQuery("kind:func")
        let rendered = SearchRenderer.renderCount(
            result: StructuralSearch.Result(matches: matches, filesScanned: 9),
            query: query,
            moduleFor: { path in path.contains("/A/") ? "ModuleA" : "ModuleB" }
        )
        let lines = rendered.split(separator: "\n").map(String.init)

        #expect(lines.contains("  2 ModuleB"))
        #expect(lines.contains("  1 ModuleA"))
        #expect(try #require(lines.firstIndex(of: "  2 ModuleB")) < #require(lines.firstIndex(of: "  1 ModuleA")))
    }

    /// A single module gives no comparison to make, so the breakdown adds nothing the summary hasn't already said.
    @Test
    func countOmitsTheBreakdownWhenOnlyOneModuleIsPresent() throws {
        let match = StructuralMatch(path: "a.swift", line: 1, endLine: 2, kind: "func", qualifiedName: "S.f()", signature: "func f()")
        let query = try StructuralQuery("kind:func")
        let rendered = SearchRenderer.renderCount(
            result: StructuralSearch.Result(matches: [match], filesScanned: 9),
            query: query,
            moduleFor: { _ in "App" }
        )

        #expect(!rendered.contains("App"))
    }

    /// `rendered()` is a spelling of the callee's own name, parentheses included, not a different value — the base name is what `BodyFacts` records, so the parenthesized form finds exactly what the bare one does.
    @Test
    func callsHealsAParenthesizedCalleeName() throws {
        let source = "struct S { func make() { rendered() } func rendered() {} }"

        let parenthesized = try StructuralQuery("calls:rendered()")
        let bare = try Self.matches("calls:rendered()", in: source)
        let expected = try Self.matches("calls:rendered", in: source)

        #expect(parenthesized.source == "calls:rendered")
        #expect(parenthesized.readingNote == "read calls:rendered() as calls:rendered — the spelling search takes.")
        #expect(bare.map(\.qualifiedName) == expected.map(\.qualifiedName))
    }

    /// A full argument-list spelling — even one naming no real label, only `_` — carries arity the index keeps no record of, so it is read down to the base name it names, but the answer now matches more than that one shape, and the note says so rather than calling it a bare spelling; only an empty `()` keeps that plain note.
    @Test
    func callsHealsAFullArgumentLabelSpelling() throws {
        let healed = try StructuralQuery("calls:rendered(_:)")

        #expect(healed.source == "calls:rendered")
        #expect(healed.readings.isEmpty)
        #expect(healed.readingNote == "read calls:rendered(_:) as calls:rendered — labels are not indexed, so this matches every call named rendered, whatever its labels.")
    }

    /// Unbalanced parentheses are not a spelling of any name, so the term refuses rather than quietly matching nothing.
    @Test
    func aCallsValueWithUnbalancedParenthesesRefuses() {
        #expect(describeFailure("calls:rendered(").contains("is not a call"))
        #expect(describeFailure("uses:rendered))").contains("is not a call"))
        #expect(describeFailure("calls:rendered(at:(into:)").contains("is not a call"))
    }

    /// A value carrying a real label — not only `_` or an empty pair — widens what the base name matches, so the note says so plainly rather than calling it a bare spelling; the note appears whether or not `--count` drops the listing.
    @Test
    func callsHealsALabelledSpellingWithItsOwnWideningNote() throws {
        let healed = try StructuralQuery("calls:save(to:)")

        #expect(healed.source == "calls:save")
        #expect(healed.readings.isEmpty)
        #expect(healed.readingNote == "read calls:save(to:) as calls:save — labels are not indexed, so this matches every call named save, whatever its labels.")
    }

    /// A qualified callee (`Foo.bar()`) is never indexed — only base names are — so the refusal says that and suggests the base name instead of the vaguer "does not spell one".
    @Test
    func aQualifiedCalleeRefusesNamingTheBaseNameToTry() {
        let message = describeFailure("calls:Foo.bar()")

        #expect(message.contains("a qualified callee isn't indexed"))
        #expect(message.contains("try calls:bar"))
    }

    /// `name:` values are healed by the same base-name reading `calls:`/`uses:` gets — `name:save()` is read as `name:save` rather than answering a confident zero.
    @Test
    func nameHealsAParenthesizedValueTheSameWayCallsDoes() throws {
        let healed = try StructuralQuery("name:save()")

        #expect(healed.source == "name:save")
        #expect(healed.readingNote == "read name:save() as name:save — the spelling search takes.")
    }

    /// A pattern-shaped value is refused with the syntax the field reads, not answered as a literal that matches nothing.
    @Test
    func aPatternShapedValueIsRefusedNamingTheFieldsSyntax() {
        for value in ["name:~fresh", "calls:/fetch/", "name:Fresh*", "name:*fresh", "name:^Fresh", "name:Fresh$", "calls:~fetch", "path:*.swift"] {
            let message = describeFailure(value)

            #expect(message.contains("does not read as a pattern"), "\(value)")
        }

        #expect(describeFailure("name:~fresh").contains("case-insensitive substring — write name:Fresh"))
        #expect(describeFailure("calls:fetch*").contains("calls: matches the value exactly"))
    }

    @Test
    func supportedAndLiteralValuesAreStillRead() throws {
        let source = """
        struct Fresh {
            static func == (lhs: Fresh, rhs: Fresh) -> Bool { true }
            static func ~= (lhs: Fresh, rhs: Fresh) -> Bool { true }
            func freshness() {}
            func take(_ value: some ~Copyable) {}
        }
        """

        try #expect(Self.matches("name:fresh kind:func", in: source).map(\.qualifiedName).map { $0.hasPrefix("Fresh.freshness(") } == [true])
        try #expect(Self.matches("name:==", in: source).map(\.qualifiedName).map { $0.hasPrefix("Fresh.==(") } == [true])
        try #expect(Self.matches("name:~=", in: source).map(\.qualifiedName).map { $0.hasPrefix("Fresh.~=(") } == [true])
        try #expect(Self.matches("sig:~Copyable", in: source).map(\.qualifiedName).map { $0.hasPrefix("Fresh.take(") } == [true])
    }

    private func describeFailure(_ query: String) -> String {
        do {
            _ = try StructuralQuery(query)
            return ""
        } catch {
            return String(describing: error)
        }
    }
}
